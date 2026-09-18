//! 合成器全局状态与会话生命周期。
//!
//! `ArchoeraShell` 是 calloop 回调里被可变借用的中心状态：Wayland 前端各协议
//! 状态、Space/输出、座位、控制面、以及 `archoera_shell_v1` 的客户端句柄都在这里。

use std::{
    ffi::OsString,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    time::Instant,
};

use smithay::{
    backend::renderer::{gles::GlesRenderer, ImportDma},
    desktop::{PopupManager, Space, Window},
    input::{Seat, SeatState},
    output::Output,
    reexports::{
        calloop::{generic::Generic, EventLoop, Interest, LoopSignal, Mode, PostAction},
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::wl_surface::WlSurface,
            Display, DisplayHandle, Resource,
        },
    },
    utils::{Logical, Point, Transform},
    wayland::{
        compositor::{CompositorClientState, CompositorState},
        cursor_shape::CursorShapeManagerState,
        dmabuf::{DmabufFeedbackBuilder, DmabufGlobal, DmabufState},
        fractional_scale::{self, FractionalScaleManagerState},
        idle_inhibit::IdleInhibitManagerState,
        input_method::InputMethodManagerState,
        output::OutputManagerState,
        selection::data_device::DataDeviceState,
        shell::xdg::{decoration::XdgDecorationState, XdgShellState},
        shm::ShmState,
        socket::ListeningSocketSource,
        text_input::TextInputManagerState,
        virtual_keyboard::VirtualKeyboardManagerState,
    },
};

use crate::{
    backend::Backend,
    cli::ShellConfig,
    control::ControlPlane,
    cursor::PointerElement,
    kiosk::OutputRect,
    protocol::{ArchoeraShellV1, Capability, MediaKey, PowerKey, SessionState},
    CalloopData,
};

/// ArchoeraOS 合成器状态。
pub struct ArchoeraShell {
    pub start_time: Instant,
    pub socket_name: OsString,
    pub display_handle: DisplayHandle,
    pub config: ShellConfig,

    /// 当前输出缩放（1.0 = 100%；运行时可由协议修改）。
    pub output_scale: f64,
    /// 期望输出模式（宽, 高）；`None` = 连接器首选模式。
    pub output_mode: Option<(i32, i32)>,
    /// 当前输出变换（旋转/镜像）。
    pub output_transform: Transform,

    // 桌面 / 输出
    pub space: Space<Window>,
    pub output: Option<Output>,
    pub popups: PopupManager,
    pub loop_signal: LoopSignal,

    // 渲染后端（含 GlesRenderer、输出与损伤跟踪）。
    // renderer 必须长期存活且可从状态访问，`zwp_linux_dmabuf_v1` 才能在
    // `dmabuf_imported` 里同步导入客户端缓冲。
    pub backend: Option<Backend>,

    // Wayland 前端
    pub compositor_state: CompositorState,
    pub xdg_shell_state: XdgShellState,
    pub decoration_state: XdgDecorationState,
    pub idle_inhibit_state: IdleInhibitManagerState,
    pub shm_state: ShmState,
    pub output_manager_state: OutputManagerState,
    pub fractional_scale_state: FractionalScaleManagerState,
    pub seat_state: SeatState<Self>,
    pub data_device_state: DataDeviceState,
    pub seat: Seat<Self>,
    /// 指针光标（形状 + 位图 + 位置）。
    pub cursor: PointerElement,
    /// `zwp_cursor_shape_v1`：客户端直接请求命名形状（GTK 据此跳过主题查找）。
    pub cursor_shape_state: CursorShapeManagerState,

    // 输入法（IME）：客户端 zwp_text_input_v3 ↔ IME zwp_input_method_v2，
    // smithay 负责两侧状态互转，合成器只需接全局对象与 popup。
    pub text_input_state: TextInputManagerState,
    pub input_method_state: InputMethodManagerState,
    /// `zwp_virtual_keyboard_v1`：IME（fcitx5）在 Wayland 前端下**同时**要求
    /// `zwp_input_method_v2` 与 `zwp_virtual_keyboard_v1` 两个全局才会初始化输入
    /// 上下文；缺少后者时 fcitx5 永远不会抓取键盘，快捷键切输入法无效。
    /// 该协议也供屏幕键盘 / 虚拟键盘客户端注入按键。
    pub virtual_keyboard_state: VirtualKeyboardManagerState,

    // linux-dmabuf（Flutter / GTK 的 EGL 渲染前提；不可用时客户端回退 wl_shm）
    pub dmabuf_state: DmabufState,
    pub dmabuf_global: Option<DmabufGlobal>,

    // ArchoeraOS 自定义协议
    pub shell_clients: Vec<ArchoeraShellV1>,
    pub session_state: SessionState,

    // 会话看门狗
    /// 当前已接入的 Wayland 客户端数。
    pub client_count: Arc<AtomicUsize>,
    /// 是否曾有客户端接入（避免空会话启动即退出）。
    pub had_client: bool,
    /// 由合成器拉起的会话命令（kiosk 主进程）；其退出即代表会话结束。
    pub session_child: Option<std::process::Child>,

    // 控制面
    pub control: ControlPlane,
    /// 当前有效的 idle-inhibitor surface 数量（0 → 未抑制）。
    pub idle_inhibitors: u32,
    pub idle_reason: Option<String>,

    /// 事件驱动的重绘标志：为真表示有新的客户端提交 / 输出变化需要合成，
    /// 为假时合成器完全空闲（不再空转 vblank / request_redraw）。
    needs_redraw: bool,
    /// udev：已有一帧交给 DRM、等 vblank 回收。用于把「一帧在飞行中」期间的
    /// 多次脏标记合并成一次合成（否则每个输入事件都会做一次全屏合成）。
    frame_in_flight: bool,
    /// 上次 `render_frame` 的单调毫秒（用于门控自愈）。
    last_render_ms: u64,
}

impl ArchoeraShell {
    pub fn new(
        event_loop: &mut EventLoop<CalloopData>,
        display: Display<Self>,
        config: ShellConfig,
    ) -> Self {
        let start_time = Instant::now();
        let dh = display.handle();

        let compositor_state = CompositorState::new::<Self>(&dh);
        let xdg_shell_state = XdgShellState::new::<Self>(&dh);
        let decoration_state = XdgDecorationState::new::<Self>(&dh);
        let idle_inhibit_state = IdleInhibitManagerState::new::<Self>(&dh);
        let shm_state = ShmState::new::<Self>(&dh, vec![]);
        let output_manager_state = OutputManagerState::new_with_xdg_output::<Self>(&dh);
        let fractional_scale_state = FractionalScaleManagerState::new::<Self>(&dh);
        let data_device_state = DataDeviceState::new::<Self>(&dh);
        let popups = PopupManager::default();

        // 光标命名形状协议：GTK 只要看到它就直接请求形状（否则会回退到主题查找，
        // 在无桌面环境的系统上常失败并退化成「隐藏光标」）。
        let cursor_shape_state = CursorShapeManagerState::new::<Self>(&dh);

        // 输入法：客户端侧 `zwp_text_input_v3`，IME 侧 `zwp_input_method_v2`。
        // smithay 负责两侧状态互转（输入上下文、preedit/commit、键盘抓取），
        // 合成器只需把两个全局对象接上并渲染候选窗口 popup。
        let text_input_state = TextInputManagerState::new::<Self>(&dh);
        let input_method_state = InputMethodManagerState::new::<Self, _>(&dh, |_client| true);
        // 虚拟键盘：fcitx5 的 Wayland 前端据此初始化并转发未处理的按键；
        // 也用于后续屏幕键盘注入按键。
        let virtual_keyboard_state =
            VirtualKeyboardManagerState::new::<Self, _>(&dh, |_client| true);

        // 注册 ArchoeraOS 控制协议全局对象（v4 起支持屏幕键盘按键注入）。
        let _global = dh.create_global::<Self, ArchoeraShellV1, ()>(4, ());

        let mut seat_state = SeatState::new();
        let mut seat: Seat<Self> = seat_state.new_wl_seat(&dh, "archoera");
        seat.add_keyboard(Default::default(), 200, 25)
            .expect("创建键盘失败");
        seat.add_pointer();
        // 触摸：kiosk 需要支持触摸设备（触摸即聚焦命中窗口，并驱动 text-input/IME）。
        seat.add_touch();

        let control = ControlPlane::new(config.volume);
        let client_count = Arc::new(AtomicUsize::new(0));
        let socket_name = Self::init_wayland_listener(
            display,
            event_loop,
            config.socket_name.as_deref(),
            client_count.clone(),
        );
        let loop_signal = event_loop.get_signal();

        let output_scale = config.scale;
        let output_mode = config.mode;
        let output_transform = crate::backend::output_transform(config.transform);

        Self {
            start_time,
            socket_name,
            display_handle: dh,
            config,
            output_scale,
            output_mode,
            output_transform,
            space: Space::default(),
            output: None,
            popups,
            loop_signal,
            backend: None,
            compositor_state,
            xdg_shell_state,
            decoration_state,
            idle_inhibit_state,
            shm_state,
            output_manager_state,
            fractional_scale_state,
            seat_state,
            data_device_state,
            seat,
            cursor: PointerElement::new(),
            cursor_shape_state,
            text_input_state,
            input_method_state,
            virtual_keyboard_state,
            dmabuf_state: DmabufState::new(),
            dmabuf_global: None,
            shell_clients: Vec::new(),
            session_state: SessionState::Ready,
            client_count,
            had_client: false,
            session_child: None,
            control,
            idle_inhibitors: 0,
            idle_reason: None,
            needs_redraw: false,
            frame_in_flight: false,
            last_render_ms: 0,
        }
    }

    /// 用渲染器报告的 dmabuf 格式注册 `zwp_linux_dmabuf_v1`。
    ///
    /// - `device_id = Some(dev_t)`（udev 后端）：用 `DmabufFeedbackBuilder` 发布 **v4**
    ///   反馈，告知客户端主渲染设备与可用 tranche（GPU 直出关键）；
    /// - `device_id = None`（winit 嵌套）：发布普通 **v3** 全局。
    ///
    /// 渲染器不支持任何 dmabuf 格式时（例如纯软件渲染）跳过注册，客户端会自动回退到
    /// `wl_shm`，合成器仍可正常工作。
    pub fn setup_dmabuf(&mut self, renderer: &mut GlesRenderer, device_id: Option<u64>) {
        let formats = renderer.dmabuf_formats();
        if formats.indexset().is_empty() {
            tracing::info!(
                "渲染器不报告 dmabuf 格式，跳过 zwp_linux_dmabuf_v1（客户端将回退 wl_shm）"
            );
            return;
        }
        let count = formats.indexset().len();

        let global = match device_id {
            Some(dev_id) => {
                let feedback = DmabufFeedbackBuilder::new(dev_id, formats)
                    .build()
                    .map_err(|err| tracing::warn!(%err, "构建 dmabuf 反馈失败"))
                    .ok();
                match feedback {
                    Some(feedback) => self
                        .dmabuf_state
                        .create_global_with_default_feedback::<Self>(
                            &self.display_handle,
                            &feedback,
                        ),
                    None => self
                        .dmabuf_state
                        .create_global::<Self>(&self.display_handle, renderer.dmabuf_formats()),
                }
            }
            None => self
                .dmabuf_state
                .create_global::<Self>(&self.display_handle, formats),
        };

        self.dmabuf_global = Some(global);
        tracing::info!(
            formats = count,
            dmabuf_v4 = device_id.is_some(),
            "已注册 zwp_linux_dmabuf_v1"
        );
    }

    /// 向各输出的客户端下发 frame 回调。
    ///
    /// **必须在帧真正上屏之后调用**：udev 走 vblank（`frame_submitted` 之后），
    /// winit 走 Redraw 之后。若在「合成完但还没上屏」时就发（此前的做法），客户端会
    /// 赶在上一帧之前画下一帧，多余提交被 `queue_frame` 丢弃 → 表现为**低帧率/卡顿**。
    pub fn send_frame_callbacks(&mut self) {
        let now = monotonic_now();
        let outputs: Vec<Output> = self.space.outputs().cloned().collect();
        for output in &outputs {
            let refresh = frame_refresh(output);
            self.space.elements().for_each(|window| {
                window.send_frame(output, now, refresh, |_, _| Some(output.clone()));
            });
        }
    }

    /// 合成并提交一帧：渲染全部输出、驱动客户端帧回调、清理已销毁的 popup。
    ///
    /// 调用即清空重绘标志：本帧合成的是「清零前」累积的全部状态。若渲染期间又有
    /// 客户端提交（不会发生：渲染不派发客户端消息），标志会被重新置位。
    pub fn render_frame(&mut self) -> anyhow::Result<()> {
        self.needs_redraw = false;
        self.last_render_ms = monotonic_now().as_millis() as u64;
        tracing::trace!("合成一帧");

        if let Some(backend) = self.backend.as_mut() {
            backend.render(&self.space, &self.cursor)?;
            // 只有真的提交了 DRM 帧才算「一帧在飞行中」：空帧不会产生 vblank，
            // 若也置位就会把后续的 schedule_redraw 永久挡掉（表现为画面定住，
            // 切 VT 回来走 ActivateSession 直接合成、于是又正常几帧）。
            self.frame_in_flight = backend.last_render_queued();
        }

        self.space.refresh();
        self.popups.cleanup();
        // 冲刷帧回调 / popup configure 等事件（udev 的 vblank 路径依赖此步）。
        let mut dh = self.display_handle.clone();
        if let Err(err) = dh.flush_clients() {
            tracing::warn!(%err, "flush_clients 失败");
        }
        // 帧率诊断：约每 5 秒在日志里打一条（info）。真机上若看到 fps 远高于屏幕
        // 刷新率，说明客户端没有被节流（帧回调/时间戳路径还有问题）；若 fps 正常但
        // 仍然卡，则瓶颈在每帧的合成/上传或应用自身。
        let now_ms = monotonic_now().as_millis() as u64;
        let last_ms = FRAME_LOG_MS.load(Ordering::Relaxed);
        if last_ms == 0 {
            FRAME_LOG_MS.store(now_ms, Ordering::Relaxed);
        } else if now_ms.saturating_sub(last_ms) >= 5000 {
            let frames = FRAME_COUNT.swap(0, Ordering::Relaxed);
            let secs = now_ms.saturating_sub(last_ms) as f64 / 1000.0;
            tracing::info!(
                frames,
                fps = (frames as f64 / secs).round() as u64,
                "合成器帧率"
            );
            FRAME_LOG_MS.store(now_ms, Ordering::Relaxed);
        }
        FRAME_COUNT.fetch_add(1, Ordering::Relaxed);

        Ok(())
    }

    /// 当前主输出的显示状态：(宽, 高, 缩放×1000, 变换, 刷新率 mHz)。
    pub fn output_state_info(&self) -> Option<(i32, i32, u32, u32, u32)> {
        let output = self.output.as_ref()?;
        let mode = output.current_mode()?;
        let scale = output.current_scale().fractional_scale();
        Some((
            mode.size.w,
            mode.size.h,
            (scale * 1000.0).round() as u32,
            crate::backend::transform_code(output.current_transform()),
            mode.refresh.max(0) as u32,
        ))
    }

    /// 下发主输出状态（bind 时与每次变化后）。
    pub fn notify_output_state(&self) {
        if let Some((w, h, scale, transform, refresh)) = self.output_state_info() {
            let transform = crate::protocol::output_transform_from_code(transform);
            self.broadcast(|s| s.output_state(w as u32, h as u32, scale, transform, refresh));
        }
    }

    /// 应用运行时显示设置（缩放/模式/变换）并通知客户端。
    ///
    /// - 模式切换走后端（udev 改 DRM 模式）；
    /// - 缩放/变换更新 `wl_output` 状态，并对已有 surface 重发分数缩放；
    /// - 之后 kiosk 按新逻辑尺寸重新 configure 窗口并重绘。
    pub fn apply_output_config(&mut self) -> anyhow::Result<()> {
        let applied_mode = match self.backend.as_mut() {
            Some(backend) => backend.apply_output_config(
                self.output_scale,
                self.output_transform,
                self.output_mode,
            )?,
            None => None,
        };

        if let Some(output) = self.output.clone() {
            let scale = crate::backend::output_scale(self.output_scale);
            output.change_current_state(
                applied_mode,
                Some(self.output_transform),
                Some(scale),
                None,
            );
        }

        // 缩放变化要让已存在的表面重新拿到 preferred_scale（分数缩放）。
        self.refresh_fractional_scale();

        if let Some(rect) = self.output_rect() {
            crate::kiosk::reconfigure_all(&self.space, rect);
        }
        self.mark_dirty();
        self.schedule_redraw();
        self.notify_output_state();
        Ok(())
    }

    /// 把当前缩放重新下发给所有已订阅 `wp_fractional_scale_v1` 的表面。
    fn refresh_fractional_scale(&self) {
        let scale = self.output_scale.max(1.0);
        for window in self.space.elements() {
            window.with_surfaces(|_surface, states| {
                fractional_scale::with_fractional_scale(states, |fs| fs.set_preferred_scale(scale));
            });
        }
    }

    fn init_wayland_listener(
        display: Display<Self>,
        event_loop: &mut EventLoop<CalloopData>,
        requested_name: Option<&str>,
        client_count: Arc<AtomicUsize>,
    ) -> OsString {
        let listening_socket = match requested_name {
            Some(name) => ListeningSocketSource::with_name(name)
                .unwrap_or_else(|e| panic!("绑定 WAYLAND_DISPLAY={name} 失败: {e}")),
            None => ListeningSocketSource::new_auto().expect("创建 Wayland socket 失败"),
        };
        let socket_name = listening_socket.socket_name().to_os_string();

        let loop_handle = event_loop.handle();

        loop_handle
            .insert_source(listening_socket, move |client_stream, _, data| {
                let client_state = ClientState::new(client_count.clone());
                if let Err(err) = data
                    .display_handle
                    .insert_client(client_stream, Arc::new(client_state))
                {
                    tracing::warn!(%err, "接入客户端失败");
                }
            })
            .expect("注册 Wayland socket 事件源失败");

        loop_handle
            .insert_source(
                Generic::new(display, Interest::READ, Mode::Level),
                |_, display, data| {
                    // SAFETY: display 的生命周期由本事件源持有，直到事件循环结束。
                    let dispatched = unsafe {
                        display
                            .get_mut()
                            .dispatch_clients(&mut data.state)
                            .expect("dispatch_clients 失败")
                    };
                    tracing::trace!(dispatched, "display 事件");
                    // 任一客户端消息（缓冲提交 / 帧回调请求 / 协议请求）都可能改变画面。
                    // 标记并按需唤醒后端，取代「永远重绘」：无客户端活动时完全空闲。
                    data.state.mark_dirty();
                    data.state.schedule_redraw();
                    // 关键：把对客户端的回复（registry 全局、configure、帧回调）冲刷出去。
                    // 缺此步客户端会永远等不到回复（表现为卡死/黑屏）。
                    if let Err(err) = data.display_handle.flush_clients() {
                        tracing::warn!(%err, "flush_clients 失败");
                    }
                    Ok(PostAction::Continue)
                },
            )
            .expect("注册 display 事件源失败");

        socket_name
    }

    /// 当前主输出的几何矩形（kiosk 全屏目标）。
    pub fn output_rect(&self) -> Option<OutputRect> {
        let output = self.output.as_ref()?;
        self.space.output_geometry(output)
    }

    /// 指针命中的 (surface, 局部坐标)。
    pub fn surface_under(
        &self,
        pos: Point<f64, Logical>,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        self.space
            .element_under(pos)
            .and_then(|(window, location)| {
                window
                    .surface_under(
                        pos - location.to_f64(),
                        smithay::desktop::WindowSurfaceType::ALL,
                    )
                    .map(|(s, p)| (s, (p + location).to_f64()))
            })
    }

    /// 是否有客户端在线。
    pub fn client_count(&self) -> usize {
        self.client_count.load(Ordering::SeqCst)
    }

    /// 清理已断开客户端的协议句柄。
    pub fn prune_shell_clients(&mut self) {
        self.shell_clients.retain(|c| c.is_alive());
    }

    fn broadcast(&self, f: impl Fn(&ArchoeraShellV1)) {
        for client in &self.shell_clients {
            if client.is_alive() {
                f(client);
            }
        }
    }

    /// 新客户端绑定控制协议后，立即下发能力位与当前系统状态。
    pub fn send_initial_state(&self, shell: &ArchoeraShellV1) {
        shell.capabilities(self.control.capabilities().bits());
        if let Some(brightness) = self.control.brightness_percent() {
            shell.brightness_changed(brightness);
        }
        shell.volume_changed(self.control.volume());
        let battery = self.control.battery_state();
        shell.battery(
            battery.present as u32,
            battery.percent,
            battery.charging as u32,
        );
        if self.has_capability(Capability::Screen) {
            shell.screen_enabled_changed(self.control.screen_enabled() as u32);
        }
        if let Some((w, h, scale_milli, transform, refresh)) = self.output_state_info() {
            let transform = crate::protocol::output_transform_from_code(transform);
            shell.output_state(w as u32, h as u32, scale_milli, transform, refresh);
        }
        shell.session(self.session_state);
    }

    pub fn notify_capabilities(&self) {
        self.broadcast(|s| s.capabilities(self.control.capabilities().bits()));
    }

    pub fn notify_brightness(&self, percent: u32) {
        self.broadcast(|s| s.brightness_changed(percent));
    }

    pub fn notify_volume(&self) {
        self.broadcast(|s| s.volume_changed(self.control.volume()));
    }

    pub fn notify_battery(&self) {
        let b = self.control.battery_state();
        self.broadcast(|s| s.battery(b.present as u32, b.percent, b.charging as u32));
    }

    pub fn notify_media_key(&self, key: MediaKey) {
        self.broadcast(|s| s.media_key(key));
    }

    pub fn notify_power_key(&self, key: PowerKey) {
        self.broadcast(|s| s.power_key(key));
    }

    pub fn notify_screen_enabled(&self, enabled: bool) {
        self.broadcast(|s| s.screen_enabled_changed(enabled as u32));
    }

    pub fn notify_session(&self, state: SessionState) {
        self.broadcast(|s| s.session(state));
    }

    /// 能力位是否可用（供请求侧校验）。
    pub fn has_capability(&self, cap: Capability) -> bool {
        self.control.capabilities().contains(cap)
    }

    /// 标记需要重绘；随后由 [`Self::schedule_redraw`] 落到具体后端。
    pub fn mark_dirty(&mut self) {
        self.needs_redraw = true;
    }

    /// 当前是否有待合成的更新。
    pub fn needs_redraw(&self) -> bool {
        self.needs_redraw
    }

    /// DRM 帧已被 vblank 回收：允许下一次 `schedule_redraw` 立即合成。
    pub fn note_frame_submitted(&mut self) {
        self.frame_in_flight = false;
    }

    /// 把「需要重绘」落到后端：
    /// - winit：请求一次窗口重绘，真正的合成在 `WinitEvent::Redraw` 回调里；
    /// - udev：没有重绘事件，直接同步合成一帧（由下一次 vblank 回收）。
    pub fn schedule_redraw(&mut self) {
        if !self.needs_redraw {
            return;
        }
        // 熄屏期间不合成（udev 输出已暂停）：保持 dirty，亮屏时补一帧。
        if self.control.screen_supported() && !self.control.screen_enabled() {
            return;
        }

        // udev：已有一帧在飞行中时只保留 dirty，由 vblank 合并成一次合成。
        // 这是「一操作（点击/移动）就掉帧」的根因修复：输入事件可达上百 Hz，
        // 此前每个事件都会触发一次全屏合成，帧率立刻垮掉。
        #[cfg(feature = "udev")]
        let is_udev = matches!(self.backend, Some(Backend::Udev(_)));
        #[cfg(not(feature = "udev"))]
        let is_udev = false;
        if is_udev && self.frame_in_flight {
            // 自愈：超过 ~50ms 没有新的合成（约两帧 @60Hz），认为 vblank 丢了/被吞了，
            // 放行一次以免画面永久卡住。
            let now = monotonic_now().as_millis() as u64;
            if now.saturating_sub(self.last_render_ms) < 50 {
                return;
            }
            self.frame_in_flight = false;
        }
        let space = &self.space;
        let cursor = &self.cursor;
        if let Some(backend) = self.backend.as_mut() {
            if let Err(err) = backend.request_frame(space, cursor) {
                tracing::warn!(%err, "调度重绘失败");
            }
        }
    }

    /// 开关屏幕（DPMS），委派渲染后端；非 udev 后端为无操作。
    pub fn set_screen_power(&mut self, enabled: bool) -> anyhow::Result<()> {
        match self.backend.as_mut() {
            Some(backend) => backend.set_screen_power(enabled),
            None => Ok(()),
        }
    }

    /// 让 kiosk 焦点落在最上层窗口。
    pub fn focus_topmost(&mut self) {
        let serial = smithay::utils::SERIAL_COUNTER.next_serial();
        let top = self.space.elements().next_back().cloned();
        let keyboard = self.seat.get_keyboard().unwrap();
        match top {
            Some(window) => {
                if let Some(toplevel) = window.toplevel() {
                    keyboard.set_focus(self, Some(toplevel.wl_surface().clone()), serial);
                }
            }
            None => keyboard.set_focus(self, Option::<WlSurface>::None, serial),
        }
    }
}

/// 每客户端的合成器数据；持有会话客户端计数，在断开（Drop）时自动递减。
pub struct ClientState {
    pub compositor_state: CompositorClientState,
    counter: Arc<AtomicUsize>,
}

impl ClientState {
    pub fn new(counter: Arc<AtomicUsize>) -> Self {
        let count = counter.fetch_add(1, Ordering::SeqCst) + 1;
        tracing::debug!(count, "Wayland 客户端接入");
        Self {
            compositor_state: CompositorClientState::default(),
            counter,
        }
    }
}

impl Drop for ClientState {
    fn drop(&mut self) {
        let count = self.counter.fetch_sub(1, Ordering::SeqCst) - 1;
        tracing::debug!(count, "Wayland 客户端断开");
    }
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {}
}

/// 协议时间戳基准：**CLOCK_MONOTONIC**（毫秒级 Duration）。
///
/// Wayland 的 `wl_callback.done` / 输入事件时间戳按生态惯例（wlroots/weston）都是
/// 「自开机起的单调毫秒」。GTK/Flutter 的 frame clock 会拿它和自己的单调钟比对来推算
/// 刷新节拍；若传「合成器启动以来的时长」（anvil 例子的写法），客户端会算出离谱的
/// 间隔 → 抖动、卡顿。故统一取 CLOCK_MONOTONIC。
pub fn monotonic_now() -> std::time::Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: clock_gettime 只写 ts；CLOCK_MONOTONIC 在所有受支持平台上都可用。
    unsafe {
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts);
    }
    std::time::Duration::new(
        ts.tv_sec.max(0) as u64,
        ts.tv_nsec.clamp(0, 999_999_999) as u32,
    )
}

/// 输出的建议刷新间隔（客户端 frame callback 用）：wl_output 的 refresh 单位是 mHz，/// 这里换算成周期纳秒；拿不到当前模式时退回 60Hz。
fn frame_refresh(output: &Output) -> Option<std::time::Duration> {
    output
        .current_mode()
        .map(|m| std::time::Duration::from_nanos(1_000_000_000_000u64 / m.refresh.max(1) as u64))
        .or(Some(std::time::Duration::from_micros(16_667)))
}

// ── 帧率诊断（约每 5 秒一行 info；数值异常高说明客户端没有被节流）──────────
static FRAME_COUNT: AtomicU64 = AtomicU64::new(0);
static FRAME_LOG_MS: AtomicU64 = AtomicU64::new(0);

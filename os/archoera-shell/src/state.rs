//! 合成器全局状态与会话生命周期。
//!
//! `ArchoeraShell` 是 calloop 回调里被可变借用的中心状态：Wayland 前端各协议
//! 状态、Space/输出、座位、控制面、以及 `archoera_shell_v1` 的客户端句柄都在这里。

use std::{
    ffi::OsString,
    sync::{
        atomic::{AtomicUsize, Ordering},
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
    utils::{Logical, Point},
    wayland::{
        compositor::{CompositorClientState, CompositorState},
        dmabuf::{DmabufFeedbackBuilder, DmabufGlobal, DmabufState},
        idle_inhibit::IdleInhibitManagerState,
        output::OutputManagerState,
        selection::data_device::DataDeviceState,
        shell::xdg::{decoration::XdgDecorationState, XdgShellState},
        shm::ShmState,
        socket::ListeningSocketSource,
    },
};

use crate::{
    backend::Backend,
    cli::ShellConfig,
    control::ControlPlane,
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
    pub seat_state: SeatState<Self>,
    pub data_device_state: DataDeviceState,
    pub seat: Seat<Self>,

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
        let data_device_state = DataDeviceState::new::<Self>(&dh);
        let popups = PopupManager::default();

        // 注册 ArchoeraOS 控制协议全局对象。
        let _global = dh.create_global::<Self, ArchoeraShellV1, ()>(1, ());

        let mut seat_state = SeatState::new();
        let mut seat: Seat<Self> = seat_state.new_wl_seat(&dh, "archoera");
        seat.add_keyboard(Default::default(), 200, 25)
            .expect("创建键盘失败");
        seat.add_pointer();

        let control = ControlPlane::new(config.volume);
        let client_count = Arc::new(AtomicUsize::new(0));
        let socket_name = Self::init_wayland_listener(
            display,
            event_loop,
            config.socket_name.as_deref(),
            client_count.clone(),
        );
        let loop_signal = event_loop.get_signal();

        Self {
            start_time,
            socket_name,
            display_handle: dh,
            config,
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
            seat_state,
            data_device_state,
            seat,
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

    /// 合成并提交一帧：渲染全部输出、驱动客户端帧回调、清理已销毁的 popup。
    ///
    /// 调用即清空重绘标志：本帧合成的是「清零前」累积的全部状态。若渲染期间又有
    /// 客户端提交（不会发生：渲染不派发客户端消息），标志会被重新置位。
    pub fn render_frame(&mut self) -> anyhow::Result<()> {
        self.needs_redraw = false;
        tracing::trace!("合成一帧");

        if let Some(backend) = self.backend.as_mut() {
            backend.render(&self.space)?;
        }

        let elapsed = self.start_time.elapsed();
        let outputs: Vec<Output> = self.space.outputs().cloned().collect();
        for output in &outputs {
            self.space.elements().for_each(|window| {
                window.send_frame(output, elapsed, Some(std::time::Duration::ZERO), |_, _| {
                    Some(output.clone())
                })
            });
        }
        self.space.refresh();
        self.popups.cleanup();
        Ok(())
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
        let space = &self.space;
        if let Some(backend) = self.backend.as_mut() {
            if let Err(err) = backend.request_frame(space) {
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

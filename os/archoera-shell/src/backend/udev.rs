//! 裸机（DRM/KMS + libinput + libseat）后端。
//!
//! 目标：在没有现成桌面会话的机器上，直接接管显卡输出与输入设备，让
//! ArchoeraMusic 成为「开机即见」的唯一界面。
//!
//! ## 设计取向
//! - **普通用户即可**：设备经由 `libseat` 会话打开，不请求 root、不写系统目录；
//! - **单 GPU 优先**：kiosk 场景通常只有一块显卡，这里只驱动首个可用 DRM 设备，
//!   不做多 GPU 合成（`MultiRenderer`）。多卡机器建议在 BIOS/内核层固定主卡；
//! - **vblank 驱动**：每个 CRTC 用 `DrmOutput` + `DrmCompositor` 直接扫描输出，
//!   vblank 到达后回收上一帧并合成下一帧；
//! - 渲染器与 dmabuf 导入复用 [`crate::backend::Backend`] 的共享 `GlesRenderer`。
//!
//! ## 状态
//! 本后端**尚未在真实 DRM 硬件上验证**（开发机为 WSL2，无 `/dev/dri`）。
//! 编译需要系统提供 `libseat`（Arch：`extra/seatd`）、`libinput`、`libdrm`、`gbm`、
//! `libudev` 的开发文件。首次上机时请重点关注：连接器枚举、模式选择、vblank 回收。

use std::{collections::HashMap, path::PathBuf};

use smithay::{
    backend::{
        allocator::gbm::{GbmAllocator, GbmBufferFlags, GbmDevice},
        drm::{
            compositor::FrameFlags,
            exporter::gbm::GbmFramebufferExporter,
            output::{DrmOutput, DrmOutputManager, DrmOutputRenderElements},
            DrmDevice, DrmDeviceFd, DrmEvent, DrmNode,
        },
        egl::{context::EGLContext, EGLDisplay},
        libinput::{LibinputInputBackend, LibinputSessionInterface},
        renderer::gles::GlesRenderer,
        session::{libseat::LibSeatSession, Event as SessionEvent, Session},
        udev::{all_gpus, primary_gpu, UdevBackend as UdevDeviceMonitor, UdevEvent},
    },
    desktop::{Space, Window},
    output::{Mode as WlMode, Output, PhysicalProperties, Scale},
    reexports::{
        calloop::EventLoop,
        drm::control::{connector, crtc, Device as ControlDevice, ModeTypeFlags},
        input::Libinput,
        rustix::fs::OFlags,
        wayland_server::DisplayHandle,
    },
    utils::{DeviceFd, Transform},
};
use smithay_drm_extras::drm_scanner::{DrmScanEvent, DrmScanner};

use super::{Backend, OutputElement, CLEAR_COLOR};
use crate::{
    cursor::PointerElement, kiosk, protocol::SessionState, state::ArchoeraShell, CalloopData,
};

/// 优先尝试的扫描输出像素格式（10-bit 优先，回退 8-bit）。
const SUPPORTED_FORMATS: &[smithay::backend::allocator::Fourcc] = &[
    smithay::backend::allocator::Fourcc::Abgr2101010,
    smithay::backend::allocator::Fourcc::Argb2101010,
    smithay::backend::allocator::Fourcc::Abgr8888,
    smithay::backend::allocator::Fourcc::Argb8888,
];

type GbmAlloc = GbmAllocator<DrmDeviceFd>;
type GbmExport = GbmFramebufferExporter<DrmDeviceFd>;
type OutputManager = DrmOutputManager<GbmAlloc, GbmExport, (), DrmDeviceFd>;
type DrmOutputHandle = DrmOutput<GbmAlloc, GbmExport, (), DrmDeviceFd>;
/// 每输出渲染元素（桌面内容 + 指针光标）。
type UdevElements = OutputElement;

/// 单块 DRM 设备上的一个已点亮输出。
struct UdevSurface {
    drm_output: DrmOutputHandle,
    output: Output,
    /// 该输出对应的连接器（运行时切换模式需查其模式表）。
    connector: connector::Handle,
    /// 当前生效的 DRM 模式（用于判断是否需要切换）。
    mode: smithay::reexports::drm::control::Mode,
    /// 连接器名（如 eDP-1 / HDMI-A-1），供协议 output_info 使用。
    name: String,
    /// 该连接器支持的全部模式：(宽, 高, 刷新率 mHz)。
    modes: Vec<super::OutputMode>,
}

/// 裸机后端状态。
pub struct UdevBackend {
    renderer: GlesRenderer,
    manager: OutputManager,
    /// libseat 会话：即使不直接查询也必须持有——`drop` 会关闭它打开的所有设备。
    session: LibSeatSession,
    libinput: Libinput,
    surfaces: HashMap<crtc::Handle, UdevSurface>,
    /// 连接器扫描器：保留状态以支持热插拔增量扫描（Connected / Disconnected）。
    scanner: DrmScanner,
    /// 本次 render 是否真的向 DRM 提交了帧（空帧不提交、也就没有 vblank）。
    pub frame_queued: bool,
}

impl UdevBackend {
    pub fn renderer(&mut self) -> &mut GlesRenderer {
        &mut self.renderer
    }

    /// 切换 VT：转发给 libseat（logind 后端会做实际的 VT 切换与 DRM 主控交接）。
    pub fn change_vt(&mut self, vt: i32) -> anyhow::Result<()> {
        self.session
            .change_vt(vt)
            .map_err(|e| anyhow::anyhow!("libseat change_vt({vt}) 失败: {e}"))
    }

    /// 各输出的（连接器名, 模式列表）快照，按名字排序保证 id 稳定。
    pub fn output_meta(&self) -> Vec<super::OutputMeta> {
        let mut out: Vec<super::OutputMeta> = self
            .surfaces
            .values()
            .map(|s| (s.name.clone(), s.modes.clone()))
            .collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// 开关屏幕（DPMS）：暂停 / 重新激活 DRM 输出管理器。
    ///
    /// 与 VT 抢占复用同一机制（`pause` / `activate`）；熄屏期间 `schedule_redraw`
    /// 会保持 dirty 而不合成，亮屏后补一帧。
    pub fn set_screen_power(&mut self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.manager
                .activate(false)
                .map_err(|e| anyhow::anyhow!("点亮屏幕失败: {e:?}"))?;
        } else {
            self.manager.pause();
        }
        Ok(())
    }

    /// 运行时应用输出配置：按 `mode_pref` 为每个输出挑选并切换 DRM 模式。
    ///
    /// 缩放/变换由共享状态更新 `wl_output`（`DrmCompositor` 每帧从 `Output` 读取
    /// 当前变换），模式切换必须走 `use_mode`（会同时调整 swapchain）。返回实际
    /// 生效的模式（主输出），供上层同步 `wl_output`。
    pub fn apply_output_config(
        &mut self,
        _scale: f64,
        _transform: Transform,
        mode_pref: Option<(i32, i32)>,
    ) -> anyhow::Result<Option<smithay::output::Mode>> {
        let mut applied: Option<smithay::output::Mode> = None;
        for (crtc, surface) in self.surfaces.iter_mut() {
            let info = self
                .manager
                .device()
                .get_connector(surface.connector, true)
                .map_err(|e| anyhow::anyhow!("读取连接器模式失败: {e}"))?;
            let Some(mode) = pick_mode(&info, mode_pref) else {
                tracing::warn!(?crtc, "连接器没有匹配的显示模式，保持当前模式");
                continue;
            };
            if mode != surface.mode {
                surface
                    .drm_output
                    .use_mode(
                        mode,
                        &mut self.renderer,
                        &DrmOutputRenderElements::<GlesRenderer, UdevElements>::default(),
                    )
                    .map_err(|e| anyhow::anyhow!("切换输出模式失败: {e:?}"))?;
                surface.mode = mode;
                tracing::info!(?crtc, mode = ?mode, "DRM 输出模式已切换");
            }
            applied = Some(WlMode::from(mode));
        }
        Ok(applied)
    }

    /// 把名为 `name` 的输出切换到它模式表里的第 `index` 个模式。
    ///
    /// 与 `apply_output_config` 的区别：按 (宽, 高, **刷新率**) 三元组精确定位，
    /// 因此同分辨率的 165Hz / 60Hz 可以区分（KScreen 那种列表也才切得对）。
    pub fn set_output_mode_index(
        &mut self,
        name: &str,
        index: usize,
    ) -> anyhow::Result<Option<smithay::output::Mode>> {
        for surface in self.surfaces.values_mut() {
            if surface.name != name {
                continue;
            }
            let Some(&(w, h, refresh)) = surface.modes.get(index) else {
                return Ok(None);
            };
            let info = self
                .manager
                .device()
                .get_connector(surface.connector, true)
                .map_err(|e| anyhow::anyhow!("读取连接器模式失败: {e}"))?;
            let Some(mode) = info
                .modes()
                .iter()
                .find(|m| {
                    let sz = m.size();
                    sz.0 as i32 == w
                        && sz.1 as i32 == h
                        && m.vrefresh().saturating_mul(1000) == refresh
                })
                .copied()
            else {
                tracing::warn!(name, index, "该输出没有这个模式");
                return Ok(None);
            };
            if mode != surface.mode {
                surface
                    .drm_output
                    .use_mode(
                        mode,
                        &mut self.renderer,
                        &DrmOutputRenderElements::<GlesRenderer, UdevElements>::default(),
                    )
                    .map_err(|e| anyhow::anyhow!("切换输出模式失败: {e:?}"))?;
                surface.mode = mode;
                tracing::info!(name, index, mode = ?mode, "DRM 输出模式已按索引切换");
            }
            return Ok(Some(WlMode::from(mode)));
        }
        Ok(None)
    }

    /// 合成并提交所有输出的下一帧（桌面内容 + 指针光标）。
    pub fn render(
        &mut self,
        space: &Space<Window>,
        pointer: &PointerElement,
    ) -> anyhow::Result<()> {
        self.frame_queued = false;
        for (crtc, surface) in self.surfaces.iter_mut() {
            // DRM 合成器要求元素按「前 → 后」排列（最上层在前）：光标置顶，
            // 其后才是窗口与候选窗口，否则会被不透明的全屏窗口直接盖掉/跳过。
            let mut elements: Vec<UdevElements> = Vec::new();

            // 指针落在这个输出上才画光标（kiosk 通常只有一个输出）。
            if let Some(geo) = space.output_geometry(&surface.output) {
                let location = pointer.location();
                if geo.to_f64().contains(location) {
                    let scale = smithay::utils::Scale::from(
                        surface.output.current_scale().fractional_scale(),
                    );
                    let position = location - geo.loc.to_f64();
                    elements.extend(
                        pointer
                            .render_elements(&mut self.renderer, position, scale, 1.0)
                            .into_iter()
                            .map(OutputElement::from),
                    );
                }
            }

            match space.render_elements_for_output(&mut self.renderer, &surface.output, 1.0) {
                Ok(space_elements) => {
                    elements.extend(space_elements.into_iter().map(OutputElement::Space))
                }
                Err(err) => {
                    tracing::warn!(?crtc, %err, "收集渲染元素失败");
                    continue;
                }
            }

            match surface.drm_output.render_frame(
                &mut self.renderer,
                &elements,
                CLEAR_COLOR,
                FrameFlags::DEFAULT,
            ) {
                Ok(result) => {
                    if !result.is_empty {
                        match surface.drm_output.queue_frame(()) {
                            Ok(()) => self.frame_queued = true,
                            Err(err) => tracing::warn!(?crtc, ?err, "提交 DRM 帧失败"),
                        }
                    }
                }
                Err(err) => tracing::warn!(?crtc, ?err, "渲染 DRM 输出失败"),
            }
        }
        Ok(())
    }
}

/// 初始化 udev 后端：会话、输入、首个 DRM 设备与全部已连接输出。
pub fn init_udev(
    event_loop: &mut EventLoop<CalloopData>,
    data: &mut CalloopData,
) -> anyhow::Result<()> {
    // 1. libseat 会话（普通用户即可，无需 root / polkit）。
    //
    // libseat 会优先连 seatd（`/run/seatd.sock`），未运行时自动回退到 **logind**
    // 这一内置后端——因此无需常驻守护进程或 root；可用 `LIBSEAT_BACKEND`
    // 强制指定（`logind` / `seatd`）。
    let (mut session, session_notifier) =
        LibSeatSession::new().map_err(|e| anyhow::anyhow!("初始化 libseat 会话失败: {e}"))?;
    let seat_name = session.seat();
    tracing::info!(
        seat = %seat_name,
        backend = std::env::var("LIBSEAT_BACKEND").as_deref().unwrap_or("auto"),
        "libseat 会话就绪"
    );

    // 2. libinput（经会话打开设备）。
    let mut libinput_context =
        Libinput::new_with_udev::<LibinputSessionInterface<LibSeatSession>>(session.clone().into());
    libinput_context.udev_assign_seat(&seat_name).map_err(|_| {
        anyhow::anyhow!("libinput 绑定 seat `{seat_name}` 失败（seat 不存在或权限不足）")
    })?;
    let libinput_backend = LibinputInputBackend::new(libinput_context.clone());

    // 3. udev 设备监视（热插拔）。
    let udev_monitor = UdevDeviceMonitor::new(&seat_name)
        .map_err(|e| anyhow::anyhow!("初始化 udev 监视失败: {e}"))?;

    // 4. 选主 GPU 并打开。
    let path = pick_drm_device(&seat_name, data.state.config.drm_device.as_deref())?;
    let node = DrmNode::from_path(&path)
        .map_err(|e| anyhow::anyhow!("解析 DRM 节点 {} 失败: {e}", path.display()))?;
    tracing::info!(node = ?node, path = %path.display(), "使用主 GPU");

    let fd = session
        .open(
            &path,
            OFlags::RDWR | OFlags::CLOEXEC | OFlags::NOCTTY | OFlags::NONBLOCK,
        )
        .map_err(|e| anyhow::anyhow!("打开 DRM 设备失败: {e}"))?;
    let fd = DrmDeviceFd::new(DeviceFd::from(fd));

    let (drm, drm_notifier) = DrmDevice::new(fd.clone(), true)
        .map_err(|e| anyhow::anyhow!("初始化 DRM 设备失败: {e}"))?;
    let gbm = GbmDevice::new(fd).map_err(|e| anyhow::anyhow!("初始化 GBM 设备失败: {e}"))?;

    // 5. EGL + GLES 渲染器（与 winit 后端同一路径）。
    let egl_display = unsafe { EGLDisplay::new(gbm.clone()) }
        .map_err(|e| anyhow::anyhow!("创建 EGLDisplay 失败: {e}"))?;
    let context =
        EGLContext::new(&egl_display).map_err(|e| anyhow::anyhow!("创建 EGLContext 失败: {e}"))?;
    let mut renderer = unsafe { GlesRenderer::new(context) }
        .map_err(|e| anyhow::anyhow!("创建 GLES 渲染器失败: {e}"))?;

    // 6. DRM 输出管理器。
    let render_formats = renderer
        .egl_context()
        .dmabuf_render_formats()
        .iter()
        .copied()
        .collect::<Vec<_>>();
    let allocator = GbmAllocator::new(
        gbm.clone(),
        GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT,
    );
    let exporter = GbmFramebufferExporter::new(gbm.clone(), Some(node));
    let mut manager = OutputManager::new(
        drm,
        allocator,
        exporter,
        Some(gbm.clone()),
        SUPPORTED_FORMATS.iter().copied(),
        render_formats,
    );

    // 7. 扫描连接器并点亮输出。
    let mut scanner: DrmScanner = DrmScanner::new();
    let scan = scanner
        .scan_connectors(manager.device())
        .map_err(|e| anyhow::anyhow!("扫描 DRM 连接器失败: {e}"))?;

    let mut surfaces = HashMap::new();
    let mut cursor_x = 0;
    for event in scan.iter() {
        if let DrmScanEvent::Connected {
            connector,
            crtc: Some(crtc),
        } = event
        {
            match setup_output(
                &mut manager,
                &mut renderer,
                &data.display_handle,
                &mut data.state.space,
                &connector,
                crtc,
                cursor_x,
                data.state.output_mode,
                super::output_scale(data.state.output_scale),
                data.state.output_transform,
            ) {
                Ok((drm_output, output, mode)) => {
                    // 首个点亮的输出作为 kiosk 主输出：kiosk 策略据此给窗口发
                    // configure（否则 output_rect() 为 None，客户端永不显示）。
                    if data.state.output.is_none() {
                        data.state.output = Some(output.clone());
                    }
                    if let Some(geo) = data.state.space.output_geometry(&output) {
                        cursor_x += geo.size.w;
                    }
                    surfaces.insert(
                        crtc,
                        UdevSurface {
                            drm_output,
                            output,
                            connector: connector.handle(),

                            mode,
                            name: format!(
                                "{}-{}",
                                connector.interface().as_str(),
                                connector.interface_id()
                            ),
                            modes: connector
                                .modes()
                                .iter()
                                .map(|m| {
                                    let size = m.size();
                                    (
                                        size.0 as i32,
                                        size.1 as i32,
                                        m.vrefresh().saturating_mul(1000),
                                    )
                                })
                                .collect(),
                        },
                    );
                }
                Err(err) => tracing::warn!(?crtc, %err, "点亮连接器失败，跳过"),
            }
        }
    }

    if surfaces.is_empty() {
        anyhow::bail!("未找到任何可用显示输出（连接器均未连接或无 CRTC）");
    }
    tracing::info!(outputs = surfaces.len(), "DRM 输出已就绪");

    // 8. 上提到共享状态，并注册 dmabuf（v4 反馈，告知主渲染设备）。
    let mut backend = UdevBackend {
        renderer,
        manager,
        session,
        libinput: libinput_context.clone(),
        surfaces,
        scanner,
        frame_queued: false,
    };
    data.state
        .setup_dmabuf(backend.renderer(), Some(node.dev_id()));

    std::env::set_var("WAYLAND_DISPLAY", &data.state.socket_name);
    data.state.backend = Some(Backend::Udev(backend));
    // 裸机后端可经 DrmOutputManager 暂停/激活实现 DPMS 熄屏，置位该能力位。
    data.state.control.set_screen_supported(true);
    // 也可运行时切换输出模式/缩放/旋转（set_output_* 请求）。
    data.state.control.set_output_supported(true);

    // 首帧：事件驱动模型下没有客户端提交时也要先把底色画出来。
    data.state.mark_dirty();
    data.state.schedule_redraw();

    // 9. 事件源：libinput / 会话 / DRM vblank / udev 热插拔。
    event_loop
        .handle()
        .insert_source(libinput_backend, move |event, _, data| {
            data.state.process_input_event(event);
        })
        .map_err(|e| anyhow::anyhow!("注册 libinput 事件源失败: {e}"))?;

    event_loop
        .handle()
        .insert_source(session_notifier, move |event, _, data| match event {
            SessionEvent::PauseSession => {
                tracing::info!("会话被切换走，暂停渲染与输入");
                if let Some(Backend::Udev(backend)) = data.state.backend.as_mut() {
                    backend.libinput.suspend();
                    backend.manager.pause();
                }
            }
            SessionEvent::ActivateSession => {
                tracing::info!("会话恢复，重新激活输出");
                if let Some(Backend::Udev(backend)) = data.state.backend.as_mut() {
                    if backend.libinput.resume().is_err() {
                        tracing::warn!("恢复 libinput 失败");
                    }
                    if let Err(err) = backend.manager.activate(false) {
                        tracing::warn!(?err, "激活 DRM 输出失败");
                    }
                }
                data.state.mark_dirty();
                if let Err(err) = data.state.render_frame() {
                    tracing::warn!(%err, "恢复后重绘失败");
                }
            }
        })
        .map_err(|e| anyhow::anyhow!("注册会话事件源失败: {e}"))?;

    let primary_dev_id = node.dev_id();
    event_loop
        .handle()
        .insert_source(drm_notifier, move |event, _, data| match event {
            DrmEvent::VBlank(crtc) => {
                if let Some(Backend::Udev(backend)) = data.state.backend.as_mut() {
                    if let Some(surface) = backend.surfaces.get(&crtc) {
                        if let Err(err) = surface.drm_output.frame_submitted() {
                            tracing::warn!(?crtc, ?err, "回收 DRM 帧失败");
                        }
                        // 帧已上屏：允许下一次调度立即合成（合并帧的边界）。
                        data.state.note_frame_submitted();
                        // 帧已上屏 → 现在才通知客户端可以画下一帧（节拍关键）。
                        data.state.send_frame_callbacks();
                    }
                }
                // 事件驱动：仅在有新提交时合成；空帧不 queue_frame，vblank 自然停止，
                // 直至下一次 schedule_redraw 唤醒。
                if data.state.needs_redraw() {
                    if let Err(err) = data.state.render_frame() {
                        tracing::warn!(%err, "vblank 后重绘失败");
                    }
                }
            }
            DrmEvent::Error(err) => tracing::error!(?err, "DRM 设备错误"),
        })
        .map_err(|e| anyhow::anyhow!("注册 DRM 事件源失败: {e}"))?;

    event_loop
        .handle()
        .insert_source(udev_monitor, move |event, _, data| match event {
            UdevEvent::Added { device_id, path } => {
                tracing::info!(?device_id, path = %path.display(), "DRM 设备接入（单 GPU 后端暂不接管）");
            }
            UdevEvent::Changed { device_id } => {
                if device_id == primary_dev_id {
                    if let Err(err) = refresh_outputs(&mut data.state, &data.display_handle) {
                        tracing::warn!(%err, "重新扫描连接器失败");
                    }
                } else {
                    tracing::debug!(?device_id, "其它 DRM 设备状态变化");
                }
            }
            UdevEvent::Removed { device_id } => {
                if device_id == primary_dev_id {
                    tracing::warn!("主 DRM 设备被移除，结束会话");
                    data.state.notify_session(SessionState::ShuttingDown);
                    data.state.loop_signal.stop();
                }
            }
        })
        .map_err(|e| anyhow::anyhow!("注册 udev 事件源失败: {e}"))?;

    Ok(())
}

/// 选择主 DRM 设备：优先显式指定（`--drm-device` / `ARCHOERA_DRM_DEVICE`），
/// 否则用固件标注的主 GPU，再退化为首个可用 GPU。
fn pick_drm_device(seat: &str, forced: Option<&str>) -> anyhow::Result<PathBuf> {
    if let Some(forced) = forced {
        let path = PathBuf::from(forced);
        if !path.exists() {
            anyhow::bail!("指定的 DRM 设备不存在: {}", path.display());
        }
        tracing::info!(path = %path.display(), "使用显式指定的 DRM 设备");
        return Ok(path);
    }
    if let Ok(Some(path)) = primary_gpu(seat) {
        return Ok(path);
    }
    all_gpus(seat)
        .map_err(|e| anyhow::anyhow!("枚举 GPU 失败: {e}"))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("未找到可用 DRM 设备（/dev/dri 是否存在？）"))
}

/// 处理 DRM 连接器热插拔：增量扫描，点亮新连接器、移除已断开的输出，
/// 并在主输出消失时重新选择；一块输出都不剩则结束会话。
///
/// 注：kiosk 仍把播放器窗口放在**主输出**上，热插入的新输出只铺底色，
/// 不做跨屏窗口迁移（kiosk 单窗口语义）。本路径尚未在真实硬件上验证。
fn refresh_outputs(
    state: &mut ArchoeraShell,
    display_handle: &DisplayHandle,
) -> anyhow::Result<()> {
    {
        let Some(Backend::Udev(backend)) = state.backend.as_mut() else {
            return Ok(());
        };

        let scan = backend
            .scanner
            .scan_connectors(backend.manager.device())
            .map_err(|e| anyhow::anyhow!("扫描 DRM 连接器失败: {e}"))?;

        // 1) 移除已断开的输出。
        for event in scan.iter() {
            if let DrmScanEvent::Disconnected {
                connector,
                crtc: Some(crtc),
            } = event
            {
                if let Some(surface) = backend.surfaces.remove(&crtc) {
                    tracing::info!(
                        ?crtc,
                        output = %output_label(&connector),
                        "输出断开，移除"
                    );
                    state.space.unmap_output(&surface.output);
                }
            }
        }

        // 2) 点亮新接入的连接器（追加到现有输出右侧）。
        let mut next_x = state
            .space
            .outputs()
            .filter_map(|o| state.space.output_geometry(o))
            .map(|geo| geo.loc.x + geo.size.w)
            .max()
            .unwrap_or(0);
        for event in scan.iter() {
            if let DrmScanEvent::Connected {
                connector,
                crtc: Some(crtc),
            } = event
            {
                if backend.surfaces.contains_key(&crtc) {
                    continue;
                }
                match setup_output(
                    &mut backend.manager,
                    &mut backend.renderer,
                    display_handle,
                    &mut state.space,
                    &connector,
                    crtc,
                    next_x,
                    state.output_mode,
                    super::output_scale(state.output_scale),
                    state.output_transform,
                ) {
                    Ok((drm_output, output, mode)) => {
                        if let Some(geo) = state.space.output_geometry(&output) {
                            next_x += geo.size.w;
                        }
                        backend.surfaces.insert(
                            crtc,
                            UdevSurface {
                                drm_output,
                                output,
                                connector: connector.handle(),

                                mode,
                                name: format!(
                                    "{}-{}",
                                    connector.interface().as_str(),
                                    connector.interface_id()
                                ),
                                modes: connector
                                    .modes()
                                    .iter()
                                    .map(|m| {
                                        let size = m.size();
                                        (
                                            size.0 as i32,
                                            size.1 as i32,
                                            m.vrefresh().saturating_mul(1000),
                                        )
                                    })
                                    .collect(),
                            },
                        );
                    }
                    Err(err) => tracing::warn!(
                        ?crtc,
                        output = %output_label(&connector),
                        %err,
                        "点亮热插拔输出失败"
                    ),
                }
            }
        }
    }

    // 3) 主输出失效则重选；一块都不剩就结束会话。
    let primary_alive = match state.output.as_ref() {
        Some(primary) => {
            let name = primary.name();
            state.space.outputs().any(|o| o.name() == name)
        }
        None => false,
    };
    if primary_alive {
        state.mark_dirty();
        state.schedule_redraw();
        return Ok(());
    }

    let new_primary = state.space.outputs().next().cloned();
    match &new_primary {
        Some(output) => tracing::info!(output = %output.name(), "重新选择主输出"),
        None => tracing::warn!("已无可用输出，结束会话"),
    }
    state.output = new_primary;
    if state.output.is_some() {
        if let Some(rect) = state.output_rect() {
            kiosk::reconfigure_all(&state.space, rect);
        }
        state.mark_dirty();
        state.schedule_redraw();
    } else {
        state.notify_session(SessionState::ShuttingDown);
        state.loop_signal.stop();
    }
    Ok(())
}

/// 连接器的人类可读标识（如 `DP-1`）。
fn output_label(connector: &connector::Info) -> String {
    format!(
        "{}-{}",
        connector.interface().as_str(),
        connector.interface_id()
    )
}

/// 从连接器模式表挑选目标模式。
///
/// `mode_pref`（`--mode` / `set_output_mode`）存在时优先精确匹配该尺寸
/// （preferred 优先、刷新率更高者优先）；无匹配或未指定时回退 preferred、再回退首个。
// 保留 map_or：`is_none_or` 需要 Rust 1.82，而本 workspace 声明 1.80+。
#[allow(clippy::unnecessary_map_or)]
fn pick_mode(
    connector: &connector::Info,
    mode_pref: Option<(i32, i32)>,
) -> Option<smithay::reexports::drm::control::Mode> {
    connector
        .modes()
        .iter()
        .filter(|mode| {
            mode_pref.map_or(true, |(w, h)| {
                let size = mode.size();
                size.0 as i32 == w && size.1 as i32 == h
            })
        })
        .max_by_key(|mode| {
            (
                mode.mode_type().contains(ModeTypeFlags::PREFERRED) as u8,
                mode.vrefresh(),
            )
        })
        .or_else(|| {
            connector
                .modes()
                .iter()
                .find(|mode| mode.mode_type().contains(ModeTypeFlags::PREFERRED))
        })
        .or_else(|| connector.modes().first())
        .copied()
}

/// 在给定 CRTC 上点亮一个连接器，创建 Wayland `Output` 全局并返回 `DrmOutput`。
///
/// `mode_pref` 为期望分辨率（`--mode`）：在连接器模式中优先精确匹配该尺寸
/// （preferred 优先、刷新率更高者优先），无匹配则回退 preferred / 首个模式。
#[allow(clippy::too_many_arguments)]
fn setup_output(
    manager: &mut OutputManager,
    renderer: &mut GlesRenderer,
    display_handle: &DisplayHandle,
    space: &mut Space<Window>,
    connector: &connector::Info,
    crtc: crtc::Handle,
    x: i32,
    mode_pref: Option<(i32, i32)>,
    scale: Scale,
    transform: Transform,
) -> anyhow::Result<(
    DrmOutputHandle,
    Output,
    smithay::reexports::drm::control::Mode,
)> {
    // 保留 map_or：`is_none_or` 需要 Rust 1.82，而本 workspace 声明 1.80+。
    let mode =
        pick_mode(connector, mode_pref).ok_or_else(|| anyhow::anyhow!("连接器没有可用显示模式"))?;
    let wl_mode = WlMode::from(mode);

    let (phys_w, phys_h) = connector.size().unwrap_or((0, 0));
    let output = Output::new(
        format!(
            "{}-{}",
            connector.interface().as_str(),
            connector.interface_id()
        ),
        PhysicalProperties {
            size: (phys_w as i32, phys_h as i32).into(),
            subpixel: connector.subpixel().into(),
            make: "Unknown".into(),
            model: "Unknown".into(),
        },
    );
    let _global = output.create_global::<ArchoeraShell>(display_handle);
    output.set_preferred(wl_mode);

    let position = (x, 0).into();
    output.change_current_state(Some(wl_mode), Some(transform), Some(scale), Some(position));
    space.map_output(&output, position);

    let drm_output = manager
        .initialize_output::<GlesRenderer, UdevElements>(
            crtc,
            mode,
            &[connector.handle()],
            &output,
            None,
            renderer,
            &DrmOutputRenderElements::default(),
        )
        .map_err(|e| anyhow::anyhow!("初始化 DRM 输出失败: {e:?}"))?;

    tracing::info!(
        connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
        ?crtc,
        mode = ?mode,
        "已点亮输出"
    );

    Ok((drm_output, output, mode))
}

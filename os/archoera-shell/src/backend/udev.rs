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
        renderer::{element::surface::WaylandSurfaceRenderElement, gles::GlesRenderer},
        session::{libseat::LibSeatSession, Event as SessionEvent, Session},
        udev::{all_gpus, primary_gpu, UdevBackend as UdevDeviceMonitor, UdevEvent},
    },
    desktop::{space::SpaceRenderElements, Space, Window},
    output::{Mode as WlMode, Output, PhysicalProperties},
    reexports::{
        calloop::EventLoop,
        drm::control::{connector, crtc, ModeTypeFlags},
        input::Libinput,
        rustix::fs::OFlags,
        wayland_server::DisplayHandle,
    },
    utils::DeviceFd,
};
use smithay_drm_extras::drm_scanner::{DrmScanEvent, DrmScanner};

use super::{Backend, CLEAR_COLOR};
use crate::{protocol::SessionState, state::ArchoeraShell, CalloopData};

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
type UdevElements = SpaceRenderElements<GlesRenderer, WaylandSurfaceRenderElement<GlesRenderer>>;

/// 单块 DRM 设备上的一个已点亮输出。
struct UdevSurface {
    drm_output: DrmOutputHandle,
    output: Output,
}

/// 裸机后端状态。
pub struct UdevBackend {
    renderer: GlesRenderer,
    manager: OutputManager,
    /// libseat 会话：即使不直接查询也必须持有——`drop` 会关闭它打开的所有设备。
    #[allow(dead_code)]
    session: LibSeatSession,
    libinput: Libinput,
    surfaces: HashMap<crtc::Handle, UdevSurface>,
}

impl UdevBackend {
    pub fn renderer(&mut self) -> &mut GlesRenderer {
        &mut self.renderer
    }

    /// 合成并提交所有输出的下一帧。
    pub fn render(&mut self, space: &Space<Window>) -> anyhow::Result<()> {
        for (crtc, surface) in self.surfaces.iter_mut() {
            let elements =
                match space.render_elements_for_output(&mut self.renderer, &surface.output, 1.0) {
                    Ok(elements) => elements,
                    Err(err) => {
                        tracing::warn!(?crtc, %err, "收集渲染元素失败");
                        continue;
                    }
                };

            match surface.drm_output.render_frame(
                &mut self.renderer,
                &elements,
                CLEAR_COLOR,
                FrameFlags::DEFAULT,
            ) {
                Ok(result) => {
                    if !result.is_empty {
                        if let Err(err) = surface.drm_output.queue_frame(()) {
                            tracing::warn!(?crtc, ?err, "提交 DRM 帧失败");
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
    let (mut session, session_notifier) =
        LibSeatSession::new().map_err(|e| anyhow::anyhow!("初始化 libseat 会话失败: {e}"))?;
    let seat_name = session.seat();
    tracing::info!(seat = %seat_name, "libseat 会话就绪");

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
    let path = pick_drm_device(&seat_name)?;
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
            ) {
                Ok((drm_output, output)) => {
                    if let Some(geo) = data.state.space.output_geometry(&output) {
                        cursor_x += geo.size.w;
                    }
                    surfaces.insert(crtc, UdevSurface { drm_output, output });
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
    };
    data.state
        .setup_dmabuf(backend.renderer(), Some(node.dev_id()));

    std::env::set_var("WAYLAND_DISPLAY", &data.state.socket_name);
    data.state.backend = Some(Backend::Udev(backend));

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
                tracing::debug!(?device_id, "DRM 设备状态变化");
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

/// 选择主 DRM 设备：优先固件标注的主 GPU，否则取首个。
fn pick_drm_device(seat: &str) -> anyhow::Result<PathBuf> {
    if let Ok(Some(path)) = primary_gpu(seat) {
        return Ok(path);
    }
    all_gpus(seat)
        .map_err(|e| anyhow::anyhow!("枚举 GPU 失败: {e}"))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("未找到可用 DRM 设备（/dev/dri 是否存在？）"))
}

/// 在给定 CRTC 上点亮一个连接器，创建 Wayland `Output` 全局并返回 `DrmOutput`。
#[allow(clippy::too_many_arguments)]
fn setup_output(
    manager: &mut OutputManager,
    renderer: &mut GlesRenderer,
    display_handle: &DisplayHandle,
    space: &mut Space<Window>,
    connector: &connector::Info,
    crtc: crtc::Handle,
    x: i32,
) -> anyhow::Result<(DrmOutputHandle, Output)> {
    let mode = connector
        .modes()
        .iter()
        .find(|mode| mode.mode_type().contains(ModeTypeFlags::PREFERRED))
        .or_else(|| connector.modes().first())
        .copied()
        .ok_or_else(|| anyhow::anyhow!("连接器没有可用显示模式"))?;
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
    output.change_current_state(Some(wl_mode), None, None, Some(position));
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

    Ok((drm_output, output))
}

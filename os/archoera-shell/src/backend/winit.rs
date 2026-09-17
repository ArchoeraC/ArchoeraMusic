//! winit 嵌套后端：把合成器作为普通窗口跑在现有会话里。

use smithay::{
    backend::{
        renderer::{damage::OutputDamageTracker, gles::GlesRenderer},
        winit::{self, WinitEvent},
    },
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::calloop::EventLoop,
    utils::{Rectangle, Transform},
};

use super::{Backend, WinitBackend};
use crate::{kiosk, state::ArchoeraShell, CalloopData};

pub fn init_winit(
    event_loop: &mut EventLoop<CalloopData>,
    data: &mut CalloopData,
) -> anyhow::Result<()> {
    let (graphics, winit) =
        winit::init::<GlesRenderer>().map_err(|e| anyhow::anyhow!("初始化 winit 后端失败: {e}"))?;

    let size = graphics.window_size();
    let mode = Mode {
        size,
        refresh: 60_000,
    };

    let output = Output::new(
        "archoera-0".to_string(),
        PhysicalProperties {
            size: (0, 0).into(),
            subpixel: Subpixel::Unknown,
            make: "Archoera".into(),
            model: "Kiosk (winit)".into(),
        },
    );
    let _global = output.create_global::<ArchoeraShell>(&data.display_handle);
    output.change_current_state(
        Some(mode),
        Some(Transform::Normal),
        None,
        Some((0, 0).into()),
    );
    output.set_preferred(mode);

    data.state.space.map_output(&output, (0, 0));
    data.state.output = Some(output.clone());
    kiosk::reconfigure_all(&data.state.space, Rectangle::from_size(size.to_logical(1)));

    // 渲染后端上提到共享状态；renderer 需先借给 dmabuf 注册。
    let mut backend = WinitBackend {
        graphics,
        output: output.clone(),
        damage_tracker: OutputDamageTracker::from_output(&output),
    };
    data.state.setup_dmabuf(backend.renderer(), None);
    data.state.backend = Some(Backend::Winit(backend));

    // 让子进程（会话客户端）默认连到本合成器。
    std::env::set_var("WAYLAND_DISPLAY", &data.state.socket_name);

    event_loop
        .handle()
        .insert_source(winit, move |event, _, data| {
            let CalloopData {
                state,
                display_handle,
            } = data;

            match event {
                WinitEvent::Resized { size, .. } => {
                    if let Some(output) = state.output.clone() {
                        output.change_current_state(
                            Some(Mode {
                                size,
                                refresh: 60_000,
                            }),
                            None,
                            None,
                            None,
                        );
                    }
                    kiosk::reconfigure_all(&state.space, Rectangle::from_size(size.to_logical(1)));
                }
                WinitEvent::Input(event) => state.process_input_event(event),
                WinitEvent::Redraw => {
                    if let Err(err) = state.render_frame() {
                        tracing::error!(%err, "合成渲染失败");
                    }
                    if let Some(backend) = state.backend.as_ref() {
                        backend.request_redraw();
                    }
                    if let Err(err) = display_handle.flush_clients() {
                        tracing::warn!(%err, "刷出客户端事件失败");
                    }
                }
                WinitEvent::CloseRequested => {
                    tracing::info!("窗口关闭，结束会话");
                    state.loop_signal.stop();
                }
                _ => {}
            }
        })
        .map_err(|e| anyhow::anyhow!("注册 winit 事件源失败: {e}"))?;

    Ok(())
}

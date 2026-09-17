//! `archoera_shell_v1` 服务端处理器：全局绑定与请求分发。

use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New,
};

use crate::{
    protocol::{ArchoeraShellV1, Capability, Request, SessionState},
    state::ArchoeraShell,
};

impl GlobalDispatch<ArchoeraShellV1, ()> for ArchoeraShell {
    fn bind(
        state: &mut Self,
        _dhandle: &DisplayHandle,
        _client: &Client,
        resource: New<ArchoeraShellV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        let shell = data_init.init(resource, ());
        state.prune_shell_clients();
        state.send_initial_state(&shell);
        state.shell_clients.push(shell);
        tracing::info!(
            clients = state.shell_clients.len(),
            capabilities = state.control.capabilities().bits(),
            "archoera_shell_v1 客户端已绑定"
        );
    }
}

impl Dispatch<ArchoeraShellV1, ()> for ArchoeraShell {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &ArchoeraShellV1,
        request: Request,
        _data: &(),
        _dhandle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            Request::SetBrightness { percent } => {
                if !state.has_capability(Capability::Brightness) {
                    tracing::debug!("会话无亮度能力，忽略 set_brightness");
                    return;
                }
                if let Some(applied) = state.control.set_brightness(percent) {
                    state.notify_brightness(applied);
                }
            }
            Request::SetVolume { percent } => {
                state.control.set_volume(percent);
                state.notify_volume();
            }
            Request::PowerOff => begin_shutdown(state, ShutdownAction::PowerOff),
            Request::Reboot => begin_shutdown(state, ShutdownAction::Reboot),
            // destroy 由 wayland-server 处理析构；其余为协议未来扩展。
            _ => {}
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        _resource: &ArchoeraShellV1,
        _data: &(),
    ) {
        state.prune_shell_clients();
    }
}

#[derive(Debug, Clone, Copy)]
enum ShutdownAction {
    PowerOff,
    Reboot,
}

/// 统一的下电流程：先把会话状态广播给播放器（使其有机会保存/淡出），
/// 刷出事件后再向 logind 提交动作。
fn begin_shutdown(state: &mut ArchoeraShell, action: ShutdownAction) {
    if !state.has_capability(Capability::Power) {
        tracing::warn!(?action, "会话无电源能力，忽略电源请求");
        return;
    }

    state.session_state = SessionState::ShuttingDown;
    state.notify_session(SessionState::ShuttingDown);

    // `flush_clients` 借 `&mut DisplayHandle`；状态里的句柄可克隆出独立可变句柄，
    // 底层共享同一 backend handle，借此确保「即将关机」事件已写入客户端 socket。
    let mut dhandle = state.display_handle.clone();
    if let Err(err) = dhandle.flush_clients() {
        tracing::warn!(%err, "关机前刷出客户端事件失败");
    }

    let result = match action {
        ShutdownAction::PowerOff => state.control.power_off(),
        ShutdownAction::Reboot => state.control.reboot(),
    };

    match result {
        Ok(()) => tracing::info!(?action, "已提交系统电源动作"),
        Err(err) => tracing::error!(%err, ?action, "系统电源动作失败"),
    }
}

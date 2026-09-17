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
            Request::Suspend => begin_suspend(state, SuspendAction::Suspend),
            Request::Hibernate => begin_suspend(state, SuspendAction::Hibernate),
            Request::SetScreenEnabled { enabled } => set_screen_enabled(state, enabled != 0),
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

#[derive(Debug, Clone, Copy)]
enum SuspendAction {
    Suspend,
    Hibernate,
}

/// 挂起/休眠流程：先广播 `suspending`（播放器可保存 / 暂停），刷出事件后再提交。
///
/// logind 的 `Suspend` / `Hibernate` 是**同步阻塞**调用——它在系统恢复后才返回，
/// 因此这里会阻塞合成器事件循环（挂起期间本就无需响应）。成功返回后恢复到就绪态。
fn begin_suspend(state: &mut ArchoeraShell, action: SuspendAction) {
    if !state.has_capability(Capability::Suspend) {
        tracing::warn!(?action, "会话无挂起能力，忽略挂起请求");
        return;
    }

    let previous = state.session_state;
    state.session_state = SessionState::Suspending;
    state.notify_session(SessionState::Suspending);

    let mut dhandle = state.display_handle.clone();
    if let Err(err) = dhandle.flush_clients() {
        tracing::warn!(%err, "挂起前刷出客户端事件失败");
    }

    let result = match action {
        SuspendAction::Suspend => state.control.suspend(),
        SuspendAction::Hibernate => state.control.hibernate(),
    };

    // 无论成功（已恢复）还是失败，都回到挂起前的会话状态。
    state.session_state = previous;
    state.notify_session(previous);
    state.mark_dirty();
    state.schedule_redraw();

    match result {
        Ok(()) => tracing::info!(?action, "系统挂起完成并已恢复"),
        Err(err) => tracing::error!(%err, ?action, "系统挂起动作失败"),
    }
}

/// 开关屏幕（DPMS）。仅 `screen` 能力位可用时生效；udev 后端执行，其它后端无操作。
fn set_screen_enabled(state: &mut ArchoeraShell, enabled: bool) {
    if !state.has_capability(Capability::Screen) {
        tracing::debug!("会话无屏幕控制能力，忽略 set_screen_enabled");
        return;
    }
    if state.control.screen_enabled() == enabled {
        return;
    }

    match state.set_screen_power(enabled) {
        Ok(()) => {
            state.control.set_screen_enabled(enabled);
            state.notify_screen_enabled(enabled);
            // 亮屏后补一帧；熄屏时 schedule 会被跳过（保持 dirty）。
            state.mark_dirty();
            state.schedule_redraw();
            tracing::info!(enabled, "屏幕开关已切换");
        }
        Err(err) => tracing::warn!(%err, enabled, "屏幕开关失败"),
    }
}

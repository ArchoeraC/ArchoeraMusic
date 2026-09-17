//! ArchoeraOS 会话入口。
//!
//! 启动一个 kiosk Wayland 合成器，把它自己的 `WAYLAND_DISPLAY` 交给会话客户端
//! （ArchoeraMusic），客户端以全屏窗口构成整个系统界面。

mod backend;
mod cli;
mod control;
mod cursor;
mod handlers;
mod input;
mod kiosk;
mod protocol;
mod state;

use std::{ffi::OsStr, process::Child, time::Duration};

use smithay::reexports::{
    calloop::{
        timer::{TimeoutAction, Timer},
        EventLoop,
    },
    wayland_server::{Display, DisplayHandle},
};
use tracing_subscriber::EnvFilter;

use cli::ShellConfig;
use state::ArchoeraShell;

/// calloop 回调共享数据。
pub struct CalloopData {
    pub state: ArchoeraShell,
    pub display_handle: DisplayHandle,
}

fn main() -> anyhow::Result<()> {
    init_tracing();

    let config = ShellConfig::from_env()?;
    let mut event_loop: EventLoop<CalloopData> = EventLoop::try_new()?;
    let display: Display<ArchoeraShell> = Display::new()?;
    let display_handle = display.handle();
    let state = ArchoeraShell::new(&mut event_loop, display, config.clone());

    tracing::info!(
        socket = ?state.socket_name,
        backend = ?config.backend,
        capabilities = state.control.capabilities().bits(),
        "ArchoeraOS 会话启动"
    );

    let mut data = CalloopData {
        state,
        display_handle,
    };

    backend::init(&mut event_loop, &mut data)?;

    match &config.command {
        Some(argv) => {
            let child = spawn_session_app(argv, &data.state.socket_name)?;
            data.state.session_child = Some(child);
        }
        None => tracing::info!(
            socket = ?data.state.socket_name,
            "未指定会话命令，可用该 WAYLAND_DISPLAY 手动接入客户端"
        ),
    }

    if config.exit_on_close && config.command.is_some() {
        install_session_watchdog(&event_loop)?;
    }

    event_loop.run(None, &mut data, |_| {})?;

    // 会话结束：终止仍存活的会话客户端，避免留下孤儿进程。
    if let Some(mut child) = data.state.session_child.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
    tracing::info!("ArchoeraOS 会话结束");
    Ok(())
}

fn init_tracing() {
    match EnvFilter::try_from_default_env() {
        Ok(filter) => tracing_subscriber::fmt().with_env_filter(filter).init(),
        Err(_) => tracing_subscriber::fmt()
            .with_env_filter(EnvFilter::new("archoera_shell=info,warn"))
            .init(),
    }
}

/// 拉起会话客户端，并把合成器的 socket 注入其环境。
fn spawn_session_app(argv: &[String], socket_name: &OsStr) -> anyhow::Result<Child> {
    let (program, args) = argv
        .split_first()
        .ok_or_else(|| anyhow::anyhow!("会话命令为空"))?;

    let mut command = std::process::Command::new(program);
    command
        .args(args)
        .env("WAYLAND_DISPLAY", socket_name)
        // kiosk 标记：客户端据此关闭窗口装饰（无 WM 装饰，也不画 CSD 标题栏）。
        .env("ARCHOERA_KIOSK", "1")
        .env_remove("WAYLAND_SOCKET")
        .env_remove("DISPLAY");

    let child = command.spawn()?;
    tracing::info!(pid = child.id(), program, "已拉起会话客户端");
    Ok(child)
}

/// kiosk 看门狗：会话客户端进程退出（或全部 Wayland 客户端退出）后结束会话。
fn install_session_watchdog(event_loop: &EventLoop<CalloopData>) -> anyhow::Result<()> {
    let timer = Timer::from_duration(Duration::from_secs(1));
    event_loop
        .handle()
        .insert_source(timer, |_, _, data| {
            let state = &mut data.state;

            // 1) 合成器拉起的会话进程退出：最可靠的结束信号，不依赖 Wayland 断连检测
            //    （对持续渲染的客户端，客户端数量不一定能及时归零）。
            let child_exited = match state.session_child.as_mut() {
                Some(child) => matches!(child.try_wait(), Ok(Some(_)) | Err(_)),
                None => false,
            };
            if child_exited {
                tracing::info!("会话客户端进程已退出，结束 kiosk 会话");
                state.loop_signal.stop();
                return TimeoutAction::Drop;
            }

            // 2) 兜底：曾接入的 Wayland 客户端全部退出。
            if state.client_count() > 0 {
                state.had_client = true;
                return TimeoutAction::ToDuration(Duration::from_secs(1));
            }
            if state.had_client {
                tracing::info!("会话客户端全部退出，结束 kiosk 会话");
                state.loop_signal.stop();
                return TimeoutAction::Drop;
            }
            TimeoutAction::ToDuration(Duration::from_secs(1))
        })
        .map_err(|e| anyhow::anyhow!("注册会话看门狗失败: {e}"))?;
    Ok(())
}

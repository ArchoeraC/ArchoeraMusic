//! ArchoeraOS 会话入口。
//!
//! 启动一个 kiosk Wayland 合成器，把它自己的 `WAYLAND_DISPLAY` 交给会话客户端
//! （ArchoeraMusic），客户端以全屏窗口构成整个系统界面。

mod backend;
mod cli;
mod control;
mod handlers;
mod input;
mod kiosk;
mod protocol;
mod state;

use std::{ffi::OsStr, time::Duration};

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
        Some(argv) => spawn_session_app(argv, &data.state.socket_name)?,
        None => tracing::info!(
            socket = ?data.state.socket_name,
            "未指定会话命令，可用该 WAYLAND_DISPLAY 手动接入客户端"
        ),
    }

    if config.exit_on_close && config.command.is_some() {
        install_session_watchdog(&event_loop)?;
    }

    event_loop.run(None, &mut data, |_| {})?;
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
fn spawn_session_app(argv: &[String], socket_name: &OsStr) -> anyhow::Result<()> {
    let (program, args) = argv
        .split_first()
        .ok_or_else(|| anyhow::anyhow!("会话命令为空"))?;

    let mut command = std::process::Command::new(program);
    command
        .args(args)
        .env("WAYLAND_DISPLAY", socket_name)
        .env_remove("WAYLAND_SOCKET")
        .env_remove("DISPLAY");

    let child = command.spawn()?;
    tracing::info!(pid = child.id(), program, "已拉起会话客户端");
    Ok(())
}

/// kiosk 看门狗：客户端曾接入且全部退出后，结束整个会话。
fn install_session_watchdog(event_loop: &EventLoop<CalloopData>) -> anyhow::Result<()> {
    let timer = Timer::from_duration(Duration::from_secs(1));
    event_loop
        .handle()
        .insert_source(timer, |_, _, data| {
            let state = &mut data.state;
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

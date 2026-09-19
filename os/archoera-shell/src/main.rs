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

use std::{
    ffi::OsStr,
    process::Child,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use smithay::reexports::{
    calloop::{
        timer::{TimeoutAction, Timer},
        EventLoop,
    },
    wayland_server::{Display, DisplayHandle},
};
use smithay::wayland::input_method::InputMethodSeat;
use tracing_subscriber::EnvFilter;

use cli::ShellConfig;
use state::ArchoeraShell;

/// calloop 回调共享数据。
pub struct CalloopData {
    pub state: ArchoeraShell,
    pub display_handle: DisplayHandle,
}

/// SIGTERM/SIGINT 置位后由会话看门狗优雅收尾（终止会话客户端、退出事件循环）。
/// 直接在信号处理里做清理不安全，故只置位原子标志。
static TERMINATE: AtomicBool = AtomicBool::new(false);

extern "C" fn on_terminate(_sig: libc::c_int) {
    TERMINATE.store(true, Ordering::Relaxed);
}

/// 让 SIGTERM/SIGINT 走优雅退出：kiosk 会话脚本用它成对收尾合成器与输入法，
/// 避免进程被直接打死而留下孤儿的会话客户端。
fn install_signal_handlers() {
    // SAFETY: 处理器只做一次原子写，异步信号安全。
    unsafe {
        libc::signal(
            libc::SIGTERM,
            on_terminate as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            on_terminate as *const () as libc::sighandler_t,
        );
    }
}

fn main() -> anyhow::Result<()> {
    init_tracing();
    install_signal_handlers();

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

    // 始终安装：优雅响应 SIGTERM/SIGINT；exit_on_close 的客户端退出判定在源内部处理。
    install_session_watchdog(&event_loop)?;
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
/// 同时负责 SIGTERM/SIGINT 的优雅收尾与输入法断开检测。**始终安装**，以便
/// `--no-exit-on-close` 下仍能优雅响应终止信号。
fn install_session_watchdog(event_loop: &EventLoop<CalloopData>) -> anyhow::Result<()> {
    let timer = Timer::from_duration(Duration::from_secs(1));
    event_loop
        .handle()
        .insert_source(timer, |_, _, data| {
            let state = &mut data.state;

            // 0) SIGTERM/SIGINT：优雅退出（随后统一终止会话客户端，避免孤儿）。
            if TERMINATE.load(Ordering::Relaxed) {
                tracing::info!("收到终止信号，结束 kiosk 会话");
                state.loop_signal.stop();
                return TimeoutAction::Drop;
            }

            if !state.config.exit_on_close {
                return TimeoutAction::ToDuration(Duration::from_secs(1));
            }

            // 仅托管了会话命令时，客户端退出才代表会话结束（与旧行为一致）。
            let kiosk = state.config.command.is_some();

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

            // 1.5) 输入法看门狗：曾在线的 IME 断开 → 结束会话，让会话脚本成对重启
            //      合成器 + fcitx5。smithay 0.7 的 input-method 桥接在有旧实例时不会
            //      登记新实例（`add_instance` 只对旧实例发 unavailable），热重连会把
            //      输入法永久留在「无实例」状态，所以不断开会话就无法自愈。
            if state.config.ime_watch {
                // `has_instance` 是 crate 私有；用公开的 `keyboard_grabbed`：
                // fcitx5 的 Wayland 前端接入后必定抓取键盘，断开时抓取随对象销毁释放。
                let ime_connected = state.seat.input_method().keyboard_grabbed();
                if ime_connected {
                    if !state.ime_was_connected {
                        tracing::info!("输入法已接管键盘（keyboard grab 建立）");
                    }
                    state.ime_was_connected = true;
                    state.ime_disconnect_ticks = 0;
                } else if state.ime_was_connected {
                    // 去抖：连续 3 个周期（约 3s）仍无抓取才算真断开，避免瞬时释放误判。
                    state.ime_disconnect_ticks = state.ime_disconnect_ticks.saturating_add(1);
                    if state.ime_disconnect_ticks >= 3 {
                        tracing::warn!(
                            "输入法已在运行中断开，结束会话以成对重建桥接（可用 --no-ime-watch 关闭）"
                        );
                        state.loop_signal.stop();
                        return TimeoutAction::Drop;
                    }
                }
            }

            // 2) 兜底：曾接入的 Wayland 客户端全部退出（仅托管会话命令时）。
            if kiosk {
                if state.client_count() > 0 {
                    state.had_client = true;
                    return TimeoutAction::ToDuration(Duration::from_secs(1));
                }
                if state.had_client {
                    tracing::info!("会话客户端全部退出，结束 kiosk 会话");
                    state.loop_signal.stop();
                    return TimeoutAction::Drop;
                }
            }
            TimeoutAction::ToDuration(Duration::from_secs(1))
        })
        .map_err(|e| anyhow::anyhow!("注册会话看门狗失败: {e}"))?;
    Ok(())
}

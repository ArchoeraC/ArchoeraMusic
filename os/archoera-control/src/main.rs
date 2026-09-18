//! ArchoeraOS 控制面客户端 / 命令行工具。
//!
//! 通过自定义 `archoera_shell_v1` 协议与 `archoera-shell` 合成器通信：读取会话能力位与
//! 系统状态（亮度 / 音量 / 电量 / 会话态），并下发亮度、音量、关机、重启等会话级请求。
//!
//! 它同时是协议的端到端验证器——两端由同一份 XML 生成绑定，因此只要本工具能编译并
//! 与合成器完成一次请求/响应往返，就证明协议连线成立。
//!
//! 用法：
//! ```text
//! archoera-control [--socket <name>] [status|watch|brightness <0-100>|volume <0-100>|power-off|reboot]
//! ```

mod protocol;

use std::{env, process::ExitCode};

use anyhow::{bail, Context, Result};
use wayland_client::{
    globals::{registry_queue_init, GlobalListContents},
    protocol::wl_registry,
    Connection, Dispatch, QueueHandle,
};

use protocol::{
    ArchoeraShellV1, Capability, Event, MediaKey, OutputTransform, PowerKey, SessionState,
};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("archoera-control: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let (socket, command) = Cli::parse(env::args().skip(1))?;
    if let Some(name) = socket {
        // wayland-client 的 `connect_to_env` 读的是环境变量，这里代为设置。
        env::set_var("WAYLAND_DISPLAY", &name);
    }

    let conn = Connection::connect_to_env().context(
        "连接 Wayland 失败：请确认 WAYLAND_DISPLAY 指向 archoera-shell（或传 --socket）",
    )?;
    let (globals, mut queue) =
        registry_queue_init::<ControlState>(&conn).context("初始化 Wayland registry 失败")?;
    let qh = queue.handle();
    let shell: ArchoeraShellV1 = globals
        .bind(&qh, 1..=2, ())
        .context("合成器未提供 archoera_shell_v1 全局对象（当前会话不是 ArchoeraOS？）")?;

    let mut state = ControlState::default();

    match command {
        Command::Help => print_usage(),
        Command::Status => {
            queue.roundtrip(&mut state).context("读取初始状态失败")?;
            print_status(&state);
        }
        Command::Watch => {
            state.verbose = true;
            queue.roundtrip(&mut state).context("读取初始状态失败")?;
            print_status(&state);
            println!("—— 持续监听会话事件（Ctrl-C 退出）——");
            loop {
                queue
                    .blocking_dispatch(&mut state)
                    .context("事件循环结束")?;
            }
        }
        Command::Brightness(percent) => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Brightness, "亮度");
            shell.set_brightness(percent);
            queue.roundtrip(&mut state).context("提交亮度请求失败")?;
            match state.brightness {
                Some(applied) => println!("亮度 → {applied}%"),
                None => println!("亮度请求已发送，但当前会话没有可选背光设备（未落地）"),
            }
        }
        Command::Volume(percent) => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Volume, "音量");
            shell.set_volume(percent);
            queue.roundtrip(&mut state).context("提交音量请求失败")?;
            println!("音量 → {}%", state.volume.unwrap_or(percent));
        }
        Command::PowerOff => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Power, "电源");
            shell.power_off();
            let _ = queue.roundtrip(&mut state);
            println!("已提交关机请求");
        }
        Command::Reboot => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Power, "电源");
            shell.reboot();
            let _ = queue.roundtrip(&mut state);
            println!("已提交重启请求");
        }
        Command::Suspend => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Suspend, "挂起");
            shell.suspend();
            let _ = queue.roundtrip(&mut state);
            println!("已提交挂起请求（系统恢复后返回）");
        }
        Command::Hibernate => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Suspend, "休眠");
            shell.hibernate();
            let _ = queue.roundtrip(&mut state);
            println!("已提交休眠请求");
        }
        Command::Screen(on) => {
            queue.roundtrip(&mut state).context("读取初始能力失败")?;
            warn_if_unsupported(&state, Capability::Screen, "屏幕控制");
            shell.set_screen_enabled(on as u32);
            queue.roundtrip(&mut state).context("提交屏幕请求失败")?;
            match state.screen {
                Some(current) if current != on => println!("屏幕请求已发送"),
                Some(_) => println!("屏幕 → {}", if on { "开" } else { "关" }),
                None => println!("屏幕请求已发送（当前会话未通告屏幕状态）"),
            }
        }
    }

    Ok(())
}

/// 已从合成器获知的会话状态快照。
#[derive(Default)]
struct ControlState {
    caps: Option<Capability>,
    brightness: Option<u32>,
    volume: Option<u32>,
    /// (是否插电, 电量百分比, 是否充电中)
    battery: Option<(bool, u32, bool)>,
    session: Option<SessionState>,
    /// 屏幕开关（DPMS）；仅 udev 后端会下发。
    screen: Option<bool>,
    /// 主输出状态 (宽, 高, 缩放×1000, 刷新率 mHz)。
    output: Option<(u32, u32, u32, u32)>,
    /// `watch` 模式下随事件逐条打印。
    verbose: bool,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for ControlState {
    fn event(
        _state: &mut Self,
        _proxy: &wl_registry::WlRegistry,
        _event: wl_registry::Event,
        _data: &GlobalListContents,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        // 全局列表由 `GlobalListContents` 自身维护，这里无需处理。
    }
}

impl Dispatch<ArchoeraShellV1, ()> for ControlState {
    fn event(
        state: &mut Self,
        _proxy: &ArchoeraShellV1,
        event: Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            Event::Capabilities { flags } => {
                state.caps = Some(Capability::from_bits_truncate(flags));
            }
            Event::BrightnessChanged { percent } => {
                state.brightness = Some(percent);
                if state.verbose {
                    println!("亮度: {percent}%");
                }
            }
            Event::VolumeChanged { percent } => {
                state.volume = Some(percent);
                if state.verbose {
                    println!("音量: {percent}%");
                }
            }
            Event::MediaKey { key } => {
                println!("媒体键: {}", media_key_label(key.into_result().ok()));
            }
            Event::PowerKey { key } => {
                println!("电源键: {}", power_key_label(key.into_result().ok()));
            }
            Event::Battery {
                present,
                percent,
                charging,
            } => {
                state.battery = Some((present != 0, percent, charging != 0));
                if state.verbose {
                    println!("{}", format_battery(state.battery.unwrap()));
                }
            }
            Event::Session { state: session } => {
                let session = session.into_result().unwrap_or(SessionState::Ready);
                state.session = Some(session);
                if state.verbose {
                    println!(
                        "会话: {}",
                        match session {
                            SessionState::Ready => "就绪",
                            SessionState::ShuttingDown => "即将结束（关机/重启/退出）",
                            SessionState::Suspending => "即将挂起/休眠",
                        }
                    );
                }
            }
            Event::ScreenEnabledChanged { enabled } => {
                state.screen = Some(enabled != 0);
                if state.verbose {
                    println!("屏幕: {}", if enabled != 0 { "开" } else { "关" });
                }
            }
            Event::OutputState {
                width,
                height,
                scale_milli,
                transform,
                refresh_millihz,
            } => {
                state.output = Some((width, height, scale_milli, refresh_millihz));
                if state.verbose {
                    println!(
                        "输出: {width}x{height} @ {:.3}Hz 缩放 {:.1}% 变换 {}",
                        refresh_millihz as f64 / 1000.0,
                        scale_milli as f64 / 10.0,
                        match transform.into_result().unwrap_or(OutputTransform::Normal) {
                            OutputTransform::Normal => "normal",
                            OutputTransform::_90 => "90",
                            OutputTransform::_180 => "180",
                            OutputTransform::_270 => "270",
                            OutputTransform::Flipped => "flipped",
                            OutputTransform::Flipped90 => "flipped-90",
                            OutputTransform::Flipped180 => "flipped-180",
                            OutputTransform::Flipped270 => "flipped-270",
                        }
                    );
                }
            }
        }
    }
}

fn print_status(state: &ControlState) {
    let caps = state.caps.unwrap_or_else(Capability::empty);
    println!("能力: {}", format_caps(caps));
    println!(
        "亮度: {}",
        state
            .brightness
            .map(|p| format!("{p}%"))
            .unwrap_or_else(|| "不可用".into())
    );
    println!(
        "音量: {}",
        state
            .volume
            .map(|p| format!("{p}%"))
            .unwrap_or_else(|| "不可用".into())
    );
    if let Some(battery) = state.battery {
        println!("{}", format_battery(battery));
    }
    if let Some(screen) = state.screen {
        println!("屏幕: {}", if screen { "开" } else { "关" });
    }
    if let Some((w, h, scale_milli, refresh_millihz)) = state.output {
        println!(
            "输出: {w}x{h} @ {:.3}Hz 缩放 {:.1}%",
            refresh_millihz as f64 / 1000.0,
            scale_milli as f64 / 10.0
        );
    }
    let session = state.session.unwrap_or(SessionState::Ready);
    println!(
        "会话: {}",
        match session {
            SessionState::Ready => "就绪",
            SessionState::ShuttingDown => "即将结束",
            SessionState::Suspending => "即将挂起/休眠",
        }
    );
}

fn format_caps(caps: Capability) -> String {
    let mut names = Vec::new();
    for (cap, name) in [
        (Capability::Brightness, "brightness"),
        (Capability::Power, "power"),
        (Capability::Volume, "volume"),
        (Capability::MediaKeys, "media_keys"),
        (Capability::Battery, "battery"),
        (Capability::Suspend, "suspend"),
        (Capability::PowerKey, "power_key"),
        (Capability::Screen, "screen"),
        (Capability::Output, "output"),
        (Capability::Keyboard, "keyboard"),
    ] {
        if caps.contains(cap) {
            names.push(name);
        }
    }
    if names.is_empty() {
        "无（只读会话）".into()
    } else {
        names.join(", ")
    }
}

fn format_battery((present, percent, charging): (bool, u32, bool)) -> String {
    if !present {
        "电池: 无".into()
    } else {
        format!(
            "电池: {percent}%{}",
            if charging { "（充电中）" } else { "" }
        )
    }
}

fn media_key_label(key: Option<MediaKey>) -> &'static str {
    match key {
        Some(MediaKey::PlayPause) => "播放/暂停",
        Some(MediaKey::Next) => "下一曲",
        Some(MediaKey::Previous) => "上一曲",
        Some(MediaKey::Stop) => "停止",
        Some(MediaKey::VolumeUp) => "音量+",
        Some(MediaKey::VolumeDown) => "音量-",
        Some(MediaKey::Mute) => "静音",
        None => "未知",
    }
}

fn power_key_label(key: Option<PowerKey>) -> &'static str {
    match key {
        Some(PowerKey::Power) => "电源键",
        Some(PowerKey::Sleep) => "睡眠键",
        Some(PowerKey::Suspend) => "挂起键",
        None => "未知",
    }
}

fn warn_if_unsupported(state: &ControlState, cap: Capability, what: &str) {
    if let Some(caps) = state.caps {
        if !caps.contains(cap) {
            eprintln!("提示：当前会话未通告 {what} 能力，合成器会忽略该请求");
        }
    }
}

/// 解析后的命令。
enum Command {
    Help,
    Status,
    Watch,
    Brightness(u32),
    Volume(u32),
    PowerOff,
    Reboot,
    Suspend,
    Hibernate,
    /// 屏幕开关（true = 点亮）。
    Screen(bool),
}

struct Cli;

impl Cli {
    /// 解析 `[--socket <name>] [command]`。返回 (socket, command)。
    fn parse(args: impl Iterator<Item = String>) -> Result<(Option<String>, Command)> {
        let args: Vec<String> = args.collect();
        let mut i = 0;
        let mut socket = None;

        while i < args.len() {
            match args[i].as_str() {
                "--socket" | "-s" => {
                    let name = args
                        .get(i + 1)
                        .cloned()
                        .context("--socket 需要一个参数（WAYLAND_DISPLAY 名称）")?;
                    socket = Some(name);
                    i += 2;
                }
                "--help" | "-h" => return Ok((socket, Command::Help)),
                _ => break,
            }
        }

        let rest = &args[i..];
        let command = match rest.first().map(String::as_str) {
            None | Some("status") => Command::Status,
            Some("watch" | "listen") => Command::Watch,
            Some("help") => Command::Help,
            Some("brightness") => Command::Brightness(parse_percent(rest.get(1))?),
            Some("volume") => Command::Volume(parse_percent(rest.get(1))?),
            Some("power-off" | "poweroff") => Command::PowerOff,
            Some("reboot") => Command::Reboot,
            Some("suspend") => Command::Suspend,
            Some("hibernate") => Command::Hibernate,
            Some("screen") => Command::Screen(parse_on_off(rest.get(1))?),
            Some(other) => bail!("未知命令 `{other}`（--help 查看用法）"),
        };
        Ok((socket, command))
    }
}

fn parse_percent(arg: Option<&String>) -> Result<u32> {
    let raw = arg.context("该命令需要一个 0-100 的百分比参数")?;
    let value: u32 = raw
        .parse()
        .with_context(|| format!("`{raw}` 不是合法的百分比"))?;
    Ok(value.min(100))
}

/// 解析屏幕开关参数：`on`/`1`/`true` 为点亮，`off`/`0`/`false` 为熄屏。
fn parse_on_off(arg: Option<&String>) -> Result<bool> {
    match arg.map(String::as_str) {
        Some("on" | "1" | "true" | "yes") => Ok(true),
        Some("off" | "0" | "false" | "no") => Ok(false),
        Some(other) => bail!("`{other}` 不是合法的屏幕状态（on / off）"),
        None => bail!("screen 命令需要 on 或 off 参数"),
    }
}

fn print_usage() {
    println!(
        "\
archoera-control —— ArchoeraOS 控制面客户端

用法:
  archoera-control [--socket <name>] [命令]

命令:
  status（默认）      打印能力位与当前系统状态
  watch               持续监听并打印会话事件（媒体键 / 亮度 / 电量）
  brightness <0-100>  设置背光亮度
  volume <0-100>      设置会话音量
  power-off           关闭系统电源
  reboot              重启系统
  suspend             挂起系统到内存（恢复后返回）
  hibernate           休眠系统到磁盘
  screen <on|off>     开关屏幕（DPMS，仅 udev 后端）

选项:
  -s, --socket <name> 指定 WAYLAND_DISPLAY（默认读环境变量）
  -h, --help          显示本帮助"
    );
}

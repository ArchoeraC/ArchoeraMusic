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

use protocol::{ArchoeraShellV1, Capability, Event, MediaKey, SessionState};

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
        .bind(&qh, 1..=1, ())
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
    let session = state.session.unwrap_or(SessionState::Ready);
    println!(
        "会话: {}",
        match session {
            SessionState::Ready => "就绪",
            SessionState::ShuttingDown => "即将结束",
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

选项:
  -s, --socket <name> 指定 WAYLAND_DISPLAY（默认读环境变量）
  -h, --help          显示本帮助"
    );
}

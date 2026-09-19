//! 命令行与会话配置解析。
//!
//! 设计取向：kiosk 合成器的启动参数保持极小——一个 socket 名、一条要托管的
//! 会话命令、以及退出策略。其余行为（全屏、无装饰、单实例）由 kiosk 策略固定。

use std::ffi::OsString;

/// 合成器运行后端。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// 嵌套运行在已有 Wayland/WSLg 会话中（开发与测试）。
    Winit,
    /// 直接接管 DRM/KMS + libinput（裸机 / 虚拟机控制台）。
    Udev,
}

/// kiosk 输出变换（旋转 / 镜像）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransformKind {
    Normal,
    R90,
    R180,
    R270,
    Flipped,
    Flipped90,
    Flipped180,
    Flipped270,
}

impl TransformKind {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "normal" => Self::Normal,
            "90" => Self::R90,
            "180" => Self::R180,
            "270" => Self::R270,
            "flipped" => Self::Flipped,
            "flipped90" => Self::Flipped90,
            "flipped180" => Self::Flipped180,
            "flipped270" => Self::Flipped270,
            _ => return None,
        })
    }
}

/// 会话启动配置。
#[derive(Debug, Clone)]
pub struct ShellConfig {
    /// `WAYLAND_DISPLAY` 名；`None` 表示自动选择下一个可用名。
    pub socket_name: Option<String>,
    /// 要托管的会话命令（空表示不自动拉起客户端）。
    pub command: Option<Vec<String>>,
    /// 客户端全部退出时是否结束会话（kiosk 默认 true）。
    pub exit_on_close: bool,
    /// 初始会话音量（0-100）。
    pub volume: u32,
    /// 运行后端。
    pub backend: BackendKind,
    /// 是否允许第二个 toplevel（默认 false：kiosk 单窗口）。
    pub allow_multiple: bool,
    /// 指定 DRM 设备节点（如 `/dev/dri/card1`）；`None` 用固件主 GPU 或首个。
    pub drm_device: Option<String>,
    /// 期望输出分辨率（宽, 高）；udev 后端据此挑选连接器模式，`None` 用 preferred。
    pub mode: Option<(i32, i32)>,
    /// 输出缩放（>0；1.0 = 100%）。整数用于 wl_output，分数用于 wp_fractional_scale。
    pub scale: f64,
    /// 输出变换（旋转/镜像）。
    pub transform: TransformKind,
    /// 输入法看门狗：**曾在线的 IME 断开后结束会话**（会话脚本据此成对重启
    /// 合成器 + fcitx5）。smithay 0.7 的 input-method 桥接不支持热重连——有旧实例
    /// 时 `add_instance` 只会对旧实例发 `unavailable` 却不登记新实例，重连会永久
    /// 打断输入法。故宁可结束会话重建。`--no-ime-watch` 可关闭。
    pub ime_watch: bool,
}

impl Default for ShellConfig {
    fn default() -> Self {
        Self {
            socket_name: None,
            command: None,
            exit_on_close: true,
            volume: 100,
            backend: BackendKind::Winit,
            allow_multiple: false,
            drm_device: None,
            mode: None,
            scale: 1.0,
            transform: TransformKind::Normal,
            ime_watch: true,
        }
    }
}

impl ShellConfig {
    /// 从 `argv` / 环境变量解析配置。
    ///
    /// 约定：
    /// - `--socket <name>`：固定 `WAYLAND_DISPLAY`；
    /// - `-c, --command <line>`：按空白拆分的命令；
    /// - `-- <argv...>`：剩余参数整体作为命令（可含带空格参数）；
    /// - `--backend winit|udev`；
    /// - `--no-exit-on-close`：客户端全退后不结束会话；
    /// - `--no-ime-watch`：输入法断开后不结束会话（默认结束以成对重建桥接）；
    /// - `--allow-multiple`：允许第二个 toplevel（默认 kiosk 单窗口）；
    /// - `--drm-device <path>`：udev 后端指定 DRM 节点；
    /// - `--volume <n>`；
    /// - `ARCHOERA_SESSION_APP` / `ARCHOERA_DRM_DEVICE`：未显式给值时的环境兜底。
    pub fn from_env() -> anyhow::Result<Self> {
        Self::from_args(std::env::args_os())
    }

    pub fn from_args<I>(args: I) -> anyhow::Result<Self>
    where
        I: IntoIterator<Item = OsString>,
    {
        let mut cfg = ShellConfig::default();
        let mut iter = args.into_iter();
        let _argv0 = iter.next();
        let mut rest: Vec<OsString> = iter.collect();

        let mut i = 0;
        while i < rest.len() {
            let arg = rest[i].to_string_lossy().into_owned();
            match arg.as_str() {
                "-h" | "--help" => {
                    print_help();
                    std::process::exit(0);
                }
                "--socket" => {
                    i += 1;
                    cfg.socket_name = Some(take(&rest, i, "--socket")?);
                }
                "-c" | "--command" => {
                    i += 1;
                    let line = take(&rest, i, "--command")?;
                    cfg.command = Some(split_whitespace(&line));
                }
                "--volume" => {
                    i += 1;
                    let v = take(&rest, i, "--volume")?;
                    cfg.volume = v.parse().unwrap_or(100).min(100);
                }
                "--backend" => {
                    i += 1;
                    let b = take(&rest, i, "--backend")?;
                    cfg.backend = match b.as_str() {
                        "winit" => BackendKind::Winit,
                        "udev" => BackendKind::Udev,
                        other => anyhow::bail!("未知后端 `{other}`（可选 winit / udev）"),
                    };
                }
                "--no-exit-on-close" => cfg.exit_on_close = false,
                "--no-ime-watch" => cfg.ime_watch = false,
                "--allow-multiple" => cfg.allow_multiple = true,
                "--drm-device" => {
                    i += 1;
                    cfg.drm_device = Some(take(&rest, i, "--drm-device")?);
                }
                "--mode" => {
                    i += 1;
                    let raw = take(&rest, i, "--mode")?;
                    cfg.mode = Some(parse_mode(&raw)?);
                }
                "--scale" => {
                    i += 1;
                    let raw = take(&rest, i, "--scale")?;
                    let scale: f64 = raw
                        .parse()
                        .map_err(|_| anyhow::anyhow!("`{raw}` 不是合法的缩放倍数"))?;
                    if !(0.25..=4.0).contains(&scale) {
                        anyhow::bail!("--scale 需在 0.25..=4.0 之间（当前 {scale}）");
                    }
                    cfg.scale = scale;
                }
                "--transform" => {
                    i += 1;
                    let raw = take(&rest, i, "--transform")?;
                    cfg.transform = TransformKind::parse(&raw).ok_or_else(|| {
                        anyhow::anyhow!(
                            "未知变换 `{raw}`（normal/90/180/270/flipped/flipped90/flipped180/flipped270）"
                        )
                    })?;
                }
                "--" => {
                    let argv: Vec<String> = rest
                        .drain(i + 1..)
                        .map(|s| s.to_string_lossy().into_owned())
                        .collect();
                    if !argv.is_empty() {
                        cfg.command = Some(argv);
                    }
                    break;
                }
                other => anyhow::bail!("未知参数 `{other}`（--help 查看用法）"),
            }
            i += 1;
        }

        if cfg.command.is_none() {
            if let Ok(app) = std::env::var("ARCHOERA_SESSION_APP") {
                if !app.trim().is_empty() {
                    cfg.command = Some(split_whitespace(&app));
                }
            }
        }

        if cfg.drm_device.is_none() {
            if let Ok(dev) = std::env::var("ARCHOERA_DRM_DEVICE") {
                if !dev.trim().is_empty() {
                    cfg.drm_device = Some(dev);
                }
            }
        }

        // 会话脚本可用环境变量关闭输入法看门狗（默认开启）。
        if let Ok(v) = std::env::var("ARCHOERA_IME_WATCH") {
            if matches!(v.trim(), "0" | "false" | "no" | "off") {
                cfg.ime_watch = false;
            }
        }

        Ok(cfg)
    }
}

fn take(rest: &[OsString], index: usize, flag: &str) -> anyhow::Result<String> {
    rest.get(index)
        .map(|s| s.to_string_lossy().into_owned())
        .ok_or_else(|| anyhow::anyhow!("参数 {flag} 缺少取值"))
}

/// 解析 `WxH`（如 `1920x1080`）为分辨率。
fn parse_mode(raw: &str) -> anyhow::Result<(i32, i32)> {
    let (w, h) = raw
        .split_once('x')
        .or_else(|| raw.split_once('X'))
        .ok_or_else(|| anyhow::anyhow!("`{raw}` 不是合法的分辨率（形如 1920x1080）"))?;
    let w: i32 = w
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("`{raw}` 宽度非法"))?;
    let h: i32 = h
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("`{raw}` 高度非法"))?;
    if w <= 0 || h <= 0 {
        anyhow::bail!("分辨率必须为正（{raw}）");
    }
    Ok((w, h))
}

/// 极简 shell 分词：支持单/双引号与反斜杠转义，足够表达会话命令。
fn split_whitespace(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut escaped = false;

    for ch in line.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        match (quote, ch) {
            (_, '\\') => escaped = true,
            (Some(q), c) if c == q => quote = None,
            (None, '"') | (None, '\'') => quote = Some(ch),
            (None, c) if c.is_whitespace() => {
                if !current.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
            }
            (_, c) => current.push(c),
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

fn print_help() {
    println!(
        "archoera-shell —— ArchoeraOS kiosk Wayland 合成器\n\
         \n\
         用法: archoera-shell [选项] [-- <会话命令> [参数...]]\n\
         \n\
         选项:\n\
           --socket <name>        固定 WAYLAND_DISPLAY 名（默认自动分配）\n\
           -c, --command <line>   托管的会话命令（按空白拆分）\n\
           --backend <winit|udev> 运行后端（默认 winit，嵌套开发）\n\
           --volume <0-100>       初始会话音量\n\
           --no-exit-on-close     客户端全部退出后不结束会话\n\
           --no-ime-watch         不在输入法断开后结束会话（默认会结束以成对重建）\n\
           --allow-multiple       允许第二个 toplevel（默认 kiosk 只接受一个）\n\
           --drm-device <path>    udev 后端指定 DRM 节点（默认固件主 GPU / 首个）\n\
           --mode <WxH>           期望输出分辨率（udev 挑连接器模式；默认 preferred）\n\
           --scale <f>            输出缩放 0.25-4.0（默认 1.0）\n\
           --transform <t>        normal/90/180/270/flipped/flipped90/flipped180/flipped270\n\
           -h, --help             显示本帮助"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn defaults_are_winit_no_command() {
        let cfg = ShellConfig::from_args(args(&["archoera-shell"])).unwrap();
        assert_eq!(cfg.socket_name, None);
        assert_eq!(cfg.command, None);
        assert_eq!(cfg.backend, BackendKind::Winit);
        assert_eq!(cfg.volume, 100);
        assert!(cfg.exit_on_close);
        assert!(!cfg.allow_multiple);
        assert_eq!(cfg.drm_device, None);
        assert_eq!(cfg.mode, None);
        assert!((cfg.scale - 1.0).abs() < f64::EPSILON);
        assert_eq!(cfg.transform, TransformKind::Normal);
    }

    #[test]
    fn parses_display_options() {
        let cfg = ShellConfig::from_args(args(&[
            "archoera-shell",
            "--mode",
            "1920x1080",
            "--scale",
            "1.5",
            "--transform",
            "90",
        ]))
        .unwrap();
        assert_eq!(cfg.mode, Some((1920, 1080)));
        assert!((cfg.scale - 1.5).abs() < f64::EPSILON);
        assert_eq!(cfg.transform, TransformKind::R90);
    }

    #[test]
    fn rejects_bad_display_options() {
        assert!(ShellConfig::from_args(args(&["archoera-shell", "--mode", "1920"])).is_err());
        assert!(ShellConfig::from_args(args(&["archoera-shell", "--scale", "9"])).is_err());
        assert!(ShellConfig::from_args(args(&["archoera-shell", "--transform", "tilt"])).is_err());
    }

    #[test]
    fn parses_kiosk_and_drm_device_flags() {
        let cfg = ShellConfig::from_args(args(&[
            "archoera-shell",
            "--allow-multiple",
            "--drm-device",
            "/dev/dri/card1",
        ]))
        .unwrap();
        assert!(cfg.allow_multiple);
        assert_eq!(cfg.drm_device.as_deref(), Some("/dev/dri/card1"));
    }

    #[test]
    fn ime_watch_defaults_on_and_can_be_disabled() {
        let cfg = ShellConfig::from_args(args(&["archoera-shell"])).unwrap();
        assert!(cfg.ime_watch);
        let cfg = ShellConfig::from_args(args(&["archoera-shell", "--no-ime-watch"])).unwrap();
        assert!(!cfg.ime_watch);
    }

    #[test]
    fn parses_flags_and_backend() {
        let cfg = ShellConfig::from_args(args(&[
            "archoera-shell",
            "--socket",
            "archoera-test",
            "--backend",
            "udev",
            "--volume",
            "42",
            "--no-exit-on-close",
        ]))
        .unwrap();
        assert_eq!(cfg.socket_name.as_deref(), Some("archoera-test"));
        assert_eq!(cfg.backend, BackendKind::Udev);
        assert_eq!(cfg.volume, 42);
        assert!(!cfg.exit_on_close);
    }

    #[test]
    fn volume_is_clamped_to_100() {
        let cfg = ShellConfig::from_args(args(&["archoera-shell", "--volume", "999"])).unwrap();
        assert_eq!(cfg.volume, 100);
    }

    #[test]
    fn command_flag_splits_and_honors_quotes() {
        let cfg = ShellConfig::from_args(args(&[
            "archoera-shell",
            "--command",
            "archoera_music --title \"hello world\"",
        ]))
        .unwrap();
        assert_eq!(
            cfg.command,
            Some(vec![
                "archoera_music".to_string(),
                "--title".to_string(),
                "hello world".to_string()
            ])
        );
    }

    #[test]
    fn double_dash_takes_remaining_argv_verbatim() {
        let cfg = ShellConfig::from_args(args(&[
            "archoera-shell",
            "--socket",
            "s",
            "--",
            "/usr/bin/archoera_music",
            "--flag with spaces",
        ]))
        .unwrap();
        assert_eq!(cfg.socket_name.as_deref(), Some("s"));
        assert_eq!(
            cfg.command,
            Some(vec![
                "/usr/bin/archoera_music".to_string(),
                "--flag with spaces".to_string()
            ])
        );
    }

    #[test]
    fn rejects_unknown_flag_and_backend() {
        assert!(ShellConfig::from_args(args(&["archoera-shell", "--nope"])).is_err());
        assert!(ShellConfig::from_args(args(&["archoera-shell", "--backend", "x11"])).is_err());
    }

    #[test]
    fn missing_value_is_an_error() {
        assert!(ShellConfig::from_args(args(&["archoera-shell", "--socket"])).is_err());
    }

    #[test]
    fn shell_tokenizer_handles_quotes_and_escapes() {
        assert_eq!(
            split_whitespace("a  b\tc"),
            vec!["a".to_string(), "b".to_string(), "c".to_string()]
        );
        assert_eq!(
            split_whitespace("cmd 'single quoted' \"double quoted\""),
            vec![
                "cmd".to_string(),
                "single quoted".to_string(),
                "double quoted".to_string()
            ]
        );
        assert_eq!(
            split_whitespace(r"cmd a\ b"),
            vec!["cmd".to_string(), "a b".to_string()]
        );
    }
}

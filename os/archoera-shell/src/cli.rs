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
}

impl Default for ShellConfig {
    fn default() -> Self {
        Self {
            socket_name: None,
            command: None,
            exit_on_close: true,
            volume: 100,
            backend: BackendKind::Winit,
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
    /// - `--volume <n>`；
    /// - `ARCHOERA_SESSION_APP`：未显式给命令时的环境兜底。
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

        Ok(cfg)
    }
}

fn take(rest: &[OsString], index: usize, flag: &str) -> anyhow::Result<String> {
    rest.get(index)
        .map(|s| s.to_string_lossy().into_owned())
        .ok_or_else(|| anyhow::anyhow!("参数 {flag} 缺少取值"))
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

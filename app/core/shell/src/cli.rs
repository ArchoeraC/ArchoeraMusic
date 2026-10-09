// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `archoerashell` 原生 CLI：参数解析、命令分派、REST 调用与 REPL。
//!
//! 经本机 MCP 服务的 REST 接口通信（同一退出码约定），不加载 Flutter/Dart。

use crate::http::{request, RequestError, Target};
use crate::l10n::L10n;
use crate::prefs::{self, Prefs};
use crate::render::Renderer;
use crate::style::Style;
use crate::term;
use serde_json::{json, Value};
use std::io::{BufRead, Write};

const VERSION: &str = "archoerashell 1.0 · MCP 2025-11-25";

struct Ctx {
    target: Target,
    l10n: L10n,
    json: bool,
    quiet: bool,
    columns: usize,
    styled: bool,
}

impl Ctx {
    fn renderer(&self) -> Renderer {
        Renderer::new(self.columns, self.styled && !self.json, self.l10n.clone())
    }

    fn request(
        &self,
        method: &str,
        path: &str,
        query: &[(String, String)],
        body: Option<&Value>,
    ) -> Result<crate::http::Response, RequestError> {
        request(&self.target, method, path, query, body)
    }

    fn finish(&self, result: Result<crate::http::Response, RequestError>) -> i32 {
        match result {
            Err(RequestError::Timeout) => {
                eprintln!(
                    "{}",
                    self.l10n.fmt(
                        "mcpShellErrTimeout",
                        &[
                            ("host", self.target.host.clone()),
                            ("port", self.target.port.to_string()),
                        ]
                    )
                );
                1
            }
            Err(RequestError::Connect(reason)) | Err(RequestError::Io(reason)) => {
                eprintln!(
                    "{}",
                    self.l10n.fmt(
                        "mcpShellErrConnect",
                        &[
                            ("host", self.target.host.clone()),
                            ("port", self.target.port.to_string()),
                            ("reason", reason),
                        ]
                    )
                );
                eprintln!("{}", self.l10n.raw("mcpShellErrConnectHint"));
                1
            }
            Ok(resp) => {
                if !(200..300).contains(&resp.status) {
                    let text = error_text(&resp.body);
                    match text {
                        Some(t) => eprintln!("{}: {t}", self.l10n.raw("mcpShellErrorPrefix")),
                        None => eprintln!("HTTP {}", resp.status),
                    }
                    return 1;
                }
                if !self.quiet {
                    if self.json {
                        println!("{}", serde_json::to_string(&resp.body).unwrap_or_default());
                    } else {
                        let mut r = self.renderer();
                        r.render(&resp.body);
                        print!("{}", r.out);
                    }
                }
                0
            }
        }
    }

    fn get(&self, path: &str, query: &[(String, String)]) -> i32 {
        let r = self.request("GET", path, query, None);
        self.finish(r)
    }

    fn send(&self, method: &str, path: &str, body: Option<&Value>) -> i32 {
        let r = self.request(method, path, &[], body);
        self.finish(r)
    }

    fn tool(&self, name: &str, body: Value) -> i32 {
        self.send("POST", &format!("/api/tools/{name}"), Some(&body))
    }
}

fn error_text(body: &Value) -> Option<String> {
    let err = body.get("error")?;
    let code = err.get("code").map(value_str).unwrap_or_else(|| "error".into());
    let message = err.get("message").map(value_str).unwrap_or_default();
    if message.is_empty() {
        Some(code)
    } else {
        Some(format!("{code}: {message}"))
    }
}

fn value_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

// ── 词法 ──────────────────────────────────────────────────────────

/// 解析一行 REPL 输入为参数（支持单/双引号与反斜杠转义）。
fn shell_split(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quoted: Option<char> = None;
    let mut has = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match quoted {
            Some(q) => {
                if c == q {
                    quoted = None;
                } else if c == '\\' && q == '"' {
                    if let Some(&n) = chars.peek() {
                        cur.push(n);
                        chars.next();
                    }
                } else {
                    cur.push(c);
                }
            }
            None => match c {
                '\'' | '"' => {
                    quoted = Some(c);
                    has = true;
                }
                '\\' => {
                    if let Some(&n) = chars.peek() {
                        cur.push(n);
                        chars.next();
                        has = true;
                    }
                }
                c if c.is_whitespace() => {
                    if has || !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                        has = false;
                    }
                }
                c => {
                    cur.push(c);
                    has = true;
                }
            },
        }
    }
    if has || !cur.is_empty() {
        out.push(cur);
    }
    out
}

// ── 命令帮助 ─────────────────────────────────────────────────────

fn help_key(command: &str) -> Option<&'static str> {
    Some(match command {
        "status" => "mcpShellHelpStatus",
        "now-playing" => "mcpShellHelpNowPlaying",
        "play" => "mcpShellHelpPlay",
        "pause" => "mcpShellHelpPause",
        "toggle" => "mcpShellHelpToggle",
        "stop" => "mcpShellHelpStop",
        "next" => "mcpShellHelpNext",
        "prev" => "mcpShellHelpPrev",
        "previous" => "mcpShellHelpPrevious",
        "seek" => "mcpShellHelpSeek",
        "volume" => "mcpShellHelpVolume",
        "repeat" => "mcpShellHelpRepeat",
        "shuffle" => "mcpShellHelpShuffle",
        "quality" => "mcpShellHelpQuality",
        "play-track" => "mcpShellHelpPlayTrack",
        "search" => "mcpShellHelpSearch",
        "search-all" => "mcpShellHelpSearchAll",
        "queue" => "mcpShellHelpQueue",
        "library" => "mcpShellHelpLibrary",
        "library-random" => "mcpShellHelpLibraryRandom",
        "library-stats" => "mcpShellHelpLibraryStats",
        "prefs" => "mcpShellHelpPrefs",
        "theme" => "mcpShellHelpTheme",
        "like" => "mcpShellHelpLike",
        "unlike" => "mcpShellHelpUnlike",
        "like-status" => "mcpShellHelpLikeStatus",
        "list-liked" => "mcpShellHelpListLiked",
        "history" => "mcpShellHelpHistory",
        "history-clear" => "mcpShellHelpHistoryClear",
        "lyrics" => "mcpShellHelpLyrics",
        "download" => "mcpShellHelpDownload",
        "sleep" => "mcpShellHelpSleep",
        "sleep-cancel" => "mcpShellHelpSleepCancel",
        "info" => "mcpShellHelpInfo",
        "tools" => "mcpShellHelpTools",
        "call" => "mcpShellHelpCall",
        _ => return None,
    })
}

fn command_help(ctx: &Ctx, command: &str) -> Option<String> {
    help_key(command).map(|k| ctx.l10n.raw(k))
}

// ── 入口 ─────────────────────────────────────────────────────────

/// 全局可持久状态（REPL 中跨行保留用户覆盖）。
struct Globals {
    host: String,
    port: u16,
    key: String,
    json: bool,
    quiet: bool,
}

pub fn run(args: Vec<String>) -> i32 {
    let prefs: Prefs = prefs::load_prefs();
    let l10n = L10n::new(prefs.locale.clone());
    if !prefs.shell_enabled {
        eprintln!("{}", l10n.raw("mcpShellDisabled"));
        return 2;
    }

    let mut globals = Globals {
        host: "127.0.0.1".to_string(),
        port: prefs.port,
        key: prefs.key.clone(),
        json: false,
        quiet: false,
    };

    if args.is_empty() {
        return if term::stdin_is_tty() {
            repl(&mut globals, &l10n)
        } else {
            batch(&mut globals, &l10n)
        };
    }
    execute(&mut globals, &l10n, &args)
}

fn make_ctx(globals: &Globals, l10n: &L10n) -> Ctx {
    Ctx {
        target: Target {
            host: globals.host.clone(),
            port: globals.port,
            key: globals.key.clone(),
        },
        l10n: l10n.clone(),
        json: globals.json,
        quiet: globals.quiet,
        columns: term::columns(),
        styled: term::use_style(),
    }
}

/// 解析 + 执行一条命令。返回退出码。
fn execute(globals: &mut Globals, l10n: &L10n, argv: &[String]) -> i32 {
    let tokens: Vec<String> = argv.to_vec();
    let mut i = 0;
    while i < tokens.len() {
        let t = tokens[i].clone();
        if t == "--" {
            i += 1;
            break;
        }
        if t == "-h" || t == "--help" {
            let ctx = make_ctx(globals, l10n);
            println!("{}", ctx.l10n.raw("mcpShellUsage"));
            return 0;
        }
        if t == "-V" || t == "--version" {
            println!("{VERSION}");
            return 0;
        }
        if t == "-j" || t == "--json" {
            globals.json = true;
            i += 1;
            continue;
        }
        if t == "-q" || t == "--quiet" {
            globals.quiet = true;
            i += 1;
            continue;
        }
        if t == "--host" || t.starts_with("--host=") {
            match option_value(&tokens, i, "--host") {
                Some((v, used)) => {
                    globals.host = v;
                    i += used;
                    continue;
                }
                None => return option_error(l10n, "mcpShellErrNeedValue", &[("option", "--host")]),
            }
        }
        if t == "-p" || t == "--port" || t.starts_with("--port=") {
            let name = if t == "-p" { "--port" } else { t.as_str() };
            match option_value(&tokens, i, name) {
                Some((v, used)) => {
                    match v.parse::<i64>() {
                        Ok(n) if (1..=65535).contains(&n) => globals.port = n as u16,
                        _ => {
                            return option_error(
                                l10n,
                                "mcpShellErrBadPort",
                                &[("value", v.as_str())],
                            )
                        }
                    }
                    i += used;
                    continue;
                }
                None => return option_error(l10n, "mcpShellErrNeedValue", &[("option", "--port")]),
            }
        }
        if t == "-k" || t == "--key" || t.starts_with("--key=") {
            let name = if t == "-k" { "--key" } else { t.as_str() };
            match option_value(&tokens, i, name) {
                Some((v, used)) => {
                    globals.key = v;
                    i += used;
                    continue;
                }
                None => return option_error(l10n, "mcpShellErrNeedValue", &[("option", "--key")]),
            }
        }
        if t.starts_with('-') && t.len() > 1 {
            return option_error(l10n, "mcpShellErrUnknownOption", &[("option", t.as_str())]);
        }
        break;
    }

    let command = tokens.get(i).cloned().unwrap_or_default();
    let rest: Vec<String> = if i < tokens.len() {
        tokens[i + 1..].to_vec()
    } else {
        Vec::new()
    };
    if command.is_empty() {
        let ctx = make_ctx(globals, l10n);
        eprintln!("{}", ctx.l10n.raw("mcpShellUsage"));
        return 2;
    }
    let ctx = make_ctx(globals, l10n);
    if command == "help" {
        if let Some(first) = rest.first() {
            if let Some(help) = command_help(&ctx, first) {
                println!("{help}");
                return 0;
            }
        }
        println!("{}", ctx.l10n.raw("mcpShellUsage"));
        return 0;
    }
    if rest.iter().any(|a| a == "-h" || a == "--help") {
        if let Some(help) = command_help(&ctx, &command) {
            println!("{help}");
            return 0;
        }
    }

    dispatch(&ctx, &command, &rest)
}

fn option_error(l10n: &L10n, key: &str, args: &[(&str, &str)]) -> i32 {
    let owned: Vec<(&str, String)> = args.iter().map(|(k, v)| (*k, v.to_string())).collect();
    eprintln!("{}", l10n.fmt(key, &owned));
    2
}

/// 选项取值：支持 `--opt value` 与 `--opt=value`，返回 (值, 消耗 token 数)。
fn option_value(tokens: &[String], index: usize, _name: &str) -> Option<(String, usize)> {
    let token = &tokens[index];
    if let Some(eq) = token.find('=') {
        return Some((token[eq + 1..].to_string(), 1));
    }
    tokens.get(index + 1).map(|v| (v.clone(), 2))
}

// ── 分派 ─────────────────────────────────────────────────────────

fn dispatch(ctx: &Ctx, command: &str, args: &[String]) -> i32 {
    match command {
        "info" => ctx.get("/api/info", &[]),
        "status" => ctx.get("/api/status", &[]),
        "now-playing" => ctx.get("/api/now-playing", &[]),
        "tools" => ctx.get("/api/tools", &[]),
        "play" | "pause" | "toggle" | "stop" => {
            ctx.send("POST", &format!("/api/player/{command}"), None)
        }
        "next" => ctx.send("POST", "/api/player/next", None),
        "prev" | "previous" => ctx.send("POST", "/api/player/previous", None),
        "seek" => cmd_seek(ctx, args),
        "volume" => cmd_volume(ctx, args),
        "repeat" => cmd_repeat(ctx, args),
        "shuffle" => cmd_shuffle(ctx, args),
        "quality" => cmd_quality(ctx, args),
        "play-track" => cmd_play_track(ctx, args),
        "search" => cmd_search(ctx, args),
        "search-all" => cmd_search_all(ctx, args),
        "queue" => cmd_queue(ctx, args),
        "library" => cmd_library(ctx, args),
        "library-random" => ctx.tool("library_random", json!({ "limit": limit_args(args, 20) })),
        "library-stats" => ctx.send("POST", "/api/tools/library_stats", None),
        "prefs" => cmd_prefs(ctx, args),
        "theme" => cmd_theme(ctx, args),
        "like" | "unlike" | "like-status" => cmd_like(ctx, command, args),
        "list-liked" => cmd_list_liked(ctx, args),
        "history" => ctx.tool("history_list", json!({ "limit": limit_args(args, 50) })),
        "history-clear" => ctx.send("POST", "/api/tools/history_clear", None),
        "lyrics" => ctx.send("POST", "/api/tools/get_lyrics", None),
        "download" => cmd_download(ctx, args),
        "sleep" => cmd_sleep(ctx, args),
        "sleep-cancel" => ctx.send("POST", "/api/tools/cancel_sleep_timer", None),
        "call" => cmd_call(ctx, args),
        // 彩蛋：`awa` 显示字符表情（见 cmd_awa）。
        "awa" => cmd_awa(ctx),
        _ => {
            eprintln!(
                "{}",
                ctx.l10n
                    .fmt("mcpShellErrUnknownCommand", &[("command", command.to_string())])
            );
            eprintln!("{}", ctx.l10n.raw("mcpShellHint"));
            2
        }
    }
}

fn usage_error(ctx: &Ctx, command: &str) -> i32 {
    eprintln!("{}", ctx.l10n.raw("mcpShellUsageError"));
    if let Some(help) = command_help(ctx, command) {
        eprintln!("{help}");
    }
    eprintln!("{}", ctx.l10n.raw("mcpShellHint"));
    2
}

fn cmd_seek(ctx: &Ctx, args: &[String]) -> i32 {
    match first_int(args) {
        Some(ms) => ctx.send("POST", "/api/player/seek", Some(&json!({ "positionMs": ms }))),
        None => usage_error(ctx, "seek"),
    }
}

fn cmd_volume(ctx: &Ctx, args: &[String]) -> i32 {
    match args.first().and_then(|v| v.parse::<f64>().ok()) {
        Some(v) if (0.0..=1.0).contains(&v) => {
            ctx.send("PUT", "/api/player/volume", Some(&json!({ "volume": v })))
        }
        _ => usage_error(ctx, "volume"),
    }
}

fn cmd_repeat(ctx: &Ctx, args: &[String]) -> i32 {
    const ALLOWED: [&str; 3] = ["off", "list", "one"];
    match args.first().map(String::as_str) {
        Some(v) if ALLOWED.contains(&v) => {
            ctx.send("PUT", "/api/player/repeat", Some(&json!({ "mode": v })))
        }
        _ => usage_error(ctx, "repeat"),
    }
}

fn cmd_shuffle(ctx: &Ctx, args: &[String]) -> i32 {
    match args.first().and_then(|v| parse_on_off(v)) {
        Some(enabled) => ctx.send(
            "PUT",
            "/api/player/shuffle",
            Some(&json!({ "enabled": enabled })),
        ),
        None => usage_error(ctx, "shuffle"),
    }
}

fn cmd_quality(ctx: &Ctx, args: &[String]) -> i32 {
    const ALLOWED: [&str; 5] = ["lq", "sq", "hq", "lossless", "hi-res"];
    match args.first().map(String::as_str) {
        Some(v) if ALLOWED.contains(&v) => {
            ctx.send("PUT", "/api/player/quality", Some(&json!({ "quality": v })))
        }
        _ => usage_error(ctx, "quality"),
    }
}

fn cmd_play_track(ctx: &Ctx, args: &[String]) -> i32 {
    match args.first() {
        Some(r) => ctx.send("POST", "/api/player/track", Some(&json!({ "ref": r }))),
        None => usage_error(ctx, "play-track"),
    }
}

fn cmd_search(ctx: &Ctx, args: &[String]) -> i32 {
    let Some(source) = args.first() else {
        return usage_error(ctx, "search");
    };
    let rest = &args[1..];
    let limit = flag_int(rest, &["-n", "--limit"], 20);
    let page = flag_int(rest, &["-p", "--page"], 1);
    let query = join_query(rest);
    if query.is_empty() {
        return usage_error(ctx, "search");
    }
    ctx.get(
        "/api/search",
        &[
            ("source".into(), source.clone()),
            ("q".into(), query),
            ("limit".into(), limit.to_string()),
            ("page".into(), page.to_string()),
        ],
    )
}

fn cmd_search_all(ctx: &Ctx, args: &[String]) -> i32 {
    let limit = flag_int(args, &["-n", "--limit"], 10);
    let query = join_query(args);
    if query.is_empty() {
        return usage_error(ctx, "search-all");
    }
    ctx.tool(
        "search_all",
        json!({ "query": query, "limitPerSource": limit }),
    )
}

fn cmd_queue(ctx: &Ctx, args: &[String]) -> i32 {
    let sub = args.first().map(String::as_str).unwrap_or("list");
    let rest = if args.len() > 1 { &args[1..] } else { &[][..] };
    match sub {
        "list" => ctx.get("/api/queue", &[]),
        "play" => match first_int(rest) {
            Some(i) => ctx.send("POST", "/api/queue/play", Some(&json!({ "index": i }))),
            None => usage_error(ctx, "queue"),
        },
        "add" => {
            let refs = strip_flags(rest);
            if refs.is_empty() {
                return usage_error(ctx, "queue");
            }
            let position = flag_value(args, &["--position"]).unwrap_or_else(|| "next".to_string());
            ctx.send(
                "POST",
                "/api/queue/add",
                Some(&json!({ "tracks": refs, "position": position })),
            )
        }
        "rm" | "remove" => match first_int(rest) {
            Some(i) => ctx.send("DELETE", &format!("/api/queue/tracks/{i}"), None),
            None => usage_error(ctx, "queue"),
        },
        "move" => {
            if rest.len() < 2 {
                return usage_error(ctx, "queue");
            }
            match (rest[0].parse::<i64>(), rest[1].parse::<i64>()) {
                (Ok(from), Ok(to)) => ctx.send(
                    "PUT",
                    "/api/queue/tracks/move",
                    Some(&json!({ "from": from, "to": to })),
                ),
                _ => usage_error(ctx, "queue"),
            }
        }
        "clear" => ctx.send("DELETE", "/api/queue", None),
        _ => usage_error(ctx, "queue"),
    }
}

fn cmd_library(ctx: &Ctx, args: &[String]) -> i32 {
    let limit = flag_int(args, &["-n", "--limit"], 50);
    let offset = flag_int(args, &["--offset"], 0);
    let query = join_query(args);
    let mut q: Vec<(String, String)> = Vec::new();
    if !query.is_empty() {
        q.push(("q".into(), query));
    }
    q.push(("limit".into(), limit.to_string()));
    q.push(("offset".into(), offset.to_string()));
    ctx.get("/api/library/search", &q)
}

fn cmd_prefs(ctx: &Ctx, args: &[String]) -> i32 {
    let keys = strip_flags(args);
    let mut q: Vec<(String, String)> = Vec::new();
    if !keys.is_empty() {
        q.push(("keys".into(), keys.join(",")));
    }
    ctx.get("/api/preferences", &q)
}

fn cmd_theme(ctx: &Ctx, args: &[String]) -> i32 {
    const ALLOWED: [&str; 3] = ["light", "dark", "system"];
    match args.first().map(String::as_str) {
        Some(v) if ALLOWED.contains(&v) => ctx.tool("set_theme_mode", json!({ "mode": v })),
        _ => usage_error(ctx, "theme"),
    }
}

fn cmd_like(ctx: &Ctx, command: &str, args: &[String]) -> i32 {
    let Some(r) = args.first() else {
        return usage_error(ctx, command);
    };
    let tool = match command {
        "like" => "like_track",
        "unlike" => "unlike_track",
        _ => "get_like_status",
    };
    ctx.tool(tool, json!({ "ref": r }))
}

fn cmd_list_liked(ctx: &Ctx, args: &[String]) -> i32 {
    let Some(source) = args.first() else {
        return usage_error(ctx, "list-liked");
    };
    let limit = flag_int(args, &["-n", "--limit"], 100);
    ctx.tool("list_liked", json!({ "source": source, "limit": limit }))
}

fn cmd_download(ctx: &Ctx, args: &[String]) -> i32 {
    let sub = args.first().map(String::as_str).unwrap_or("list");
    let rest = if args.len() > 1 { &args[1..] } else { &[][..] };
    match sub {
        "list" => ctx.tool("download_list", json!({ "limit": limit_args(rest, 50) })),
        "add" => {
            let refs = strip_flags(rest);
            if refs.is_empty() {
                return usage_error(ctx, "download");
            }
            let quality = flag_value(rest, &["--quality"]);
            let mut code = 0;
            for r in refs {
                let body = match &quality {
                    Some(q) => json!({ "ref": r, "quality": q }),
                    None => json!({ "ref": r }),
                };
                let c = ctx.tool("download_add", body);
                if c != 0 {
                    code = c;
                }
            }
            code
        }
        "cancel" => match rest.first() {
            Some(id) => ctx.tool("download_cancel", json!({ "taskId": id })),
            None => usage_error(ctx, "download"),
        },
        "remove" => match rest.first() {
            Some(id) => ctx.tool("download_remove", json!({ "taskId": id })),
            None => usage_error(ctx, "download"),
        },
        _ => usage_error(ctx, "download"),
    }
}

fn cmd_sleep(ctx: &Ctx, args: &[String]) -> i32 {
    let Some(first) = args.first() else {
        return usage_error(ctx, "sleep");
    };
    if first == "--end" || first == "end" {
        return ctx.tool("set_sleep_timer", json!({ "endOfTrack": true }));
    }
    match first.parse::<i64>() {
        Ok(m) if m > 0 => ctx.tool("set_sleep_timer", json!({ "minutes": m })),
        _ => usage_error(ctx, "sleep"),
    }
}

fn cmd_call(ctx: &Ctx, args: &[String]) -> i32 {
    let Some(name) = args.first() else {
        return usage_error(ctx, "call");
    };
    let rest = &args[1..];
    let raw = flag_value(rest, &["--json", "--body", "-d"]);
    let body = match raw {
        None => json!({}),
        Some(text) => match serde_json::from_str::<Value>(&text) {
            Ok(v) if v.is_object() => v,
            _ => return usage_error(ctx, "call"),
        },
    };
    ctx.tool(name, body)
}

// ── 彩蛋：awa ───────────────────────────────────────────────────

/// `awa` 字符表情素材（**编译进二进制**，随三端分发，无需外部文件）。
///
/// 素材用**字面量** `\033[38;5;Nm` 记录颜色（便于版本管理与 `printf '%b'`）。
const AWA_ART: &str = include_str!("../assets/emoji-2-256.ansi");

/// 彩蛋：`awa` —— 打印字符表情。
///
/// 支持 ANSI 的交互终端下解释字面量转义、保留颜色；否则（`NO_COLOR` /
/// `TERM=dumb` / 非 TTY）剥掉颜色只留字符——该画本身以字符密度成像，去掉颜色
/// 即得黑白版。
fn cmd_awa(ctx: &Ctx) -> i32 {
    let rendered = if ctx.styled {
        AWA_ART.replace("\\033", "\x1b")
    } else {
        strip_sgr(AWA_ART)
    };
    print!("{rendered}");
    if !rendered.ends_with('\n') {
        println!();
    }
    0
}

/// 把字面量 `\033[`…`m`（SGR 序列）从字符串中剥除，保留其余字符与换行。
fn strip_sgr(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            let lookahead: String = chars.clone().take(4).collect();
            if lookahead.starts_with("033[") {
                for _ in 0..4 {
                    chars.next();
                }
                for d in chars.by_ref() {
                    if d == 'm' {
                        break;
                    }
                }
                continue;
            }
        }
        out.push(c);
    }
    out
}

// ── 参数解析辅助 ─────────────────────────────────────────────────

fn first_int(args: &[String]) -> Option<i64> {
    for a in args {
        if a.starts_with('-') {
            continue;
        }
        if let Ok(v) = a.parse::<i64>() {
            return Some(v);
        }
    }
    None
}

fn flag_int(args: &[String], names: &[&str], fallback: i64) -> i64 {
    for (i, a) in args.iter().enumerate() {
        for name in names {
            if a == name {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<i64>().ok()) {
                    return v;
                }
            }
            if let Some(rest) = a.strip_prefix(&format!("{name}=")) {
                if let Ok(v) = rest.parse::<i64>() {
                    return v;
                }
            }
        }
    }
    fallback
}

fn flag_value(args: &[String], names: &[&str]) -> Option<String> {
    for (i, a) in args.iter().enumerate() {
        for name in names {
            if a == name {
                if let Some(v) = args.get(i + 1) {
                    return Some(v.clone());
                }
            }
            if let Some(rest) = a.strip_prefix(&format!("{name}=")) {
                return Some(rest.to_string());
            }
        }
    }
    None
}

fn limit_args(args: &[String], fallback: i64) -> i64 {
    flag_int(args, &["-n", "--limit"], fallback)
}

fn strip_flags(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a.starts_with("--") && a.contains('=') {
            i += 1;
            continue;
        }
        if a.starts_with('-') {
            if i + 1 < args.len() && !args[i + 1].starts_with('-') {
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        out.push(a.clone());
        i += 1;
    }
    out
}

fn join_query(args: &[String]) -> String {
    strip_flags(args).join(" ")
}

fn parse_on_off(v: &str) -> Option<bool> {
    match v.to_ascii_lowercase().as_str() {
        "on" | "true" | "1" | "yes" => Some(true),
        "off" | "false" | "0" | "no" => Some(false),
        _ => None,
    }
}

// ── REPL / 批处理 ────────────────────────────────────────────────

fn repl(globals: &mut Globals, l10n: &L10n) -> i32 {
    let style = Style::new(term::use_style());
    println!("{}", style.dim(VERSION));
    println!("{}", style.dim(&l10n.raw("mcpShellHint")));

    // 交互式终端：进入原始模式，用自带行编辑器启用 ←/→ 与 ↑/↓ 历史。
    if let Some(mut raw) = term::RawInput::enable() {
        let prompt = format!("{} ", style.cyan("archoerashell›"));
        let mut editor = crate::lineedit::Editor::new(prompt, term::columns());
        loop {
            match editor.read_line(&mut raw) {
                crate::lineedit::Outcome::Line(line) => {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    if trimmed == "exit" || trimmed == "quit" || trimmed == ":q" {
                        break;
                    }
                    editor.remember(&line);
                    let argv = shell_split(&line);
                    if argv.is_empty() {
                        continue;
                    }
                    let _ = execute(globals, l10n, &argv);
                }
                crate::lineedit::Outcome::Cancel => continue,
                crate::lineedit::Outcome::Eof => break,
            }
        }
        return 0;
    }

    // 回退：原始模式不可用（罕见）时退回逐行读取。
    let stdin = std::io::stdin();
    let mut lines = stdin.lock().lines();
    loop {
        print!("{} ", style.cyan("archoerashell›"));
        let _ = std::io::stdout().flush();
        let Some(Ok(line)) = lines.next() else {
            println!();
            break;
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed == "exit" || trimmed == "quit" || trimmed == ":q" {
            break;
        }
        let argv = shell_split(&line);
        if argv.is_empty() {
            continue;
        }
        let _ = execute(globals, l10n, &argv);
    }
    0
}

fn batch(globals: &mut Globals, l10n: &L10n) -> i32 {
    let stdin = std::io::stdin();
    let mut code = 0;
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let argv = shell_split(&line);
        if argv.is_empty() {
            continue;
        }
        code = execute(globals, l10n, &argv);
    }
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_handles_quotes_and_escapes() {
        assert_eq!(
            shell_split("search netease 周杰伦 晴天 -n 5"),
            vec!["search", "netease", "周杰伦", "晴天", "-n", "5"]
        );
        assert_eq!(
            shell_split("search netease \"Jay Chou\" -n 3"),
            vec!["search", "netease", "Jay Chou", "-n", "3"]
        );
        assert_eq!(shell_split("play-track 'a b'"), vec!["play-track", "a b"]);
        assert_eq!(shell_split("   "), Vec::<String>::new());
    }

    #[test]
    fn parses_on_off() {
        assert_eq!(parse_on_off("ON"), Some(true));
        assert_eq!(parse_on_off("off"), Some(false));
        assert_eq!(parse_on_off("maybe"), None);
    }

    #[test]
    fn strips_flags_with_values() {
        assert_eq!(
            strip_flags(&["x".into(), "-n".into(), "5".into(), "y".into()]),
            vec!["x", "y"]
        );
        assert_eq!(
            strip_flags(&["--offset=3".into(), "q".into()]),
            vec!["q"]
        );
    }

    #[test]
    fn flag_readers() {
        let args = vec!["-n".to_string(), "10".to_string(), "--position=end".to_string()];
        assert_eq!(flag_int(&args, &["-n", "--limit"], 20), 10);
        assert_eq!(flag_value(&args, &["--position"]).as_deref(), Some("end"));
    }

    #[test]
    fn help_key_covers_core_commands() {
        for cmd in ["status", "search", "queue", "download", "call", "info"] {
            assert!(help_key(cmd).is_some(), "缺少 {cmd} 的帮助键");
        }
        assert!(help_key("bogus").is_none());
    }

    #[test]
    fn strip_sgr_drops_literal_color_codes() {
        // 字面量 `\033[...m`（素材格式）应被整体剥除，只留字符。
        assert_eq!(strip_sgr("\\033[38;5;168m=+\\033[0m"), "=+");
        assert_eq!(strip_sgr("\\033[38;5;168m\\033[0m"), "");
        assert_eq!(strip_sgr("plain text"), "plain text");
        // 单独的反斜杠不是 SGR，保留原样（含换行）。
        assert_eq!(strip_sgr("a\\nb"), "a\\nb");
    }

    #[test]
    fn awa_art_is_embedded_with_color() {
        assert!(!AWA_ART.is_empty());
        // 素材应含字面量 SGR 颜色序列。
        assert!(AWA_ART.contains("\\033["));
        // 剥掉颜色后仍应是可打印的字符画。
        let mono = strip_sgr(AWA_ART);
        assert!(mono.contains('@'));
        assert!(!mono.contains("\\033["));
    }
}

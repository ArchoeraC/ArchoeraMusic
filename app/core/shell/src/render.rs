// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! `archoerashell` 输出渲染器（TUI 版式：面板/表格/进度条）。
//!
//! 同一套代码在 `styled` 开关下产出 TUI（面板/表格/进度条）或纯文本；
//! 所有输出行都经 [`Renderer::w`] 按终端列数兜底截断，保证不撑破排版。

use crate::l10n::L10n;
use crate::style::Style;
use crate::width::{display_width, pad_right, truncate};
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Renderer {
    pub out: String,
    pub columns: usize,
    pub style: Style,
    pub l10n: L10n,
}

impl Renderer {
    pub fn new(columns: usize, styled: bool, l10n: L10n) -> Self {
        Renderer {
            out: String::new(),
            columns,
            style: Style::new(styled),
            l10n,
        }
    }

    /// 取本地化标签（`mcpShellLbl*`，与 Dart 端同一份 ARB 文案）。
    fn lbl(&self, key: &str) -> String {
        self.l10n.raw(key)
    }

    fn w(&mut self, line: &str) {
        let text = if self.columns > 0 && display_width(line) > self.columns {
            truncate(line, self.columns)
        } else {
            line.to_string()
        };
        self.out.push_str(&text);
        self.out.push('\n');
    }

    fn fit_cell(text: &str, width: usize) -> String {
        if width == 0 {
            return String::new();
        }
        let t = if display_width(text) > width {
            truncate(text, width)
        } else {
            text.to_string()
        };
        pad_right(&t, width)
    }

    // ── 分派 ──────────────────────────────────────────────────────

    pub fn render(&mut self, value: &Value) {
        if self.style.enabled {
            self.render_styled(value);
        } else {
            self.render_plain(value);
        }
    }

    // ── 纯文本 ────────────────────────────────────────────────────

    fn render_plain(&mut self, value: &Value) {
        match value {
            Value::Object(map) => self.plain_map(map),
            Value::Array(items) => {
                for item in items {
                    let line = format!("  {}", plain_value(item));
                    self.w(&line);
                }
            }
            other => {
                let line = plain_value(other);
                self.w(&line);
            }
        }
    }

    fn plain_map(&mut self, map: &serde_json::Map<String, Value>) {
        if map.get("results").map(Value::is_array).unwrap_or(false) {
            self.plain_search_all(map);
            return;
        }
        if map.get("tracks").map(Value::is_array).unwrap_or(false) {
            let list = map.get("tracks").and_then(Value::as_array).unwrap();
            self.plain_tracks(list, map.get("total"), None);
            return;
        }
        if map.get("entries").map(Value::is_array).unwrap_or(false) {
            let list = map.get("entries").and_then(Value::as_array).unwrap();
            self.plain_tracks(list, map.get("total"), Some("playedAt"));
            return;
        }
        if map.get("tasks").map(Value::is_array).unwrap_or(false) {
            let list = map.get("tasks").and_then(Value::as_array).unwrap();
            self.plain_download_tasks(list, map.get("total"));
            return;
        }
        if map.get("lines").map(Value::is_array).unwrap_or(false) {
            let list = map.get("lines").and_then(Value::as_array).unwrap();
            self.plain_lyrics(list);
            return;
        }
        if let Some(values) = map.get("values").and_then(Value::as_object) {
            for (k, v) in values {
                let line = format!("{k}={}", plain_value(v));
                self.w(&line);
            }
            return;
        }
        if map.get("tools").map(Value::is_array).unwrap_or(false) {
            let list = map.get("tools").and_then(Value::as_array).unwrap();
            self.plain_tools(list);
            return;
        }
        if map.get("sources").map(Value::is_array).unwrap_or(false) {
            let list = map.get("sources").and_then(Value::as_array).unwrap();
            self.plain_sources(list);
            return;
        }
        if map.contains_key("playing") {
            self.plain_status(map);
            return;
        }
        self.plain_indented(&Value::Object(map.clone()), "");
    }

    fn plain_status(&mut self, map: &serde_json::Map<String, Value>) {
        let playing = map.get("playing").and_then(Value::as_bool).unwrap_or(false);
        self.w(&if playing {
            self.lbl("mcpShellLblTagPlaying")
        } else {
            self.lbl("mcpShellLblTagPaused")
        });
        if let Some(track) = map.get("track").and_then(Value::as_object) {
            let title = track
                .get("title")
                .map(str_value)
                .unwrap_or_default();
            let artists = artists(&Value::Object(track.clone()));
            let line = format!("{title} — {artists}");
            self.w(&line);
            if let Some(r) = track.get("ref").filter(|v| !v.is_null()) {
                let line = format!("  {}: {}", self.lbl("mcpShellLblRef"), plain_value(r));
                self.w(&line);
            }
        }
        let (lbl_volume, lbl_repeat) = (
            self.lbl("mcpShellLblVolume"),
            self.lbl("mcpShellLblRepeat"),
        );
        let pos = format_ms(map.get("positionMs"));
        let dur = format_ms(map.get("durationMs"));
        let mut parts = vec![format!("{pos} / {dur}")];
        if let Some(v) = map.get("volume") {
            parts.push(format!("{lbl_volume}: {}", plain_value(v)));
        }
        if let Some(v) = map.get("repeatMode") {
            parts.push(format!("{lbl_repeat}: {}", plain_value(v)));
        }
        if map.get("shuffle").and_then(Value::as_bool).unwrap_or(false) {
            parts.push(self.lbl("mcpShellLblShuffleOn"));
        }
        let line = parts.join(" · ");
        self.w(&line);
    }

    fn plain_tracks(
        &mut self,
        list: &[Value],
        total: Option<&Value>,
        tag: Option<&str>,
    ) {
        if let Some(t) = total {
            let line = format!("# {}: {}", self.lbl("mcpShellLblTotal"), plain_value(t));
            self.w(&line);
        }
        for (i, item) in list.iter().enumerate() {
            let Some(m) = item.as_object() else { continue };
            let title = m.get("title").map(str_value).unwrap_or_default();
            let artists = artists(item);
            let reference = m.get("ref").map(str_value).unwrap_or_default();
            let suffix = match tag {
                None => String::new(),
                Some(t) => format!("  ({})", m.get(t).map(plain_value).unwrap_or_default()),
            };
            let line = format!(
                "{}  {}{}{}{}",
                (i + 1).to_string(),
                title,
                if artists.is_empty() {
                    String::new()
                } else {
                    format!(" — {artists}")
                },
                if reference.is_empty() {
                    String::new()
                } else {
                    format!("  [{reference}]")
                },
                suffix,
            );
            // padLeft(3) 作用在序号上
            let padded = pad_index(&line, i + 1);
            self.w(&padded);
        }
    }

    fn plain_search_all(&mut self, map: &serde_json::Map<String, Value>) {
        if let Some(q) = map.get("query").filter(|v| !v.is_null()) {
            let line = format!("{}: {}", self.lbl("mcpShellLblQuery"), plain_value(q));
            self.w(&line);
        }
        let Some(results) = map.get("results").and_then(Value::as_array) else {
            return;
        };
        for item in results {
            let Some(m) = item.as_object() else { continue };
            let source = m.get("source").map(str_value).unwrap_or_else(|| "?".into());
            if let Some(err) = m.get("error").filter(|v| !v.is_null()) {
                let line = format!(
                    "── {source}: {} {}",
                    self.lbl("mcpShellLblError"),
                    plain_value(err)
                );
                self.w(&line);
                continue;
            }
            let total = m.get("total").map(plain_value).unwrap_or_default();
            let more = if m.get("hasMore").and_then(Value::as_bool).unwrap_or(false) {
                "+"
            } else {
                ""
            };
            let line = format!("── {source}（{total}{more}）");
            self.w(&line);
            if let Some(tracks) = m.get("tracks").and_then(Value::as_array) {
                self.plain_tracks(tracks, None, None);
            }
        }
    }

    fn plain_download_tasks(
        &mut self,
        list: &[Value],
        total: Option<&Value>,
    ) {
        if let Some(t) = total {
            let line = format!("# {}: {}", self.lbl("mcpShellLblTotal"), plain_value(t));
            self.w(&line);
        }
        for item in list {
            let Some(m) = item.as_object() else { continue };
            let pct = match m.get("progress").and_then(Value::as_f64) {
                Some(p) => format!("{:.1}%", p * 100.0),
                None => "-".to_string(),
            };
            let line = format!(
                "{}  {}  {} — {}  [{}]",
                m.get("status").map(plain_value).unwrap_or_default(),
                pct,
                m.get("title").map(plain_value).unwrap_or_default(),
                m.get("artist").map(plain_value).unwrap_or_default(),
                m.get("taskId").map(plain_value).unwrap_or_default(),
            );
            self.w(&line);
        }
    }

    fn plain_lyrics(&mut self, list: &[Value]) {
        for item in list {
            let Some(m) = item.as_object() else { continue };
            let time = format_ms(m.get("timeMs"));
            let text = m.get("text").map(str_value).unwrap_or_default();
            let translation = match m.get("translation").filter(|v| !v.is_null()) {
                Some(v) => format!("  //  {}", plain_value(v)),
                None => String::new(),
            };
            let line = format!("[{time}] {text}{translation}");
            self.w(&line);
        }
    }

    fn plain_tools(&mut self, list: &[Value]) {
        for item in list {
            let Some(m) = item.as_object() else { continue };
            let name = m.get("name").map(plain_value).unwrap_or_default();
            let line = format!(
                "{} {}  {}",
                pad_right(&name, 20),
                m.get("capability").map(plain_value).unwrap_or_default(),
                m.get("title").map(plain_value).unwrap_or_default(),
            );
            self.w(&line);
        }
    }

    fn plain_sources(&mut self, list: &[Value]) {
        for item in list {
            let Some(m) = item.as_object() else { continue };
            let logged = if m.get("loggedIn").and_then(Value::as_bool).unwrap_or(false) {
                self.lbl("mcpShellLblLoggedIn")
            } else {
                self.lbl("mcpShellLblLoggedOut")
            };
            let line = format!(
                "{}  {}  ({logged})",
                m.get("source").map(plain_value).unwrap_or_default(),
                m.get("label").map(plain_value).unwrap_or_default(),
            );
            self.w(&line);
        }
    }

    fn plain_indented(&mut self, value: &Value, indent: &str) {
        match value {
            Value::Object(map) => {
                for (k, v) in map {
                    if v.is_null() {
                        continue;
                    }
                    if v.is_object() || v.is_array() {
                        let line = format!("{indent}{k}:");
                        self.w(&line);
                        self.plain_indented(v, &format!("{indent}  "));
                    } else {
                        let line = format!("{indent}{k}: {}", plain_value(v));
                        self.w(&line);
                    }
                }
            }
            Value::Array(items) => {
                for item in items {
                    if item.is_object() || item.is_array() {
                        let line = format!("{indent}-");
                        self.w(&line);
                        self.plain_indented(item, &format!("{indent}  "));
                    } else {
                        let line = format!("{indent}- {}", plain_value(item));
                        self.w(&line);
                    }
                }
            }
            other => {
                let line = format!("{indent}{}", plain_value(other));
                self.w(&line);
            }
        }
    }

    // ── TUI ───────────────────────────────────────────────────────

    fn render_styled(&mut self, value: &Value) {
        match value {
            Value::Object(map) => self.styled_map(map),
            Value::Array(items) => {
                for item in items {
                    let line = format!("  {} {}", self.style.dim("•"), plain_value(item));
                    self.w(&line);
                }
            }
            other => {
                let line = plain_value(other);
                self.w(&line);
            }
        }
    }

    fn styled_map(&mut self, map: &serde_json::Map<String, Value>) {
        if map.get("results").map(Value::is_array).unwrap_or(false) {
            self.styled_search_all(map);
            return;
        }
        if map.get("entries").map(Value::is_array).unwrap_or(false) {
            let list = map.get("entries").and_then(Value::as_array).unwrap();
            self.styled_tracks(
                list,
                map.get("total"),
                Some("playedAt"),
            );
            return;
        }
        if map.get("tasks").map(Value::is_array).unwrap_or(false) {
            let list = map.get("tasks").and_then(Value::as_array).unwrap();
            self.styled_download_tasks(list, map.get("total"));
            return;
        }
        if map.get("lines").map(Value::is_array).unwrap_or(false) {
            let list = map.get("lines").and_then(Value::as_array).unwrap();
            self.styled_lyrics(list);
            return;
        }
        if let Some(values) = map.get("values").and_then(Value::as_object) {
            self.styled_values(values);
            return;
        }
        if map.get("tools").map(Value::is_array).unwrap_or(false) {
            let list = map.get("tools").and_then(Value::as_array).unwrap();
            self.styled_tools(list);
            return;
        }
        if map.get("sources").map(Value::is_array).unwrap_or(false) {
            let list = map.get("sources").and_then(Value::as_array).unwrap();
            self.styled_sources(list);
            return;
        }
        if map.get("service").map(Value::is_object).unwrap_or(false) {
            self.styled_info(map);
            return;
        }
        if map.get("tracks").map(Value::is_number).unwrap_or(false)
            && map.contains_key("totalSizeBytes")
        {
            self.styled_library_stats(map);
            return;
        }
        if map.get("tracks").map(Value::is_array).unwrap_or(false) {
            let list = map.get("tracks").and_then(Value::as_array).unwrap();
            if map.contains_key("query") {
                self.styled_search_header(map);
                self.styled_tracks(list, None, None);
            } else if map.contains_key("repeatMode")
                || map.contains_key("shuffle")
                || map.contains_key("index")
            {
                self.styled_queue_header(map, list.len());
                self.styled_tracks(list, None, None);
            } else if map.contains_key("source") {
                self.styled_liked_header(map);
                self.styled_tracks(list, None, None);
            } else {
                self.styled_tracks(list, map.get("total"), None);
            }
            return;
        }
        if map.contains_key("playing") {
            self.styled_status(map);
            return;
        }
        if map.contains_key("ok") || map.contains_key("liked") {
            self.styled_confirm(map);
            return;
        }
        self.styled_indented(&Value::Object(map.clone()), "  ");
    }

    fn styled_status(&mut self, map: &serde_json::Map<String, Value>) {
        let playing = map.get("playing").and_then(Value::as_bool).unwrap_or(false);
        let buffering = map.get("buffering").and_then(Value::as_bool).unwrap_or(false);
        let track = map.get("track").and_then(Value::as_object);
        let title = track
            .and_then(|t| t.get("title"))
            .or_else(|| map.get("title"))
            .map(str_value)
            .unwrap_or_default();
        let artists = match track {
            Some(t) => artists(&Value::Object(t.clone())),
            None => artists(&Value::Object(map.clone())),
        };

        let state_word = if buffering {
            self.lbl("mcpShellLblBuffering")
        } else if playing {
            self.lbl("mcpShellLblPlaying")
        } else {
            self.lbl("mcpShellLblPaused")
        };
        let icon = if buffering {
            "◌"
        } else if playing {
            "▶"
        } else {
            "⏸"
        };
        let good = !buffering && playing;
        let accent = self.style.accent(good, icon);

        let mut meta: Vec<String> = Vec::new();
        if let Some(r) = track.and_then(|t| t.get("ref")).filter(|v| !v.is_null()) {
            meta.push(self.style.dim(&str_value(r)));
        }
        if let Some(v) = map.get("volume").and_then(Value::as_f64) {
            meta.push(self.style.dim(&format!(
                "{} {}%",
                self.lbl("mcpShellLblVolume"),
                (v * 100.0).round() as i64
            )));
        }
        if let Some(q) = map.get("quality").filter(|v| !v.is_null()) {
            meta.push(self.style.dim(&format!(
                "{} {}",
                self.lbl("mcpShellLblQuality"),
                str_value(q)
            )));
        }
        if let Some(r) = map.get("repeatMode").filter(|v| !v.is_null()) {
            meta.push(self.style.dim(&format!(
                "{} {}",
                self.lbl("mcpShellLblRepeat"),
                str_value(r)
            )));
        }
        if map.get("shuffle").and_then(Value::as_bool).unwrap_or(false) {
            meta.push(self.style.dim(&self.lbl("mcpShellLblShuffleOn")));
        }
        let meta_line = meta.join(&self.style.dim(" · "));

        let pos = format_ms(map.get("positionMs"));
        let dur = format_ms(map.get("durationMs"));
        let time = format!("{pos} / {dur}");

        let title_text = if title.is_empty() { "—" } else { &title };
        let mut head: Vec<String> = vec![format!(
            "{accent}  {}",
            self.style.bold(title_text)
        )];
        if !artists.is_empty() {
            head.push(format!("   {}", self.style.dim(&artists)));
        }

        const PAD: usize = 2;
        let time_w = display_width(&time);
        const MIN_BAR: usize = 10;
        let cap = std::cmp::max(8, std::cmp::min(self.columns.saturating_sub(2), 72));
        let mut need = head
            .iter()
            .map(|l| display_width(l))
            .chain(std::iter::once(display_width(&meta_line)))
            .chain(std::iter::once(time_w + 2 + MIN_BAR))
            .max()
            .unwrap_or(0)
            + PAD * 2;
        need = need.clamp(std::cmp::min(24, cap), cap);
        let content_w = need - PAD * 2;
        let bar = self.bar(
            ratio(map.get("positionMs"), map.get("durationMs")),
            content_w.saturating_sub(time_w + 2),
        );

        let mut body: Vec<String> = Vec::new();
        body.extend(head);
        body.push(String::new());
        if bar.is_empty() {
            body.push(self.style.dim(&time));
        } else {
            body.push(format!("{bar}  {}", self.style.dim(&time)));
        }
        if !meta_line.is_empty() {
            body.push(String::new());
            body.push(meta_line);
        }

        let title_line = format!(
            "{} {}",
            self.style.cyan("♪"),
            self.style.bold(&state_word)
        );
        self.panel(&title_line, &body, PAD, Some(need));
    }

    fn styled_info(&mut self, map: &serde_json::Map<String, Value>) {
        const PAD: usize = 2;
        let name = map.get("name").map(str_value).unwrap_or_else(|| "ArchoeraMusic".into());
        let labels = [
            self.lbl("mcpShellLblVersion"),
            self.lbl("mcpShellLblPlatform"),
            self.lbl("mcpShellLblPort"),
            self.lbl("mcpShellLblProtocol"),
            self.lbl("mcpShellLblEndpoints"),
            self.lbl("mcpShellLblCaps"),
        ];
        let label_w = labels.iter().map(|l| display_width(l)).max().unwrap_or(0);
        let target = std::cmp::max(
            28,
            std::cmp::min(self.columns.saturating_sub(2), 68),
        ) - PAD * 2;

        let kv = |r: &Renderer, label: &str, value: &str| {
            format!("{}  {value}", r.style.dim(&Renderer::fit_cell(label, label_w)))
        };

        let mut body: Vec<String> = Vec::new();
        if let Some(v) = map.get("version").filter(|v| !v.is_null()) {
            body.push(kv(self, &labels[0], &str_value(v)));
        }
        if let Some(v) = map.get("platform").filter(|v| !v.is_null()) {
            body.push(kv(self, &labels[1], &str_value(v)));
        }
        if let Some(service) = map.get("service").and_then(Value::as_object) {
            body.push(String::new());
            if let Some(port) = service.get("port").filter(|v| !v.is_null()) {
                let lan = service.get("lan").and_then(Value::as_bool).unwrap_or(false);
                let scope = if lan {
                    self.lbl("mcpShellLblLan")
                } else {
                    self.lbl("mcpShellLblLoopback")
                };
                let value = format!("{}  {}", str_value(port), self.style.dim(&format!("({scope})")));
                body.push(kv(self, &labels[2], &value));
            }
            if let Some(p) = service.get("protocolVersion").filter(|v| !v.is_null()) {
                body.push(kv(self, &labels[3], &str_value(p)));
            }
            if let Some(endpoints) = service.get("endpoints").and_then(Value::as_object) {
                let parts: Vec<String> = endpoints
                    .iter()
                    .map(|(k, v)| {
                        format!(
                            "{} {}",
                            self.style.dim(&format!("{k} ")),
                            self.style.cyan(&str_value(v))
                        )
                    })
                    .collect();
                body.push(kv(self, &labels[4], &parts.join(&self.style.dim("  ·  "))));
            }
            if let Some(caps) = service.get("capabilities").and_then(Value::as_array) {
                if !caps.is_empty() {
                    let items: Vec<String> = caps.iter().map(str_value).collect();
                    body.extend(self.chip_lines(&labels[5], &items, label_w, target));
                }
            }
        }

        let title = format!("{} {}", self.style.cyan("♪"), self.style.bold(&name));
        self.panel(&title, &body, PAD, None);
    }

    fn styled_library_stats(&mut self, map: &serde_json::Map<String, Value>) {
        const PAD: usize = 2;
        let labels = [
            self.lbl("mcpShellLblTracks"),
            self.lbl("mcpShellLblSize"),
            self.lbl("mcpShellLblDuration"),
        ];
        let label_w = labels.iter().map(|l| display_width(l)).max().unwrap_or(0);
        let kv = |r: &Renderer, label: &str, value: &str| {
            format!("{}  {value}", r.style.dim(&Renderer::fit_cell(label, label_w)))
        };
        let mut body: Vec<String> = Vec::new();
        if let Some(v) = map.get("tracks") {
            body.push(kv(self, &labels[0], &self.style.bold(&str_value(v))));
        }
        if let Some(v) = map.get("totalSizeBytes").and_then(Value::as_i64) {
            body.push(kv(self, &labels[1], &format_bytes(v)));
        }
        if let Some(v) = map.get("totalDurationMs").and_then(Value::as_i64) {
            body.push(kv(self, &labels[2], &format_duration(v)));
        }
        if body.is_empty() {
            body.push(format!("· {}", self.lbl("mcpShellLblEmpty")));
        }
        let title = format!(
            "{} {}",
            self.style.cyan("♪"),
            self.style.bold(&self.lbl("mcpShellLblLibrary"))
        );
        self.panel(&title, &body, PAD, None);
    }

    fn styled_search_header(&mut self, map: &serde_json::Map<String, Value>) {
        let (lbl_page, lbl_total, lbl_search) = (
            self.lbl("mcpShellLblPage"),
            self.lbl("mcpShellLblTotal"),
            self.lbl("mcpShellLblSearch"),
        );
        let mut segs: Vec<String> = Vec::new();
        if let Some(s) = map.get("source").filter(|v| !v.is_null()) {
            segs.push(self.style.cyan(&self.style.bold(&str_value(s))));
        }
        if let Some(q) = map.get("query").filter(|v| !v.is_null()) {
            segs.push(format!("“{}”", self.style.bold(&str_value(q))));
        }
        if let Some(p) = map.get("page").filter(|v| !v.is_null()) {
            segs.push(self.style.dim(&format!("{lbl_page} {}", str_value(p))));
        }
        if let Some(t) = map.get("total").filter(|v| !v.is_null()) {
            segs.push(self.style.dim(&format!("{lbl_total} {}", str_value(t))));
        }
        let sep = self.style.dim("  ·  ");
        let line = format!("  {}  {}", self.style.dim(&lbl_search), segs.join(&sep));
        self.w(&line);
    }

    fn styled_queue_header(
        &mut self,
        map: &serde_json::Map<String, Value>,
        len: usize,
    ) {
        let (lbl_index, lbl_repeat, lbl_queue, lbl_on, lbl_off) = (
            self.lbl("mcpShellLblIndex"),
            self.lbl("mcpShellLblRepeat"),
            self.lbl("mcpShellLblQueue"),
            self.lbl("mcpShellLblShuffleOn"),
            self.lbl("mcpShellLblShuffleOff"),
        );
        let mut segs: Vec<String> = Vec::new();
        if let Some(idx) = map.get("index").and_then(Value::as_i64) {
            if len > 0 {
                segs.push(self.style.dim(&format!("{lbl_index} {}/{}", idx + 1, len)));
            }
        }
        if let Some(r) = map.get("repeatMode").filter(|v| !v.is_null()) {
            segs.push(self.style.dim(&format!("{lbl_repeat} {}", str_value(r))));
        }
        let shuffle = map.get("shuffle").and_then(Value::as_bool).unwrap_or(false);
        segs.push(self.style.dim(if shuffle { &lbl_on } else { &lbl_off }));
        let sep = self.style.dim("  ·  ");
        let line = format!("  {}  {}", self.style.dim(&lbl_queue), segs.join(&sep));
        self.w(&line);
    }

    fn styled_liked_header(&mut self, map: &serde_json::Map<String, Value>) {
        let (lbl_liked, lbl_total) = (
            self.lbl("mcpShellLblLiked"),
            self.lbl("mcpShellLblTotal"),
        );
        let source = map.get("source").map(str_value).unwrap_or_default();
        let total = match map.get("total").filter(|v| !v.is_null()) {
            Some(t) => self.style.dim(&format!("  ·  {lbl_total} {}", str_value(t))),
            None => String::new(),
        };
        let line = format!(
            "  {}  {}{total}",
            self.style.dim(&lbl_liked),
            self.style.cyan(&self.style.bold(&source))
        );
        self.w(&line);
    }

    fn styled_search_all(&mut self, map: &serde_json::Map<String, Value>) {
        if let Some(q) = map.get("query").filter(|v| !v.is_null()) {
            let line = format!(
                "  {}  {}",
                self.style.dim(&self.lbl("mcpShellLblQuery")),
                self.style.bold(&str_value(q))
            );
            self.w(&line);
        }
        let Some(results) = map.get("results").and_then(Value::as_array) else {
            return;
        };
        for item in results {
            let Some(m) = item.as_object() else { continue };
            let source = m.get("source").map(str_value).unwrap_or_else(|| "?".into());
            if let Some(err) = m.get("error").filter(|v| !v.is_null()) {
                let line = format!(
                    "  {} {}  {}",
                    self.style.dim("──"),
                    self.style.red(&self.style.bold(&source)),
                    self.style
                        .red(&format!("{}: {}", self.lbl("mcpShellLblError"), str_value(err)))
                );
                self.w(&line);
                continue;
            }
            let badge = match m.get("total").filter(|v| !v.is_null()) {
                Some(t) => {
                    let more = if m.get("hasMore").and_then(Value::as_bool).unwrap_or(false) {
                        "+"
                    } else {
                        ""
                    };
                    format!("{}{more}", str_value(t))
                }
                None => String::new(),
            };
            self.section(&source, &badge);
            if let Some(tracks) = m.get("tracks").and_then(Value::as_array) {
                self.styled_tracks(tracks, None, None);
            }
        }
    }

    fn styled_tracks(
        &mut self,
        list: &[Value],
        total: Option<&Value>,
        extra: Option<&str>,
    ) {
        struct Row {
            index: String,
            title: String,
            artist: String,
            reference: String,
            extra: Option<String>,
            current: bool,
        }
        let mut rows: Vec<Row> = Vec::new();
        for (i, item) in list.iter().enumerate() {
            let Some(m) = item.as_object() else { continue };
            let raw_extra = extra.and_then(|tag| m.get(tag));
            rows.push(Row {
                index: (i + 1).to_string(),
                title: m.get("title").map(str_value).unwrap_or_default(),
                artist: artists(item),
                reference: m.get("ref").map(str_value).unwrap_or_default(),
                extra: extra.map(|_| match raw_extra {
                    Some(v) => relative_time(v),
                    None => String::new(),
                }),
                current: m.get("isCurrent").and_then(Value::as_bool).unwrap_or(false),
            });
        }

        if let Some(t) = total {
            let line = format!(
                "  {}",
                self.style
                    .dim(&format!("{} {}", self.lbl("mcpShellLblTotal"), str_value(t)))
            );
            self.w(&line);
        }
        if rows.is_empty() {
            let line = format!("  · {}", self.lbl("mcpShellLblEmpty"));
            self.w(&line);
            return;
        }

        let idx_w = std::cmp::max(2, rows.iter().map(|r| display_width(&r.index)).max().unwrap_or(1));
        let ref_w = col_width(rows.iter().map(|r| r.reference.as_str()), 1usize << 20, 3);
        let artist_w = col_width(rows.iter().map(|r| r.artist.as_str()), 26, 6);
        let extra_w = col_width(
            rows.iter().filter_map(|r| r.extra.as_deref()),
            24,
            0,
        );
        let mut title_w = col_width(rows.iter().map(|r| r.title.as_str()), 48, 5);
        let mut shrunk_artist = artist_w;
        let mut shrunk_ref = ref_w;
        let mut shrunk_extra = extra_w;

        const MARGIN: usize = 2;
        const GAP: usize = 2;
        let available = std::cmp::max(1, self.columns.saturating_sub(MARGIN));
        let extent = |title_w: usize, artist: usize, refw: usize, extraw: usize| {
            MARGIN
                + idx_w
                + if title_w > 0 { GAP + title_w } else { 0 }
                + if artist > 0 { GAP + artist } else { 0 }
                + if refw > 0 { GAP + refw } else { 0 }
                + if extraw > 0 { GAP + extraw } else { 0 }
        };
        while extent(title_w, shrunk_artist, shrunk_ref, shrunk_extra) > available {
            if shrunk_extra > 0 {
                shrunk_extra = 0;
            } else if title_w > 8 {
                title_w -= 1;
            } else if shrunk_artist > 6 {
                shrunk_artist -= 1;
            } else if shrunk_artist > 0 {
                shrunk_artist = 0;
            } else if title_w > 1 {
                title_w -= 1;
            } else {
                break;
            }
        }
        while extent(title_w, shrunk_artist, shrunk_ref, shrunk_extra) > available && shrunk_ref > 4 {
            shrunk_ref -= 1;
        }
        if extent(title_w, shrunk_artist, shrunk_ref, shrunk_extra) > available {
            shrunk_ref = 0;
        }

        let (col_title, col_artist, col_ref, col_when) = (
            self.lbl("mcpShellLblColTitle"),
            self.lbl("mcpShellLblColArtist"),
            self.lbl("mcpShellLblColRef"),
            self.lbl("mcpShellLblColWhen"),
        );
        let mut header = format!("{}{}", " ".repeat(MARGIN), self.style.dim(&pad_index_w(&"#", idx_w)));
        if title_w > 0 {
            header.push_str(&format!("{}{}", " ".repeat(GAP), self.style.dim(&Renderer::fit_cell(&col_title, title_w))));
        }
        if shrunk_artist > 0 {
            header.push_str(&format!("{}{}", " ".repeat(GAP), self.style.dim(&Renderer::fit_cell(&col_artist, shrunk_artist))));
        }
        if shrunk_ref > 0 {
            header.push_str(&format!("{}{}", " ".repeat(GAP), self.style.dim(&Renderer::fit_cell(&col_ref, shrunk_ref))));
        }
        if shrunk_extra > 0 {
            header.push_str(&format!("{}{}", " ".repeat(GAP), self.style.dim(&Renderer::fit_cell(&col_when, shrunk_extra))));
        }
        self.w(&header);

        for r in &rows {
            let mut buf = " ".repeat(MARGIN);
            if r.current {
                buf.push_str(&self.style.green("▶"));
                buf.push_str(&" ".repeat(idx_w.saturating_sub(1)));
            } else {
                buf.push_str(&self.style.dim(&pad_index_w(&r.index, idx_w)));
            }
            if title_w > 0 {
                buf.push_str(&" ".repeat(GAP));
                let cell = Renderer::fit_cell(&r.title, title_w);
                buf.push_str(&if r.current {
                    self.style.green(&cell)
                } else {
                    cell
                });
            }
            if shrunk_artist > 0 {
                buf.push_str(&" ".repeat(GAP));
                buf.push_str(&self.style.dim(&Renderer::fit_cell(&r.artist, shrunk_artist)));
            }
            if shrunk_ref > 0 {
                buf.push_str(&" ".repeat(GAP));
                buf.push_str(&self.style.cyan(&Renderer::fit_cell(&r.reference, shrunk_ref)));
            }
            if shrunk_extra > 0 {
                if let Some(x) = &r.extra {
                    buf.push_str(&" ".repeat(GAP));
                    buf.push_str(&self.style.dim(&Renderer::fit_cell(x, shrunk_extra)));
                }
            }
            self.w(&buf);
        }
    }

    fn styled_download_tasks(
        &mut self,
        list: &[Value],
        total: Option<&Value>,
    ) {
        if let Some(t) = total {
            let line = format!(
                "  {}",
                self.style
                    .dim(&format!("{} {}", self.lbl("mcpShellLblTotal"), str_value(t)))
            );
            self.w(&line);
        }
        if list.is_empty() {
            let line = format!("  · {}", self.lbl("mcpShellLblEmpty"));
            self.w(&line);
            return;
        }
        for item in list {
            let Some(m) = item.as_object() else { continue };
            let status = m.get("status").map(str_value).unwrap_or_else(|| "-".into());
            let (icon, color) = download_state(&status);
            let ratio = m.get("progress").and_then(Value::as_f64).unwrap_or(0.0).clamp(0.0, 1.0);
            let colored = |s: &str| match color {
                StateColor::Green => self.style.green(s),
                StateColor::Red => self.style.red(s),
                StateColor::Cyan => self.style.cyan(s),
                StateColor::Yellow => self.style.yellow(s),
                StateColor::Dim => self.style.dim(s),
            };
            let pct = match m.get("progress").and_then(Value::as_f64) {
                Some(p) => format!("{:.1}%", p * 100.0),
                None => "-".to_string(),
            };
            let artist = m.get("artist").map(str_value).unwrap_or_default();
            let task_id = m.get("taskId").map(str_value).unwrap_or_default();
            let mut line = format!(
                "  {}  {}  {}  {}  {}",
                colored(icon),
                colored(&pad_right(&status, 11)),
                self.bar(ratio, 16),
                self.style.dim(&pad_right(&pct, 6)),
                self.style.bold(&m.get("title").map(str_value).unwrap_or_default()),
            );
            if !artist.is_empty() {
                line.push_str(&format!("  {}", self.style.dim(&artist)));
            }
            if !task_id.is_empty() {
                line.push_str(&format!("  {}", self.style.dim(&task_id)));
            }
            self.w(&line);
        }
    }

    fn styled_lyrics(&mut self, list: &[Value]) {
        for item in list {
            let Some(m) = item.as_object() else { continue };
            let time = format_ms(m.get("timeMs"));
            let text = m.get("text").map(str_value).unwrap_or_default();
            let line = format!("  {}  {text}", self.style.dim(&time));
            self.w(&line);
            if let Some(t) = m.get("translation").filter(|v| !v.is_null()) {
                let line = format!("{}{}", " ".repeat(9), self.style.dim(&self.style.italic(&str_value(t))));
                self.w(&line);
            }
        }
    }

    fn styled_tools(&mut self, list: &[Value]) {
        let rows: Vec<(String, String, String)> = list
            .iter()
            .filter_map(Value::as_object)
            .map(|m| {
                (
                    m.get("name").map(str_value).unwrap_or_default(),
                    m.get("capability").map(str_value).unwrap_or_default(),
                    m.get("title").map(str_value).unwrap_or_default(),
                )
            })
            .collect();
        if rows.is_empty() {
            return;
        }
        let (lbl_name, lbl_cap, lbl_title) = (
            self.lbl("mcpShellLblToolName"),
            self.lbl("mcpShellLblToolCap"),
            self.lbl("mcpShellLblToolTitle"),
        );
        let name_w = std::cmp::min(
            28,
            std::cmp::max(
                display_width(&lbl_name),
                rows.iter().map(|r| display_width(&r.0)).max().unwrap_or(0),
            ),
        );
        let cap_w = std::cmp::min(
            14,
            std::cmp::max(
                display_width(&lbl_cap),
                rows.iter().map(|r| display_width(&r.1)).max().unwrap_or(0),
            ),
        );
        let hdr = format!(
            "  {}  {}  {}",
            self.style.dim(&pad_right(&lbl_name, name_w)),
            self.style.dim(&pad_right(&lbl_cap, cap_w)),
            self.style.dim(&lbl_title)
        );
        self.w(&hdr);
        for (name, capability, title) in &rows {
            let line = format!(
                "  {}  {}  {title}",
                self.style.cyan(&Renderer::fit_cell(name, name_w)),
                self.style.dim(&Renderer::fit_cell(capability, cap_w)),
            );
            self.w(&line);
        }
    }

    fn styled_sources(&mut self, list: &[Value]) {
        let rows: Vec<(String, String, bool)> = list
            .iter()
            .filter_map(Value::as_object)
            .map(|m| {
                (
                    m.get("source").map(str_value).unwrap_or_default(),
                    m.get("label").map(str_value).unwrap_or_default(),
                    m.get("loggedIn").and_then(Value::as_bool).unwrap_or(false),
                )
            })
            .collect();
        if rows.is_empty() {
            return;
        }
        let label_w = std::cmp::min(20, rows.iter().map(|r| display_width(&r.1)).max().unwrap_or(5));
        let source_w = std::cmp::min(16, rows.iter().map(|r| display_width(&r.0)).max().unwrap_or(6));
        let (lbl_in, lbl_out) = (
            self.lbl("mcpShellLblLoggedIn"),
            self.lbl("mcpShellLblLoggedOut"),
        );
        for (source, label, logged) in &rows {
            let dot = if *logged { self.style.green("●") } else { self.style.dim("○") };
            let state = if *logged {
                self.style.dim(&lbl_in)
            } else {
                self.style.dim(&lbl_out)
            };
            let line = format!(
                "  {dot}  {}  {}  {state}",
                self.style.cyan(&Renderer::fit_cell(source, source_w)),
                Renderer::fit_cell(label, label_w),
            );
            self.w(&line);
        }
    }

    fn styled_values(&mut self, map: &serde_json::Map<String, Value>) {
        if map.is_empty() {
            let line = format!("  · {}", self.lbl("mcpShellLblEmpty"));
            self.w(&line);
            return;
        }
        let key_w = map
            .keys()
            .map(|k| display_width(k))
            .max()
            .unwrap_or(0)
            .min(28);
        for (k, v) in map {
            let line = format!(
                "  {}  {}  {}",
                self.style.cyan(&Renderer::fit_cell(k, key_w)),
                self.style.dim("="),
                plain_value(v)
            );
            self.w(&line);
        }
    }

    fn styled_confirm(&mut self, map: &serde_json::Map<String, Value>) {
        let reference = map.get("ref").filter(|v| !v.is_null());
        if let Some(liked) = map.get("liked").and_then(Value::as_bool) {
            if map.get("ok").and_then(Value::as_bool) != Some(true) {
                let mark = if liked { self.style.red("♥") } else { self.style.dim("♡") };
                let state = if liked {
                    self.lbl("mcpShellLblLiked")
                } else {
                    self.lbl("mcpShellLblNotLiked")
                };
                let refpart = match reference {
                    Some(r) => format!("  {}", self.style.dim(&str_value(r))),
                    None => String::new(),
                };
                let line = format!("  {mark}  {state}{refpart}");
                self.w(&line);
                return;
            }
        }
        let lbl_sleep = self.lbl("mcpShellLblSleep");
        if map.get("mode").map(str_value).as_deref() == Some("endOfTrack") {
            let line = format!(
                "  {}  {}  {}",
                self.style.green("✓"),
                self.style.dim(&lbl_sleep),
                self.lbl("mcpShellLblEndOfTrack")
            );
            self.w(&line);
            return;
        }
        if map.get("mode").map(str_value).as_deref() == Some("duration") {
            if let Some(m) = map.get("minutes").and_then(Value::as_i64) {
                let line = format!("  {}  {}  {m}m", self.style.green("✓"), self.style.dim(&lbl_sleep));
                self.w(&line);
                return;
            }
        }

        let lbl_volume = self.lbl("mcpShellLblVolume");
        let lbl_repeat = self.lbl("mcpShellLblRepeat");
        let lbl_on = self.lbl("mcpShellLblShuffleOn");
        let lbl_off = self.lbl("mcpShellLblShuffleOff");
        let lbl_quality = self.lbl("mcpShellLblQuality");
        let lbl_playing = self.lbl("mcpShellLblNowPlaying");
        let lbl_task = self.lbl("mcpShellLblTask");
        let lbl_liked = self.lbl("mcpShellLblLiked");
        let lbl_unliked = self.lbl("mcpShellLblUnliked");
        let lbl_queued = self.lbl("mcpShellLblQueued");
        let lbl_count = self.lbl("mcpShellLblCount");
        let lbl_theme = self.lbl("mcpShellLblTheme");
        let mut parts: Vec<String> = Vec::new();
        for (k, v) in map {
            if k == "ok" || k == "startIndex" || v.is_null() {
                continue;
            }
            match k.as_str() {
                "volume" => {
                    if let Some(n) = v.as_f64() {
                        parts.push(format!("{lbl_volume} {}%", (n * 100.0).round() as i64));
                    }
                }
                "repeatMode" => parts.push(format!("{lbl_repeat} {}", str_value(v))),
                "shuffle" => parts.push(if v.as_bool().unwrap_or(false) {
                    lbl_on.clone()
                } else {
                    lbl_off.clone()
                }),
                "quality" => parts.push(format!("{lbl_quality} {}", str_value(v))),
                "ref" => parts.push(format!("{lbl_playing} {}", str_value(v))),
                "taskId" => parts.push(format!("{lbl_task} {}", str_value(v))),
                "liked" => parts.push(if v.as_bool().unwrap_or(false) {
                    lbl_liked.clone()
                } else {
                    lbl_unliked.clone()
                }),
                "count" => {
                    if map.contains_key("position") {
                        parts.push(format!("{lbl_queued} {}", str_value(v)));
                    } else {
                        parts.push(format!("{lbl_count} {}", str_value(v)));
                    }
                }
                "position" => parts.push(format!("→ {}", str_value(v))),
                "mode" => parts.push(format!("{lbl_theme} {}", str_value(v))),
                _ => parts.push(format!("{k} {}", str_value(v))),
            }
        }
        let detail = if parts.is_empty() {
            self.lbl("mcpShellLblOk")
        } else {
            parts.join(&self.style.dim("  ·  "))
        };
        let line = format!("  {}  {detail}", self.style.green("✓"));
        self.w(&line);
    }

    fn styled_indented(&mut self, value: &Value, indent: &str) {
        match value {
            Value::Object(map) => {
                for (k, v) in map {
                    if v.is_null() {
                        continue;
                    }
                    if v.is_object() || v.is_array() {
                        let line = format!("{indent}{}{}", self.style.cyan(k), self.style.dim(":"));
                        self.w(&line);
                        self.styled_indented(v, &format!("{indent}  "));
                    } else {
                        let line = format!(
                            "{indent}{}{} {}",
                            self.style.cyan(k),
                            self.style.dim(":"),
                            plain_value(v)
                        );
                        self.w(&line);
                    }
                }
            }
            Value::Array(items) => {
                for item in items {
                    if item.is_object() || item.is_array() {
                        let line = format!("{indent}{}", self.style.dim("·"));
                        self.w(&line);
                        self.styled_indented(item, &format!("{indent}  "));
                    } else {
                        let line = format!("{indent}{} {}", self.style.dim("·"), plain_value(item));
                        self.w(&line);
                    }
                }
            }
            other => {
                let line = format!("{indent}{}", plain_value(other));
                self.w(&line);
            }
        }
    }

    // ── 面板/进度条/组头 ─────────────────────────────────────────

    fn panel(&mut self, title: &str, body: &[String], pad: usize, inner: Option<usize>) {
        let cap = std::cmp::max(8, self.columns.saturating_sub(2));
        let mut t = title.to_string();
        let mut need = body
            .iter()
            .map(|l| display_width(l) + pad * 2)
            .max()
            .unwrap_or(0);
        need = std::cmp::max(need, display_width(&t) + 3);
        let box_inner = inner
            .unwrap_or(need)
            .clamp(std::cmp::min(20, cap), cap);
        if display_width(&t) + 3 > box_inner {
            t = truncate(&t, std::cmp::max(1, box_inner - 3));
        }
        let content_w = box_inner - pad * 2;
        let dashes = box_inner.saturating_sub(display_width(&t) + 3);
        let top = format!(
            "{} {} {}",
            self.style.dim("╭─"),
            t,
            self.style.dim(&format!("{}╮", "─".repeat(dashes)))
        );
        self.w(&top);
        for line in body {
            let l = if display_width(line) > content_w {
                truncate(line, content_w)
            } else {
                line.clone()
            };
            let fill = content_w.saturating_sub(display_width(&l));
            let row = format!(
                "{}{}{}{}{}",
                self.style.dim("│"),
                " ".repeat(pad),
                l,
                " ".repeat(fill),
                format_args!("{}{}", " ".repeat(pad), self.style.dim("│"))
            );
            self.w(&row);
        }
        let bottom = self.style.dim(&format!("╰{}╯", "─".repeat(box_inner)));
        self.w(&bottom);
    }

    fn section(&mut self, title: &str, badge: &str) {
        let badge_part = if badge.is_empty() {
            String::new()
        } else {
            format!(" {}", self.style.dim(badge))
        };
        let used = 6 + display_width(title) + if badge.is_empty() { 0 } else { 1 + display_width(badge) };
        let fill = std::cmp::max(1, self.columns.saturating_sub(used));
        let line = format!(
            "  {} {} {}{badge_part}",
            self.style.dim("──"),
            self.style.cyan(&self.style.bold(title)),
            self.style.dim(&"─".repeat(fill))
        );
        self.w(&line);
    }

    fn chip_lines(
        &self,
        label: &str,
        items: &[String],
        label_w: usize,
        max_width: usize,
    ) -> Vec<String> {
        let prefix = format!("{}  ", self.style.dim(&Renderer::fit_cell(label, label_w)));
        let indent = " ".repeat(label_w + 2);
        let mut lines = Vec::new();
        let mut line = String::new();
        let mut line_w = 0usize;
        let mut line_prefix = prefix;
        for item in items {
            let chip_w = display_width(item);
            let needed = if line_w == 0 { chip_w } else { line_w + 2 + chip_w };
            if line_w > 0 && label_w + 2 + needed > max_width {
                lines.push(format!("{line_prefix}{line}"));
                line = String::new();
                line_w = 0;
                line_prefix = indent.clone();
            }
            if line_w > 0 {
                line.push_str("  ");
                line_w += 2;
            }
            line.push_str(&self.style.cyan(item));
            line_w += chip_w;
        }
        if !line.is_empty() {
            lines.push(format!("{line_prefix}{line}"));
        }
        lines
    }

    fn bar(&self, ratio: f64, width: usize) -> String {
        if width < 4 {
            return String::new();
        }
        let filled = (ratio * width as f64).round().clamp(0.0, width as f64) as usize;
        let mut parts: Vec<String> = Vec::new();
        if filled > 0 {
            parts.push(self.style.cyan(&"█".repeat(filled)));
        }
        if width - filled > 0 {
            parts.push(self.style.dim(&"░".repeat(width - filled)));
        }
        parts.join("")
    }
}

// ── 辅助 ──────────────────────────────────────────────────────────

enum StateColor {
    Green,
    Red,
    Cyan,
    Yellow,
    Dim,
}

fn download_state(status: &str) -> (&'static str, StateColor) {
    let s = status.to_ascii_lowercase();
    if s.contains("fail") || s.contains("error") {
        ("✗", StateColor::Red)
    } else if s.contains("done") || s.contains("complet") || s.contains("success") {
        ("✓", StateColor::Green)
    } else if s.contains("download") || s.contains("active") || s.contains("running") {
        ("↓", StateColor::Cyan)
    } else if s.contains("pause") || s.contains("wait") || s.contains("queue") || s.contains("pending") {
        ("◌", StateColor::Yellow)
    } else if s.contains("cancel") {
        ("⊗", StateColor::Dim)
    } else {
        ("·", StateColor::Dim)
    }
}

fn artists(item: &Value) -> String {
    if let Some(arr) = item.get("artists").and_then(Value::as_array) {
        return arr
            .iter()
            .filter(|v| !v.is_null())
            .map(str_value)
            .collect::<Vec<_>>()
            .join(" / ");
    }
    item.get("artist").map(str_value).unwrap_or_default()
}

fn str_value(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        _ => plain_value(v),
    }
}

fn plain_value(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn format_ms(v: Option<&Value>) -> String {
    let Some(ms) = v.and_then(Value::as_f64) else {
        return "--:--".to_string();
    };
    let total = ms as i64;
    let seconds = total / 1000;
    let h = seconds / 3600;
    let m = (seconds % 3600) / 60;
    let s = seconds % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m:02}:{s:02}")
    }
}

fn format_bytes(bytes: i64) -> String {
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    const UNITS: [&str; 5] = ["KiB", "MiB", "GiB", "TiB", "PiB"];
    let mut value = bytes as f64 / 1024.0;
    let mut unit = 0usize;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    let decimals = if value >= 100.0 { 0 } else { 1 };
    format!("{value:.decimals$} {}", UNITS[unit])
}

fn format_duration(ms: i64) -> String {
    let total = ms / 1000;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    let mut parts: Vec<String> = Vec::new();
    if h > 0 {
        parts.push(format!("{h}h"));
    }
    if m > 0 {
        parts.push(format!("{m}m"));
    }
    if s > 0 || (h == 0 && m == 0) {
        parts.push(format!("{s}s"));
    }
    parts.join(" ")
}

fn relative_time(v: &Value) -> String {
    let Some(ms) = v.as_i64() else {
        return String::new();
    };
    if ms <= 0 {
        return String::new();
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let diff = now - ms;
    if diff < 0 {
        return "now".to_string();
    }
    let seconds = diff / 1000;
    if seconds < 60 {
        return "just now".to_string();
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{minutes}m ago");
    }
    let hours = minutes / 60;
    if hours < 24 {
        return format!("{hours}h ago");
    }
    let days = hours / 24;
    if days < 30 {
        return format!("{days}d ago");
    }
    // 久远：显示日期（用 UTC 天数换算，避免引入 chrono）。
    let days_since_epoch = ms / 86_400_000;
    let (y, m, d) = civil_from_days(days_since_epoch);
    format!("{y}-{m:02}-{d:02}")
}

/// Howard Hinnant 的 `civil_from_days` 算法（UTC）。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn ratio(pos: Option<&Value>, dur: Option<&Value>) -> f64 {
    let (Some(p), Some(d)) = (pos.and_then(Value::as_f64), dur.and_then(Value::as_f64)) else {
        return 0.0;
    };
    if d <= 0.0 {
        return 0.0;
    }
    (p / d).clamp(0.0, 1.0)
}

fn col_width<'a>(cells: impl Iterator<Item = &'a str>, cap: usize, min: usize) -> usize {
    let mut w = 0;
    for c in cells {
        w = std::cmp::max(w, display_width(c));
    }
    if w == 0 {
        0
    } else {
        std::cmp::min(std::cmp::max(w, min), cap)
    }
}

fn pad_index_w(index: &str, width: usize) -> String {
    let w = display_width(index);
    if w >= width {
        return index.to_string();
    }
    format!("{}{}", " ".repeat(width - w), index)
}

fn pad_index(line: &str, number: usize) -> String {
    // 把序号 part 左补空格到 3 位（Dart padLeft(3)）。
    let idx = number.to_string();
    let padded = format!("{:>3}", idx);
    // line 以 `{idx}  ` 开头，替换为 padded。
    if let Some(rest) = line.strip_prefix(&idx) {
        format!("{padded}{rest}")
    } else {
        line.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn render_styled(v: Value, columns: usize) -> String {
        let mut r = Renderer::new(columns, true, L10n::english());
        r.render(&v);
        crate::width::strip_ansi(&r.out)
    }

    fn render_plain(v: Value) -> String {
        let mut r = Renderer::new(80, false, L10n::english());
        r.render(&v);
        r.out
    }

    #[test]
    fn status_panel_has_equal_borders() {
        let v = json!({
            "playing": true,
            "positionMs": 61000,
            "durationMs": 180000,
            "volume": 0.8,
            "repeatMode": "list",
            "track": {"title": "Song", "artists": ["A", "B"], "ref": "netease:1"}
        });
        let out = render_styled(v, 80);
        let lines: Vec<&str> = out.lines().collect();
        assert!(lines[0].starts_with("╭─"));
        assert!(out.contains("Playing"));
        assert!(out.contains("01:01 / 03:00"));
        assert!(out.contains("vol 80%"));
        let widths: std::collections::HashSet<usize> =
            lines.iter().map(|l| display_width(l)).collect();
        // 面板上下边框与内容行等宽。
        assert_eq!(widths.len(), 1, "面板各行宽度不一致: {out}");
    }

    #[test]
    fn plain_status_matches_dart() {
        let v = json!({
            "playing": false,
            "positionMs": 1000,
            "durationMs": 2000,
            "track": {"title": "T", "artists": ["A"]}
        });
        let out = render_plain(v);
        assert!(out.contains("[paused]"));
        assert!(out.contains("T — A"));
        assert!(out.contains("00:01 / 00:02"));
    }

    #[test]
    fn tracks_keep_ref_and_shrink_title() {
        let v = json!({
            "source": "netease", "query": "q", "total": 1,
            "tracks": [{
                "ref": "netease:1843699265",
                "title": "这是一个相当长的歌曲标题用来挤占列宽应该被截断",
                "artists": ["An artist name"]
            }]
        });
        let out = render_styled(v, 60);
        assert!(out.contains("netease:1843699265"));
        assert!(out.contains('…'));
    }

    #[test]
    fn confirm_renders_summary() {
        let out = render_styled(json!({"ok": true, "volume": 0.5}), 80);
        assert!(out.contains('✓'));
        assert!(out.contains("vol 50%"));
        let liked = render_styled(json!({"ref": "neko:1", "liked": true}), 80);
        assert!(liked.contains('♥'));
        assert!(liked.contains("liked"));
        let playing = render_styled(json!({"ok": true, "ref": "neko:1"}), 80);
        assert!(playing.contains("playing neko:1"));
    }

    #[test]
    fn info_panel_wraps_caps() {
        let out = render_styled(
            json!({
                "name": "ArchoeraMusic",
                "version": "0.9.20+7",
                "platform": "linux",
                "service": {
                    "port": 14559,
                    "lan": false,
                    "protocolVersion": "2025-11-25",
                    "endpoints": {"mcp": "/mcp"},
                    "capabilities": ["read", "playback", "download"]
                }
            }),
            80,
        );
        assert!(out.contains("ArchoeraMusic"));
        assert!(out.contains("loopback"));
        assert!(out.contains("caps"));
        assert!(out.contains("download"));
    }

    #[test]
    fn labels_follow_locale() {
        let v = json!({
            "playing": true, "positionMs": 1, "durationMs": 2,
            "track": {"title": "歌", "artists": ["手"], "ref": "n:1"}
        });
        let mut zh = Renderer::new(80, true, L10n::new(Some("zh".to_string())));
        zh.render(&v);
        let out = crate::width::strip_ansi(&zh.out);
        assert!(out.contains("播放中"), "zh 标签未生效: {out}");
    }

    #[test]
    fn narrow_never_overflows() {
        let v = json!({
            "playing": true, "positionMs": 1, "durationMs": 2,
            "track": {"title": "非常非常非常非常非常非常非常长", "artists": ["很长很长的歌手"], "ref": "neko:25880"}
        });
        let out = render_styled(v, 20);
        for line in out.lines() {
            assert!(display_width(line) <= 20, "越界: {line:?}");
        }
    }
}

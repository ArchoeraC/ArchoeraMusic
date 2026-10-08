// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 交互式行编辑器：原始模式 + 转义序列解析 + 命令历史。
//!
//! REPL 用它替代裸 `lines()`：在规范（cooked）模式下 tty 行规程不提供历史与
//! 光标移动，方向键会被当成 `^[[A` 之类的转义字节塞进输入行（Windows 因宿主终端
//! 自带行编辑而"看起来能用"）。这里三端统一关闭行规程并自行解析按键，使
//! ←/→ 移动光标、↑/↓ 翻历史、Home/End、Ctrl-A/E/U/K/W/L 等在各平台一致。
//!
//! 纯逻辑（[`KeyParser`] / [`LineBuffer`] / [`Editor`] 的窗口计算与历史）与终端
//! IO 分离，便于确定性单测；实际读字节由 [`RawInput`] 承担。

use crate::term::RawInput;
use crate::width::{char_width, display_width};
use std::io::Write;

// ── 按键 ─────────────────────────────────────────────────────────

/// 一次按键（已从字节流解析）。
#[derive(Debug, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Enter,
    Backspace,
    Delete,
    Left,
    Right,
    Home,
    End,
    Up,
    Down,
    KillToEnd,
    KillToStart,
    DeleteWord,
    ClearScreen,
    /// Ctrl-C：放弃当前行。
    Cancel,
    /// Ctrl-D：空行时为 EOF，否则删除光标处字符。
    CtrlD,
    Ignore,
}

#[derive(Default)]
enum ParseState {
    #[default]
    Ground,
    /// 刚读到 `ESC`。
    Escape,
    /// `ESC [` / `ESC O` 之后，累积参数字节。
    Csi(Vec<u8>),
    /// 多字节 UTF-8 字符累积中。
    Utf8(Vec<u8>),
}

/// 字节流 → [`Key`] 的状态机（每字节最多产出一个按键）。
#[derive(Default)]
pub struct KeyParser {
    state: ParseState,
}

impl KeyParser {
    pub fn new() -> Self {
        Self::default()
    }

    /// 喂入一个字节；若拼出一个完整按键则返回它，否则返回 `None`。
    pub fn feed(&mut self, byte: u8) -> Option<Key> {
        let state = std::mem::take(&mut self.state);
        let (next, key) = match state {
            ParseState::Ground => ground(byte),
            ParseState::Escape => escape(byte),
            ParseState::Csi(params) => csi_step(params, byte),
            ParseState::Utf8(buf) => utf8_step(buf, byte),
        };
        self.state = next;
        key
    }
}

fn ground(b: u8) -> (ParseState, Option<Key>) {
    let key = match b {
        0x1b => return (ParseState::Escape, None),
        0x0d | 0x0a => Key::Enter,
        0x7f | 0x08 => Key::Backspace,
        0x01 => Key::Home,
        0x02 => Key::Left,
        0x03 => Key::Cancel,
        0x04 => Key::CtrlD,
        0x05 => Key::End,
        0x06 => Key::Right,
        0x0b => Key::KillToEnd,
        0x0c => Key::ClearScreen,
        0x0e => Key::Down,
        0x10 => Key::Up,
        0x15 => Key::KillToStart,
        0x17 => Key::DeleteWord,
        0x00 | 0x09 | 0x1a => Key::Ignore,
        b if b >= 0x80 => return (ParseState::Utf8(vec![b]), None),
        0x20..=0x7e => Key::Char(b as char),
        _ => Key::Ignore,
    };
    (ParseState::Ground, Some(key))
}

fn escape(b: u8) -> (ParseState, Option<Key>) {
    match b {
        b'[' | b'O' => (ParseState::Csi(Vec::new()), None),
        // Alt+键 等：忽略整个组合。
        _ => (ParseState::Ground, Some(Key::Ignore)),
    }
}

fn csi_step(mut params: Vec<u8>, b: u8) -> (ParseState, Option<Key>) {
    if (0x40..=0x7e).contains(&b) {
        return (ParseState::Ground, Some(map_csi(&params, b)));
    }
    if params.len() >= 16 {
        // 异常长序列：丢弃，避免状态机被拖住。
        return (ParseState::Ground, Some(Key::Ignore));
    }
    params.push(b);
    (ParseState::Csi(params), None)
}

fn map_csi(params: &[u8], final_byte: u8) -> Key {
    match final_byte {
        b'A' => Key::Up,
        b'B' => Key::Down,
        b'C' => Key::Right,
        b'D' => Key::Left,
        b'H' => Key::Home,
        b'F' => Key::End,
        b'~' => match params {
            b"1" | b"7" => Key::Home,
            b"3" => Key::Delete,
            b"4" | b"8" => Key::End,
            _ => Key::Ignore,
        },
        _ => Key::Ignore,
    }
}

fn utf8_len(b: u8) -> usize {
    match b {
        0xc2..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf4 => 4,
        _ => 0,
    }
}

fn utf8_step(mut buf: Vec<u8>, b: u8) -> (ParseState, Option<Key>) {
    buf.push(b);
    let need = utf8_len(buf[0]);
    if need == 0 || buf.len() > need {
        return (ParseState::Ground, Some(Key::Ignore));
    }
    if buf.len() < need {
        return (ParseState::Utf8(buf), None);
    }
    let key = std::str::from_utf8(&buf)
        .ok()
        .and_then(|s| s.chars().next())
        .map(Key::Char)
        .unwrap_or(Key::Ignore);
    (ParseState::Ground, Some(key))
}

// ── 行缓冲 ───────────────────────────────────────────────────────

/// 以字符为单位维护的编辑缓冲（显示宽度经 [`char_width`] 计算，CJK 感知）。
#[derive(Default)]
pub struct LineBuffer {
    chars: Vec<char>,
    cursor: usize,
}

impl LineBuffer {
    pub fn clear(&mut self) {
        self.chars.clear();
        self.cursor = 0;
    }

    /// 用整行文本替换缓冲，光标置于行尾（历史导航用）。
    pub fn set(&mut self, s: &str) {
        self.chars = s.chars().collect();
        self.cursor = self.chars.len();
    }

    pub fn as_string(&self) -> String {
        self.chars.iter().collect()
    }

    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn len(&self) -> usize {
        self.chars.len()
    }

    pub fn insert(&mut self, c: char) {
        self.chars.insert(self.cursor, c);
        self.cursor += 1;
    }

    pub fn backspace(&mut self) -> bool {
        if self.cursor == 0 {
            return false;
        }
        self.cursor -= 1;
        self.chars.remove(self.cursor);
        true
    }

    pub fn delete(&mut self) -> bool {
        if self.cursor >= self.chars.len() {
            return false;
        }
        self.chars.remove(self.cursor);
        true
    }

    pub fn left(&mut self) -> bool {
        if self.cursor == 0 {
            false
        } else {
            self.cursor -= 1;
            true
        }
    }

    pub fn right(&mut self) -> bool {
        if self.cursor >= self.chars.len() {
            false
        } else {
            self.cursor += 1;
            true
        }
    }

    pub fn home(&mut self) -> bool {
        if self.cursor == 0 {
            false
        } else {
            self.cursor = 0;
            true
        }
    }

    pub fn end(&mut self) -> bool {
        if self.cursor == self.chars.len() {
            false
        } else {
            self.cursor = self.chars.len();
            true
        }
    }

    pub fn kill_to_end(&mut self) -> bool {
        if self.cursor >= self.chars.len() {
            return false;
        }
        self.chars.truncate(self.cursor);
        true
    }

    pub fn kill_to_start(&mut self) -> bool {
        if self.cursor == 0 {
            return false;
        }
        self.chars.drain(..self.cursor);
        self.cursor = 0;
        true
    }

    pub fn delete_word(&mut self) -> bool {
        if self.cursor == 0 {
            return false;
        }
        let mut start = self.cursor;
        while start > 0 && self.chars[start - 1].is_whitespace() {
            start -= 1;
        }
        while start > 0 && !self.chars[start - 1].is_whitespace() {
            start -= 1;
        }
        if start == self.cursor {
            return false;
        }
        self.chars.drain(start..self.cursor);
        self.cursor = start;
        true
    }

    /// 整行显示宽度。
    pub fn width(&self) -> usize {
        self.chars.iter().map(|&c| char_width(c)).sum()
    }

    /// 光标之前的显示宽度。
    pub fn width_before_cursor(&self) -> usize {
        self.chars[..self.cursor]
            .iter()
            .map(|&c| char_width(c))
            .sum()
    }
}

// ── 会话历史 ─────────────────────────────────────────────────────

/// 会话内命令历史（跨会话不持久化）。
#[derive(Default)]
pub struct History {
    items: Vec<String>,
    /// 当前定位：`len()` 表示"未在翻历史"。
    idx: usize,
    /// 进入历史前的当前行，供下翻回到底部时还原。
    stash: String,
}

impl History {
    pub fn add(&mut self, line: &str) {
        if line.trim().is_empty() {
            return;
        }
        if self.items.last().map(String::as_str) != Some(line) {
            self.items.push(line.to_string());
        }
        self.reset();
    }

    fn reset(&mut self) {
        self.idx = self.items.len();
        self.stash.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// 上翻一条；返回要替换的整行文本。已在最旧处返回 `None`。
    pub fn prev(&mut self, current: &str) -> Option<String> {
        if self.is_empty() || self.idx == 0 {
            return None;
        }
        if self.idx == self.items.len() {
            self.stash = current.to_string();
        }
        self.idx -= 1;
        Some(self.items[self.idx].clone())
    }

    /// 下翻一条；回到当前行时还原 `stash`。已在最新处返回 `None`。
    pub fn next(&mut self) -> Option<String> {
        if self.idx >= self.items.len() {
            return None;
        }
        self.idx += 1;
        if self.idx == self.items.len() {
            Some(std::mem::take(&mut self.stash))
        } else {
            Some(self.items[self.idx].clone())
        }
    }
}

// ── 编辑器 ───────────────────────────────────────────────────────

/// `read_line` 的结果。
pub enum Outcome {
    Line(String),
    /// Ctrl-C：放弃当前输入，继续 REPL。
    Cancel,
    /// Ctrl-D（空行）或输入流结束。
    Eof,
}

/// 单行编辑器：维护输入缓冲与历史，负责重绘。
pub struct Editor {
    prompt: String,
    prompt_w: usize,
    cols: usize,
    buf: LineBuffer,
    history: History,
    /// 横向滚动：左侧已隐藏的显示列数（保证长行不换行、始终单行）。
    scroll: usize,
}

impl Editor {
    /// `prompt` 可含 ANSI 样式；`cols` 为终端列数。
    pub fn new(prompt: String, cols: usize) -> Self {
        let prompt_w = display_width(&prompt);
        Editor {
            prompt,
            prompt_w,
            cols: cols.max(1),
            buf: LineBuffer::default(),
            history: History::default(),
            scroll: 0,
        }
    }

    /// 编辑器固定单行：为光标预留最右侧一列，避免触发终端自动换行。
    fn avail(&self) -> usize {
        self.cols.saturating_sub(self.prompt_w + 1).max(1)
    }

    pub fn remember(&mut self, line: &str) {
        self.history.add(line);
    }

    /// 读取一行（`raw` 须已进入原始模式）。
    pub fn read_line(&mut self, raw: &mut RawInput) -> Outcome {
        let mut next = || raw.read_byte();
        let mut write = |s: &str| {
            let mut out = std::io::stdout();
            let _ = out.write_all(s.as_bytes());
            let _ = out.flush();
        };
        self.read_with(&mut next, &mut write)
    }

    /// 事件循环。读字节与写输出以闭包注入，便于用脚本化输入做确定性单测。
    fn read_with(
        &mut self,
        next: &mut dyn FnMut() -> Option<u8>,
        write: &mut dyn FnMut(&str),
    ) -> Outcome {
        self.buf.clear();
        self.history.reset();
        self.scroll = 0;
        let first = self.paint();
        write(&first);

        let mut parser = KeyParser::new();
        loop {
            let Some(byte) = next() else {
                write("\r\n");
                return Outcome::Eof;
            };
            let Some(key) = parser.feed(byte) else {
                continue;
            };
            let changed = match key {
                Key::Enter => {
                    self.move_to_end(write);
                    write("\r\n");
                    return Outcome::Line(self.buf.as_string());
                }
                Key::Cancel => {
                    self.move_to_end(write);
                    write("^C\r\n");
                    return Outcome::Cancel;
                }
                Key::CtrlD => {
                    if self.buf.is_empty() {
                        write("\r\n");
                        return Outcome::Eof;
                    }
                    self.buf.delete()
                }
                Key::Char(c) => {
                    self.buf.insert(c);
                    true
                }
                Key::Backspace => self.buf.backspace(),
                Key::Delete => self.buf.delete(),
                Key::Left => self.buf.left(),
                Key::Right => self.buf.right(),
                Key::Home => self.buf.home(),
                Key::End => self.buf.end(),
                Key::KillToEnd => self.buf.kill_to_end(),
                Key::KillToStart => self.buf.kill_to_start(),
                Key::DeleteWord => self.buf.delete_word(),
                Key::Up => {
                    if let Some(line) = self.history.prev(&self.buf.as_string()) {
                        self.buf.set(&line);
                        self.scroll = 0;
                        true
                    } else {
                        false
                    }
                }
                Key::Down => {
                    if let Some(line) = self.history.next() {
                        self.buf.set(&line);
                        self.scroll = 0;
                        true
                    } else {
                        false
                    }
                }
                Key::ClearScreen => {
                    write("\x1b[2J\x1b[H");
                    true
                }
                Key::Ignore => false,
            };
            if changed {
                let s = self.paint();
                write(&s);
            }
        }
    }

    fn move_to_end(&mut self, write: &mut dyn FnMut(&str)) {
        if self.buf.cursor() != self.buf.len() {
            self.buf.end();
            let s = self.paint();
            write(&s);
        }
    }

    /// 调整横向滚动，使光标可见（单行渲染，绝不触发换行）。
    fn adjust_scroll(&mut self) -> usize {
        let avail = self.avail();
        let total = self.buf.width();
        let cw = self.buf.width_before_cursor();
        if total <= avail {
            self.scroll = 0;
        } else {
            if cw < self.scroll {
                self.scroll = cw;
            } else if cw >= self.scroll + avail {
                self.scroll = cw + 1 - avail;
            }
            if self.scroll > total {
                self.scroll = total;
            }
        }
        avail
    }

    /// 返回恰好放得下的可见文本，以及其显示宽度。
    fn visible(&self, avail: usize) -> (String, usize) {
        let mut col = 0usize;
        let mut out = String::new();
        let mut out_w = 0usize;
        for &c in &self.buf.chars {
            let w = char_width(c);
            let start = col;
            col += w;
            if start + w <= self.scroll {
                continue;
            }
            if start < self.scroll {
                // 宽字符跨越左边界：隐藏部分以空格占位，避免错位。
                let shown = start + w - self.scroll;
                out.extend(std::iter::repeat(' ').take(shown));
                out_w += shown;
                continue;
            }
            if out_w + w > avail {
                break;
            }
            out.push(c);
            out_w += w;
        }
        (out, out_w)
    }

    fn paint(&mut self) -> String {
        let avail = self.adjust_scroll();
        let (visible, vis_w) = self.visible(avail);
        let cw = self.buf.width_before_cursor();
        let end_col = self.prompt_w + vis_w;
        let cur_col = self.prompt_w + cw.saturating_sub(self.scroll).min(vis_w);
        let back = end_col.saturating_sub(cur_col);

        let mut s = String::with_capacity(self.prompt.len() + visible.len() + 24);
        s.push('\r');
        s.push_str(&self.prompt);
        s.push_str(&visible);
        s.push_str("\x1b[K");
        if back > 0 {
            s.push_str(&format!("\x1b[{back}D"));
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_all(parser: &mut KeyParser, bytes: &[u8]) -> Vec<Key> {
        bytes.iter().filter_map(|&b| parser.feed(b)).collect()
    }

    #[test]
    fn arrow_keys_from_csi() {
        let mut p = KeyParser::new();
        assert_eq!(feed_all(&mut p, b"\x1b[A"), vec![Key::Up]);
        assert_eq!(feed_all(&mut p, b"\x1b[B"), vec![Key::Down]);
        assert_eq!(feed_all(&mut p, b"\x1b[C"), vec![Key::Right]);
        assert_eq!(feed_all(&mut p, b"\x1b[D"), vec![Key::Left]);
    }

    #[test]
    fn application_cursor_keys_from_ss3() {
        let mut p = KeyParser::new();
        assert_eq!(feed_all(&mut p, b"\x1bOA"), vec![Key::Up]);
        assert_eq!(feed_all(&mut p, b"\x1bOD"), vec![Key::Left]);
    }

    #[test]
    fn tilde_sequences() {
        let mut p = KeyParser::new();
        assert_eq!(feed_all(&mut p, b"\x1b[H"), vec![Key::Home]);
        assert_eq!(feed_all(&mut p, b"\x1b[F"), vec![Key::End]);
        assert_eq!(feed_all(&mut p, b"\x1b[3~"), vec![Key::Delete]);
        assert_eq!(feed_all(&mut p, b"\x1b[1~"), vec![Key::Home]);
        assert_eq!(feed_all(&mut p, b"\x1b[4~"), vec![Key::End]);
        assert_eq!(feed_all(&mut p, b"\x1b[5~"), vec![Key::Ignore]);
    }

    #[test]
    fn control_and_printable_keys() {
        let mut p = KeyParser::new();
        assert_eq!(feed_all(&mut p, &[0x01]), vec![Key::Home]);
        assert_eq!(feed_all(&mut p, &[0x05]), vec![Key::End]);
        assert_eq!(feed_all(&mut p, &[0x15]), vec![Key::KillToStart]);
        assert_eq!(feed_all(&mut p, &[0x0b]), vec![Key::KillToEnd]);
        assert_eq!(feed_all(&mut p, &[0x17]), vec![Key::DeleteWord]);
        assert_eq!(feed_all(&mut p, &[0x03]), vec![Key::Cancel]);
        assert_eq!(feed_all(&mut p, &[0x04]), vec![Key::CtrlD]);
        assert_eq!(feed_all(&mut p, &[0x0d]), vec![Key::Enter]);
        assert_eq!(feed_all(&mut p, &[0x7f]), vec![Key::Backspace]);
        assert_eq!(feed_all(&mut p, b"a"), vec![Key::Char('a')]);
    }

    #[test]
    fn multibyte_char_assembles() {
        let mut p = KeyParser::new();
        let bytes = "我".as_bytes();
        assert_eq!(p.feed(bytes[0]), None);
        assert_eq!(p.feed(bytes[1]), None);
        assert_eq!(p.feed(bytes[2]), Some(Key::Char('我')));
    }

    #[test]
    fn line_buffer_edits() {
        let mut b = LineBuffer::default();
        for c in "abc".chars() {
            b.insert(c);
        }
        assert_eq!(b.as_string(), "abc");
        assert!(b.backspace());
        assert_eq!(b.as_string(), "ab");
        assert!(b.home());
        assert!(b.delete());
        assert_eq!(b.as_string(), "b");
        assert!(b.end());
        assert!(b.kill_to_start());
        assert_eq!(b.as_string(), "");
        assert!(!b.kill_to_start());

        b.set("foo bar baz");
        assert!(b.delete_word());
        assert_eq!(b.as_string(), "foo bar ");
        assert!(b.delete_word());
        assert_eq!(b.as_string(), "foo ");
    }

    #[test]
    fn line_buffer_cjk_width() {
        let mut b = LineBuffer::default();
        b.set("阿Yue");
        assert_eq!(b.width(), 2 + 3);
        assert!(b.home());
        assert!(b.right());
        assert_eq!(b.width_before_cursor(), 2);
    }

    #[test]
    fn history_prev_next_with_stash() {
        let mut h = History::default();
        h.add("one");
        h.add("two");
        h.add("one"); // 非连续重复，保留
        h.add("one"); // 连续重复，忽略

        assert_eq!(h.prev("draft").as_deref(), Some("one"));
        assert_eq!(h.prev("").as_deref(), Some("two"));
        assert_eq!(h.prev("").as_deref(), Some("one"));
        assert_eq!(h.prev(""), None);
        assert_eq!(h.next().as_deref(), Some("two"));
        assert_eq!(h.next().as_deref(), Some("one"));
        assert_eq!(h.next().as_deref(), Some("draft"));
        assert_eq!(h.next(), None);
    }

    #[test]
    fn history_ignores_blank() {
        let mut h = History::default();
        h.add("   ");
        h.add("");
        assert!(h.is_empty());
    }

    #[test]
    fn read_with_scripted_input_end_to_end() {
        let mut e = Editor::new("p> ".to_string(), 40);
        // 脚本：abc↵ | ↑（召回）←X↵ | Ctrl-C | Ctrl-D
        let mut input: Vec<u8> = Vec::new();
        input.extend_from_slice(b"abc\r");
        input.extend_from_slice(b"\x1b[A\x1b[DX\r");
        input.push(0x03);
        input.push(0x04);
        let mut idx = 0usize;
        let mut next = move || {
            let b = input.get(idx).copied();
            idx += 1;
            b
        };
        let mut sink = String::new();
        let mut write = |s: &str| sink.push_str(s);

        assert!(matches!(e.read_with(&mut next, &mut write), Outcome::Line(l) if l == "abc"));
        e.remember("abc");
        assert!(matches!(e.read_with(&mut next, &mut write), Outcome::Line(l) if l == "abXc"));
        assert!(matches!(e.read_with(&mut next, &mut write), Outcome::Cancel));
        assert!(matches!(e.read_with(&mut next, &mut write), Outcome::Eof));
    }

    #[test]
    fn scroll_keeps_cursor_visible_and_single_row() {
        // prompt "abc> " 宽 5，列宽 20 → avail = 20 - (5+1) = 14。
        let mut e = Editor::new("abc> ".to_string(), 20);
        e.buf.set("abcdefghijklmnopqrstuvwxyz"); // 26 列 > 14
        let avail = e.adjust_scroll();
        assert_eq!(avail, 14);
        // 光标在行尾：窗口滚到尾部，且末列留给光标。
        assert!(e.scroll + avail >= e.buf.width());
        let (visible, w) = e.visible(avail);
        assert!(w <= avail);
        assert_eq!(visible, "nopqrstuvwxyz");
        assert_eq!(w, 13);

        // 光标移到开头：窗口回到最左，可见前 avail 列。
        e.buf.home();
        e.adjust_scroll();
        assert_eq!(e.scroll, 0);
        let (visible, w) = e.visible(e.avail());
        assert_eq!(visible, "abcdefghijklmn");
        assert_eq!(w, 14);
    }

    #[test]
    fn scroll_handles_wide_chars() {
        // prompt 宽 0（cols=6 → avail=5），中文字符宽 2。
        let mut e = Editor::new(String::new(), 6);
        e.buf.set("我恨明月不照我"); // 14 列
        e.adjust_scroll();
        let (visible, w) = e.visible(e.avail());
        assert!(w <= e.avail());
        // 末尾窗口切在整字符边界上，不产生错位。
        assert_eq!(visible, "照我");
        assert_eq!(w, 4);
    }
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 终端显示宽度（CJK 感知）与对齐辅助。
//!
//! 与 Dart 端 `mcp_shell_render.dart` 同口径：East Asian 宽字符按 2 列、
//! 组合符/零宽字符按 0 列；ANSI SGR 序列不计宽。用于面板/表格对齐与窄终端截断。

/// 单个码点的显示列宽。
pub fn char_width(c: char) -> usize {
    let u = c as u32;
    if u == 0 {
        return 0;
    }
    // 控制字符：不计宽（我们输出的换行/制表另处理）。
    if u < 0x20 || (0x7f..0xa0).contains(&u) {
        return 0;
    }
    // 组合符号 / 变体选择符 / 零宽连接符。
    if (0x0300..=0x036f).contains(&u)
        || (0x1ab0..=0x1aff).contains(&u)
        || (0x1dc0..=0x1dff).contains(&u)
        || (0x20d0..=0x20ff).contains(&u)
        || (0xfe00..=0xfe0f).contains(&u)
        || (0xfe20..=0xfe2f).contains(&u)
        || u == 0x200b
        || u == 0x200c
        || u == 0x200d
        || u == 0x2060
        || u == 0xfeff
    {
        return 0;
    }
    // East Asian Wide / Fullwidth。
    if (0x1100..=0x115f).contains(&u)
        || (0x2e80..=0x303e).contains(&u)
        || (0x3041..=0x33ff).contains(&u)
        || (0x3400..=0x4dbf).contains(&u)
        || (0x4e00..=0x9fff).contains(&u)
        || (0xa000..=0xa4cf).contains(&u)
        || (0xac00..=0xd7a3).contains(&u)
        || (0xf900..=0xfaff).contains(&u)
        || (0xfe10..=0xfe19).contains(&u)
        || (0xfe30..=0xfe6f).contains(&u)
        || (0xff00..=0xff60).contains(&u)
        || (0xffe0..=0xffe6).contains(&u)
        || (0x1f300..=0x1faff).contains(&u)
        || (0x20000..=0x3fffd).contains(&u)
    {
        return 2;
    }
    1
}

/// 是否为一个 ANSI CSI 序列（`ESC [ ... 终止符`）；返回序列字节长度。
fn ansi_len(bytes: &[u8], i: usize) -> Option<usize> {
    if bytes.get(i) != Some(&0x1b) || bytes.get(i + 1) != Some(&b'[') {
        return None;
    }
    let mut j = i + 2;
    while j < bytes.len() {
        let b = bytes[j];
        if (0x40..=0x7e).contains(&b) {
            return Some(j - i + 1);
        }
        j += 1;
    }
    None
}

/// 去掉所有 ANSI CSI 序列。
pub fn strip_ansi(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if let Some(len) = ansi_len(bytes, i) {
            i += len;
            continue;
        }
        // 非 ANSI：按 UTF-8 边界推进。
        let rest = &s[i..];
        let c = rest.chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

/// 字符串显示列数。
pub fn display_width(s: &str) -> usize {
    // 快路径：无 ESC 时直接按 char 计算。
    if !s.contains('\x1b') {
        return s.chars().map(char_width).sum();
    }
    strip_ansi(s).chars().map(char_width).sum()
}

/// 截断到 `width` 显示列（保留 ANSI），超出以 `…` 收尾；切断 ANSI 时补复位。
pub fn truncate(s: &str, width: usize) -> String {
    if display_width(s) <= width {
        return s.to_string();
    }
    if width <= 1 {
        return "…".to_string();
    }
    let mut out = String::new();
    let mut w = 0usize;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if let Some(len) = ansi_len(bytes, i) {
            out.push_str(&s[i..i + len]);
            i += len;
            continue;
        }
        let c = s[i..].chars().next().unwrap();
        let cw = char_width(c);
        if w + cw > width - 1 {
            break;
        }
        out.push(c);
        w += cw;
        i += c.len_utf8();
    }
    out.push('…');
    if s.contains('\x1b') {
        out.push_str("\x1b[0m");
    }
    out
}

/// 右侧补空格到 `width` 显示列。
pub fn pad_right(s: &str, width: usize) -> String {
    let w = display_width(s);
    if w >= width {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + (width - w));
    out.push_str(s);
    out.extend(std::iter::repeat(' ').take(width - w));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cjk_is_two_columns() {
        assert_eq!(display_width("abc"), 3);
        assert_eq!(display_width("我恨明月"), 8);
        assert_eq!(display_width("阿YueYue"), 2 + 6);
    }

    #[test]
    fn ansi_is_zero_width() {
        assert_eq!(display_width("\x1b[2mabc\x1b[0m"), 3);
    }

    #[test]
    fn truncate_respects_cjk_and_closes_ansi() {
        let s = "\x1b[2m我恨明月不照我\x1b[0m";
        let t = truncate(s, 6);
        assert!(display_width(&t) <= 6);
        assert!(t.contains('…'));
        assert!(t.ends_with("\x1b[0m"));
    }

    #[test]
    fn pad_right_by_display_width() {
        assert_eq!(display_width(&pad_right("我", 5)), 5);
    }
}

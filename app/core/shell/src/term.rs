// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 终端能力探测：是否交互式、列数、是否启用 ANSI。

use std::io::IsTerminal;

/// `stdout` 是否连接到交互式终端（用于自动切换 TUI / 纯文本）。
pub fn stdout_is_tty() -> bool {
    std::io::stdout().is_terminal()
}

/// `stdin` 是否交互式（决定裸 `archoerashell` 进 REPL 还是逐行批处理）。
pub fn stdin_is_tty() -> bool {
    std::io::stdin().is_terminal()
}

/// 是否应启用 ANSI 样式：非交互、`NO_COLOR`、`TERM=dumb` 任一命中即关闭。
pub fn use_style() -> bool {
    if !stdout_is_tty() {
        return false;
    }
    if std::env::var_os("NO_COLOR").is_some() {
        return false;
    }
    if let Ok(term) = std::env::var("TERM") {
        if term == "dumb" || term.is_empty() {
            return false;
        }
    }
    true
}

/// 终端列数：优先 `COLUMNS`，其次 `TIOCGWINSZ`，兜底 80。
pub fn columns() -> usize {
    if let Ok(v) = std::env::var("COLUMNS") {
        if let Ok(n) = v.trim().parse::<usize>() {
            if n > 0 {
                return n;
            }
        }
    }
    #[cfg(unix)]
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_col > 0 {
            return ws.ws_col as usize;
        }
    }
    80
}

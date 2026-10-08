// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 终端能力探测：是否交互式、列数、是否启用 ANSI；以及 Unix 侧原始输入模式。

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
    #[cfg(windows)]
    if let Some(cols) = crate::console::columns() {
        return cols;
    }
    80
}

/// Unix 原始（未见行）输入：关闭规范模式与回显，逐字节阻塞读取。
///
/// Windows 侧由 [`crate::console::RawInput`] 提供同签名实现（三端在 `lineedit` 中
/// 统一使用）。Drop 时恢复原终端设置，正常退出与 panic 展开都不留下脏状态。
#[cfg(unix)]
mod raw {
    pub struct RawInput {
        saved: libc::termios,
    }

    impl RawInput {
        /// 尝试进入原始模式；`stdin` 非交互终端或设置失败返回 `None`（调用方回退）。
        pub fn enable() -> Option<Self> {
            if !super::stdin_is_tty() {
                return None;
            }
            unsafe {
                let mut t: libc::termios = std::mem::zeroed();
                if libc::tcgetattr(libc::STDIN_FILENO, &mut t) != 0 {
                    return None;
                }
                let saved = t;
                // 关闭规范/回显/扩展/信号：Ctrl-C 等以字节形式交付，由行编辑器自行处理。
                t.c_lflag &= !(libc::ICANON | libc::ECHO | libc::IEXTEN | libc::ISIG);
                t.c_iflag &=
                    !(libc::IXON | libc::ICRNL | libc::BRKINT | libc::INPCK | libc::ISTRIP);
                t.c_cc[libc::VMIN] = 1;
                t.c_cc[libc::VTIME] = 0;
                if libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &t) != 0 {
                    return None;
                }
                Some(RawInput { saved })
            }
        }

        /// 阻塞读取一个字节；EOF/错误返回 `None`。
        pub fn read_byte(&mut self) -> Option<u8> {
            let mut b = 0u8;
            let n = unsafe {
                libc::read(
                    libc::STDIN_FILENO,
                    &mut b as *mut u8 as *mut libc::c_void,
                    1,
                )
            };
            if n == 1 {
                Some(b)
            } else {
                None
            }
        }
    }

    impl Drop for RawInput {
        fn drop(&mut self) {
            unsafe {
                libc::tcsetattr(libc::STDIN_FILENO, libc::TCSADRAIN, &self.saved);
            }
        }
    }
}

#[cfg(unix)]
pub use raw::RawInput;

#[cfg(windows)]
pub use crate::console::RawInput;

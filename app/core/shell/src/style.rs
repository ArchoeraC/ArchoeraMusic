// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ANSI SGR 样式封装。渲染器持有一个 [`Style`] 开关：非交互终端关闭时所有
//! 方法原样返回，从而复用同一套排版代码产出纯文本。

const RESET: &str = "\x1b[0m";

#[derive(Clone, Copy)]
pub struct Style {
    pub enabled: bool,
}

impl Style {
    pub fn new(enabled: bool) -> Self {
        Style { enabled }
    }

    fn sgr(&self, code: &str, s: &str) -> String {
        if !self.enabled || s.is_empty() {
            return s.to_string();
        }
        format!("\x1b[{code}m{s}{RESET}")
    }

    pub fn bold(&self, s: &str) -> String {
        self.sgr("1", s)
    }
    pub fn dim(&self, s: &str) -> String {
        self.sgr("2", s)
    }
    pub fn italic(&self, s: &str) -> String {
        self.sgr("3", s)
    }
    pub fn red(&self, s: &str) -> String {
        self.sgr("31", s)
    }
    pub fn green(&self, s: &str) -> String {
        self.sgr("32", s)
    }
    pub fn yellow(&self, s: &str) -> String {
        self.sgr("33", s)
    }
    pub fn cyan(&self, s: &str) -> String {
        self.sgr("36", s)
    }

    /// 事件强调色：播放/成功取绿色，暂停/缓冲取黄色。
    pub fn accent(&self, good: bool, s: &str) -> String {
        if good {
            self.green(s)
        } else {
            self.yellow(s)
        }
    }
}

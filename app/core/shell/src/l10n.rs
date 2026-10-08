// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 命令行本地化：复用 build.rs 从 Flutter ARB 生成的 `mcpShell*` 文案。

use std::sync::OnceLock;

include!(concat!(env!("OUT_DIR"), "/help_strings.rs"));

/// 系统语言（`LC_ALL` / `LC_MESSAGES` / `LANG` → 归一化 `zh_CN` 形式）。
fn system_locale() -> String {
    for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        if let Ok(v) = std::env::var(key) {
            if v.is_empty() {
                continue;
            }
            let base = v.split('.').next().unwrap_or(&v);
            let base = base.split('@').next().unwrap_or(base);
            if base.is_empty() || base == "C" || base == "POSIX" {
                continue;
            }
            return base.replace('-', "_");
        }
    }
    "en".to_string()
}

fn lookup_raw(locale: &str, key: &str) -> Option<&'static str> {
    let want = locale.replace('-', "_");
    // 精确 → 语言前缀 → zh → en。
    let lang = want.split('_').next().unwrap_or(&want);
    let matches = |code: &str| STRINGS.iter().find(|(c, k, _)| *c == code && *k == key);
    if let Some((_, _, v)) = STRINGS.iter().find(|(c, k, _)| *c == want && *k == key) {
        return Some(v);
    }
    if let Some((_, _, v)) = STRINGS.iter().find(|(c, k, _)| *c == lang && *k == key) {
        return Some(v);
    }
    if let Some((_, _, v)) = matches("zh") {
        return Some(v);
    }
    matches("en").map(|(_, _, v)| *v)
}

#[derive(Clone)]
pub struct L10n {
    locale: String,
}

impl L10n {
    pub fn new(pref_locale: Option<String>) -> Self {
        static SYS: OnceLock<String> = OnceLock::new();
        let locale = pref_locale
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| SYS.get_or_init(system_locale).clone());
        L10n { locale }
    }

    pub fn raw(&self, key: &str) -> String {
        lookup_raw(&self.locale, key)
            .map(str::to_string)
            .unwrap_or_else(|| key.to_string())
    }

    /// 取文案并替换 `{name}` 占位符。
    pub fn fmt(&self, key: &str, args: &[(&str, String)]) -> String {
        let mut s = self.raw(key);
        for (name, value) in args {
            s = s.replace(&format!("{{{name}}}"), value);
        }
        s
    }
}

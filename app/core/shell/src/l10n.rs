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

fn find(locale: &str, key: &str) -> Option<&'static str> {
    STRINGS
        .iter()
        .find(|(c, k, _)| *c == locale && *k == key)
        .map(|(_, _, v)| *v)
}

/// 解析顺序与 Flutter 生成代码一致：精确 `zh_CN`/`zh_TW` → 语言前缀（`zh`、`de`
/// 等）→ **回退英文**（Dart 侧 `lookupAppLocalizations` 对不支持语言抛错后回退
/// `en`，故这里也必须是 en，不能回退中文）。
fn lookup_raw(locale: &str, key: &str) -> Option<&'static str> {
    let want = locale.replace('-', "_");
    if let Some(v) = find(&want, key) {
        return Some(v);
    }
    let lang = want.split('_').next().unwrap_or(&want);
    if lang != want {
        if let Some(v) = find(lang, key) {
            return Some(v);
        }
    }
    find("en", key)
}

#[derive(Clone)]
pub struct L10n {
    locale: String,
}

impl L10n {
    /// 固定英文（测试用），与 Dart 端 en 文案一致。
    #[cfg(test)]
    pub fn english() -> Self {
        L10n {
            locale: "en".to_string(),
        }
    }

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_region_then_language_prefix() {
        assert!(lookup_raw("zh_TW", "mcpShellHelpSearch").unwrap().contains("關鍵字"));
        assert!(lookup_raw("zh_CN", "mcpShellHelpSearch").unwrap().contains("关键词"));
        // 未特化的地区回退到语言：zh_HK → app_zh（简体 base），与 Flutter 生成代码一致。
        assert!(lookup_raw("zh_HK", "mcpShellHelpSearch").unwrap().contains("关键词"));
        assert!(lookup_raw("de_AT", "mcpShellHelpSearch").unwrap().contains("archoerashell search"));
    }

    #[test]
    fn unsupported_language_falls_back_to_english() {
        // 与 Dart `_shellL10n` 一致：不支持语言回退 en，而非中文。
        assert!(lookup_raw("ru", "mcpShellHelpSearch").unwrap().starts_with("Usage:"));
        assert!(lookup_raw("xx_YY", "mcpShellHelpSearch").unwrap().starts_with("Usage:"));
    }
}

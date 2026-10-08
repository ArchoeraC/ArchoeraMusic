// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 应用偏好读取（与 Dart `resolveDataDir` / `AppPrefs` 同口径）。
//!
//! CLI 需要从 `prefs.json` 取 MCP 端口与访问密钥，并读取语言偏好用于本地化。

use serde_json::Value;
use std::path::PathBuf;

pub const DEFAULT_MCP_PORT: u16 = 14559;

/// 应用数据根目录：
///   - `ARCHOERA_DATA_DIR` 覆盖；
///   - Linux：`~/.local/share/ArchoeraMusic`
///   - macOS：`~/Library/Application Support/ArchoeraMusic`
///   - Windows：`%LOCALAPPDATA%\ArchoeraMusic`
pub fn data_dir() -> PathBuf {
    if let Some(v) = std::env::var_os("ARCHOERA_DATA_DIR") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        return home.join("Library/Application Support/ArchoeraMusic");
    }
    if cfg!(windows) {
        let local = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("AppData/Local"));
        return local.join("ArchoeraMusic");
    }
    home.join(".local/share/ArchoeraMusic")
}

fn load() -> Value {
    let path = data_dir().join("prefs.json");
    match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or(Value::Null),
        Err(_) => Value::Null,
    }
}

/// 是否启用命令行 shell（缺省 true）。
pub fn shell_enabled(prefs: &Value) -> bool {
    prefs
        .get("mcp.shellEnabled")
        .and_then(Value::as_bool)
        .unwrap_or(true)
}

/// MCP 端口（收敛到非特权区间，缺省 [`DEFAULT_MCP_PORT`]）。
pub fn mcp_port(prefs: &Value) -> u16 {
    let raw = prefs
        .get("mcp.port")
        .and_then(Value::as_i64)
        .unwrap_or(DEFAULT_MCP_PORT as i64);
    raw.clamp(1024, 65535) as u16
}

/// MCP 访问密钥（缺省空串）。
pub fn mcp_key(prefs: &Value) -> String {
    prefs
        .get("mcp.accessKey")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string()
}

/// 应用语言偏好（`appearance.locale`，如 `zh` / `en`；缺省 None）。
pub fn locale(prefs: &Value) -> Option<String> {
    prefs
        .get("appearance.locale")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub struct Prefs {
    pub shell_enabled: bool,
    pub port: u16,
    pub key: String,
    pub locale: Option<String>,
}

pub fn load_prefs() -> Prefs {
    let v = load();
    Prefs {
        shell_enabled: shell_enabled(&v),
        port: mcp_port(&v),
        key: mcp_key(&v),
        locale: locale(&v),
    }
}

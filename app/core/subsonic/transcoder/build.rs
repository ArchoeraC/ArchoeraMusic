// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows VERSIONINFO 注入（仅 Windows 宿主 + Windows 目标）。
//! `archoera_transcoder.dll` 由 Subsonic 服务按需加载；补全元数据与版本号，
//! 版本来源与主程序一致（`app/pubspec.yaml`）。非 Windows 构建直接跳过。

use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let host = env::var("HOST").unwrap_or_default();
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") || !host.contains("windows") {
        return;
    }

    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let (version, packed) = app_version(Path::new(&manifest_dir));

    let mut res = winres::WindowsResource::new();
    res.set("CompanyName", "io.awa.archoera.betastudio2")
        .set("FileDescription", "ArchoeraMusic Subsonic transcoder")
        .set("InternalName", "archoera_transcoder")
        .set("LegalCopyright", "Copyright (C) 2026 io.awa.archoera.betastudio2")
        .set("OriginalFilename", "archoera_transcoder.dll")
        .set("ProductName", "ArchoeraMusic")
        .set("Comments", "https://github.com/ArchoeraC/ArchoeraMusic")
        .set("FileVersion", &version)
        .set("ProductVersion", &version)
        .set_version_info(winres::VersionInfo::FILEVERSION, packed)
        .set_version_info(winres::VersionInfo::PRODUCTVERSION, packed)
        .set_version_info(winres::VersionInfo::FILETYPE, 2) // VFT_DLL
        .set_language(0x0409);

    let icon = Path::new(&manifest_dir).join("../../../windows/runner/resources/app_icon.ico");
    if icon.exists() {
        res.set_icon(&icon.to_string_lossy());
    }

    res.compile().expect("compile archoera_transcoder Windows resources");
    println!("cargo:rerun-if-changed=../../../pubspec.yaml");
}

fn app_version(manifest_dir: &Path) -> (String, u64) {
    let raw = fs::read_to_string(manifest_dir.join("../../../pubspec.yaml"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.trim().strip_prefix("version:"))
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "0.0.0".to_string());

    let mut numeric = raw.split('+');
    let base = numeric.next().unwrap_or("0.0.0");
    let build = numeric
        .next()
        .and_then(|b| b.parse::<u64>().ok())
        .unwrap_or(0)
        .min(0xffff);

    let mut parts = base.split('.').map(|p| p.parse::<u64>().unwrap_or(0));
    let major = parts.next().unwrap_or(0).min(0xffff);
    let minor = parts.next().unwrap_or(0).min(0xffff);
    let patch = parts.next().unwrap_or(0).min(0xffff);
    let packed = (major << 48) | (minor << 32) | (patch << 16) | build;

    (raw, packed)
}

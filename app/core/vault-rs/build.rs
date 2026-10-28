// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows VERSIONINFO 注入（仅 Windows 目标；其它平台直接跳过）。
//!
//! `archoera-vault.exe` 以前是完全没有版本资源的裸 exe：未签名 + 无元数据 +
//! DPAPI/进程查询导入，极易被 AV 的启发式打高分。这里从 `app/pubspec.yaml`
//! 读取应用版本，写入 FileVersion/ProductVersion 与公司/产品字段，并复用主程序
//! 图标；不改变任何运行期行为。

use std::env;
use std::fs;
use std::path::Path;

fn main() {
    // 只在「Windows 宿主 + Windows 目标」时调用 rc.exe：Linux/macOS 交叉编译
    // （vault-rs/test-windows.sh 的 msvc-wine、cross-macos.sh）没有可用的
    // Windows SDK 资源编译器；跳过版本资源不影响测试与链接。
    let host = env::var("HOST").unwrap_or_default();
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") || !host.contains("windows") {
        return;
    }

    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let (version, packed) = app_version(Path::new(&manifest_dir));

    let mut res = winres::WindowsResource::new();
    res.set("CompanyName", "io.awa.archoera.betastudio2")
        .set("FileDescription", "ArchoeraMusic credential vault")
        .set("InternalName", "archoera-vault")
        .set("LegalCopyright", "Copyright (C) 2026 io.awa.archoera.betastudio2")
        .set("OriginalFilename", "archoera-vault.exe")
        .set("ProductName", "ArchoeraMusic")
        .set("Comments", "https://github.com/ArchoeraC/ArchoeraMusic")
        .set("FileVersion", &version)
        .set("ProductVersion", &version)
        .set_version_info(winres::VersionInfo::FILEVERSION, packed)
        .set_version_info(winres::VersionInfo::PRODUCTVERSION, packed)
        .set_language(0x0409); // en-US

    let icon = Path::new(&manifest_dir).join("../../windows/runner/resources/app_icon.ico");
    if icon.exists() {
        res.set_icon(&icon.to_string_lossy());
    }

    res.compile().expect("compile archoera-vault Windows resources");
    println!("cargo:rerun-if-changed=../../pubspec.yaml");
}

/// 返回（原始版本串，四段式打包值）。`1.0.2+0` → (`1.0.2+0`, 0x0001_0000_0002_0000)。
fn app_version(manifest_dir: &Path) -> (String, u64) {
    let raw = fs::read_to_string(manifest_dir.join("../../pubspec.yaml"))
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

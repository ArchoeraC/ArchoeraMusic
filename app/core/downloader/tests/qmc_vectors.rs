// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! QMC 解密对拍：使用 `lantianhcgp/unlock-music`（MIT）测试向量
//! （`tests/data/qmc/*.bin`）验证 Rust 移植的 `derive_key` 与 `qmc_decrypt`。

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use archoera_downloader::qmc::{derive_key, qmc_decrypt};

fn data(name: &str) -> Vec<u8> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/data/qmc")
        .join(name);
    fs::read(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
}

fn full(name: &str) -> Vec<u8> {
    let mut v = data(&format!("{name}_raw.bin"));
    v.extend_from_slice(&data(&format!("{name}_suffix.bin")));
    v
}

#[test]
fn derive_key_matches_vectors() {
    for (raw, key) in [
        ("mflac_map_key_raw.bin", "mflac_map_key.bin"),
        ("mflac_rc4_key_raw.bin", "mflac_rc4_key.bin"),
        ("mgg_map_key_raw.bin", "mgg_map_key.bin"),
    ] {
        let got = derive_key(&data(raw)).unwrap_or_else(|e| panic!("{raw}: {e}"));
        assert_eq!(got, data(key), "{raw}");
    }
}

#[test]
fn decrypt_matches_vectors() {
    for name in ["mflac_map", "mflac_rc4", "mgg_map"] {
        let target = data(&format!("{name}_target.bin"));
        let (out, ext) =
            qmc_decrypt(&full(name), &HashMap::new()).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(out.len(), target.len(), "{name} length");
        if out != target {
            let i = out
                .iter()
                .zip(&target)
                .position(|(a, b)| a != b)
                .unwrap_or(usize::MAX);
            let lo = i.saturating_sub(2);
            panic!(
                "{name} mismatch at {i}: got {:02x?} want {:02x?}",
                &out[lo..(i + 6).min(out.len())],
                &target[lo..(i + 6).min(target.len())]
            );
        }
        assert!(!ext.is_empty());
    }
}

#[test]
fn static_vector() {
    let raw = data("qmc0_static_raw.bin");
    let target = data("qmc0_static_target.bin");
    let (out, _) = qmc_decrypt(&raw, &HashMap::new()).unwrap_or_else(|e| panic!("static: {e}"));
    assert_eq!(out, target);
}

#[test]
fn musicex_needs_external_key() {
    use archoera_downloader::qmc::parse_musicex_tag;
    let name = "Q0M0001TMfOW0Y9MkR.mflac";
    let audio: Vec<u8> = (0u32..1000).map(|i| (i * 7) as u8).collect();
    // 标签区共 0xC0 字节（含末尾 16 字节 trailer）。
    let mut region = vec![0u8; 0xC0];
    for (i, ch) in name.bytes().enumerate() {
        let off = 0x48 + i * 2;
        if off + 1 >= region.len() {
            break;
        }
        region[off] = ch;
    }
    region[0xB0..0xB4].copy_from_slice(&0xC0u32.to_le_bytes());
    region[0xB4..0xB8].copy_from_slice(&1u32.to_le_bytes());
    region[0xB8..0xC0].copy_from_slice(b"musicex\0");

    let mut file = audio.clone();
    file.extend_from_slice(&region);
    let parsed = parse_musicex_tag(&file).unwrap();
    assert_eq!(parsed.media_file_name, name);
    let err = qmc_decrypt(&file, &HashMap::new()).unwrap_err().to_string();
    assert_eq!(err, "执行部分操作时发生错误");
}

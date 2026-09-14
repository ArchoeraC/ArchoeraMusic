// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later


use std::collections::HashMap;
use std::process::exit;

fn usage() -> ! {
    eprintln!("usage: decrypt <input> <output> [--qmc-ekey <k>]");
    exit(2);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        usage();
    }
    let input = &args[1];
    let output = &args[2];
    let mut qmc_ekey: Option<String> = None;
    let mut i = 3;
    while i < args.len() {
        match args[i].as_str() {
            "--qmc-ekey" if i + 1 < args.len() => {
                qmc_ekey = Some(args[i + 1].clone());
                i += 2;
            }
            _ => usage(),
        }
    }

    let data = match std::fs::read(input) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("读取失败 {input}: {e}");
            exit(1);
        }
    };

    let result = if archoera_downloader::qmc::is_musicex(&data) {
        match archoera_downloader::qmc::parse_musicex_tag(&data) {
            Ok(tag) => {
                let mut keys: HashMap<String, String> = HashMap::new();
                if let Some(k) = &qmc_ekey {
                    keys.insert(tag.media_file_name.clone(), k.clone());
                } else {
                    eprintln!("执行部分操作时发生错误");
                    exit(1);
                }
                archoera_downloader::qmc::qmc_decrypt(&data, &keys)
            }
            Err(_) => {
                eprintln!("无法解析的头文件或行为");
                exit(1);
            }
        }
    } else {
        let ext = std::path::Path::new(input)
            .extension()
            .and_then(|e| e.to_str());
        archoera_downloader::decrypt::decrypt_container(&data, ext)
    };

    match result {
        Ok((plain, ext)) => {
            let out = if ext.is_empty() {
                output.to_string()
            } else {
                std::path::Path::new(output)
                    .with_extension(&ext)
                    .to_string_lossy()
                    .into_owned()
            };
            if let Err(e) = std::fs::write(&out, &plain) {
                eprintln!("写出失败 {out}: {e}");
                exit(1);
            }
            println!("解密完成: {out} ({} 字节, ext={ext})", plain.len());
        }
        Err(e) => {
            eprintln!("解密失败: {e}");
            exit(1);
        }
    }
}

// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 设备密钥文件（`device.key`，F2）：32B 随机设备材料，仅存本地 0600 文件。
//! 文件缺失即设备因子不可用（m2a 口令路径 → NEED_RECOVERY；m2b → 无法解锁）。

use std::path::{Path, PathBuf};

use crate::crypto;
use crate::errors::{Result, VaultError};
use crate::format::KEY_SIZE;

pub const FILE_NAME: &str = "device.key";

pub fn path_for(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join(FILE_NAME)
}

/// 生成 32B 随机设备材料并落盘（0600 原子写），返回该材料。
pub fn create_and_save(data_dir: &str) -> Result<Vec<u8>> {
    let key = crypto::random_vec(KEY_SIZE)?;
    save(data_dir, &key)?;
    Ok(key)
}

/// 读取设备材料；文件缺失抛 [VaultError::NeedRecovery]。
pub fn load(data_dir: &str) -> Result<Vec<u8>> {
    let path = path_for(data_dir);
    if !path.exists() {
        return Err(VaultError::need_recovery(
            "设备密钥缺失（device.key 不存在）：设备因子不可用，请改用恢复码解锁",
        ));
    }
    let raw = std::fs::read(&path)?;
    if raw.len() != KEY_SIZE {
        return Err(VaultError::invalid_data(format!(
            "device.key 长度异常（{} 字节，应为 {}）",
            raw.len(),
            KEY_SIZE
        )));
    }
    Ok(raw)
}

/// 原子写（tmp + 0600 + rename；失败保留原文件）。
pub fn save(data_dir: &str, key: &[u8]) -> Result<()> {
    if key.len() != KEY_SIZE {
        return Err(VaultError::argument(format!(
            "设备材料须为 {KEY_SIZE} 字节"
        )));
    }
    std::fs::create_dir_all(data_dir)?;
    let path = path_for(data_dir);
    let tmp = PathBuf::from(format!("{}.tmp", path.display()));
    std::fs::write(&tmp, key)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// 删除设备材料（不存在则忽略）。
pub fn delete(data_dir: &str) -> Result<()> {
    let path = path_for(data_dir);
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    Ok(())
}

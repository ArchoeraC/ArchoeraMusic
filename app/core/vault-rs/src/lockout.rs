// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 解锁失败退避（credential-vault-plan §3.7 + security-review SEC-05）。
//!
//! 状态持久化：份额存在（OS/LEGACY/文件模式）→ 内嵌于 `master-share` 槽位的
//! [ShareBundle]；份额缺失（口令/多封装）→ 明文 `<dataDir>/vault.lockout` 回退。

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::errors::Result;
use crate::share::{SecretStore, ShareBundle};

pub const SHARE_KEY: &str = "master-share";

const FILE_NAME: &str = "vault.lockout";
const MAX_FAILURES: i32 = 10;
const BASE_MS: i64 = 1000;
const CAP_MS: i64 = 300_000;

pub struct VaultLockout {
    path: PathBuf,
}

impl VaultLockout {
    pub fn new(data_dir: &str) -> Self {
        Self {
            path: Path::new(data_dir).join(FILE_NAME),
        }
    }

    fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    /// 读取授权侧份额（兼容 legacy 32B 原始份额）。
    pub fn get_share(&self, store: &dyn SecretStore) -> Result<Option<Vec<u8>>> {
        let raw = store.load(SHARE_KEY)?;
        Ok(ShareBundle::decode(raw.as_deref()).0)
    }

    /// 写入授权侧份额（退避状态清零）。
    pub fn set_share(&self, store: &dyn SecretStore, share: &[u8]) -> Result<()> {
        let bundle = ShareBundle::encode(share, 0, 0)?;
        store.store(SHARE_KEY, &bundle)
    }

    /// 删除授权侧份额。
    pub fn delete_share(&self, store: &dyn SecretStore) -> Result<()> {
        store.delete(SHARE_KEY)
    }

    /// 若锁定中返回剩余秒数（等价 C# [Check]，由调用方转为 err）。
    pub fn locked_seconds(&self, store: &dyn SecretStore) -> Option<i64> {
        let (_, _, _, until) = self.read(store);
        let now = Self::now_ms();
        if until > now {
            Some(std::cmp::max(1, (until - now + 999) / 1000))
        } else {
            None
        }
    }

    /// 记录一次解锁失败并写入退避截止时刻（指数退避 + 封顶）。
    pub fn record_failure(&self, store: &dyn SecretStore) {
        let (share, has_share, failures, until) = self.read(store);
        let now = Self::now_ms();
        let mut f = if until > now { failures + 1 } else { 1 };
        f = std::cmp::min(f, MAX_FAILURES);
        let backoff = std::cmp::min(BASE_MS << (f - 1), CAP_MS);
        self.write(store, share.as_deref(), has_share, f, now + backoff);
    }

    /// 成功解锁 / 销毁重建时清零（幂等）。
    pub fn clear(&self, store: &dyn SecretStore) {
        let (share, has_share, _, _) = self.read(store);
        if has_share {
            if let Some(share) = share {
                if let Ok(bundle) = ShareBundle::encode(&share, 0, 0) {
                    let _ = store.store(SHARE_KEY, &bundle);
                }
            }
            return;
        }
        let _ = std::fs::remove_file(&self.path);
    }

    /// 读取退避状态：`(share, has_share, failures, until)`。
    fn read(&self, store: &dyn SecretStore) -> (Option<Vec<u8>>, bool, i32, i64) {
        let raw = store.load(SHARE_KEY).unwrap_or(None);
        if let Some(raw) = raw {
            let (share, failures, until) = ShareBundle::decode(Some(&raw));
            return (share, true, failures, until);
        }
        let (f, u) = self.read_file();
        (None, false, f, u)
    }

    fn write(
        &self,
        store: &dyn SecretStore,
        share: Option<&[u8]>,
        has_share: bool,
        failures: i32,
        until: i64,
    ) {
        if has_share {
            if let Some(share) = share {
                if let Ok(bundle) = ShareBundle::encode(share, failures, until) {
                    let _ = store.store(SHARE_KEY, &bundle);
                }
            }
            return;
        }
        self.write_file(failures, until);
    }

    fn read_file(&self) -> (i32, i64) {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(_) => return (0, 0),
        };
        let parts: Vec<&str> = text.split_whitespace().collect();
        if parts.len() == 2 {
            if let (Ok(f), Ok(u)) = (parts[0].parse::<i32>(), parts[1].parse::<i64>()) {
                return (f.clamp(0, MAX_FAILURES), u);
            }
        }
        (0, 0)
    }

    fn write_file(&self, failures: i32, until: i64) {
        let _ = std::fs::create_dir_all(self.path.parent().unwrap_or(Path::new(".")));
        let tmp = PathBuf::from(format!("{}.tmp", self.path.display()));
        if std::fs::write(&tmp, format!("{failures} {until}")).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}

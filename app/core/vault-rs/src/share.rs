// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 授权侧份额（S）承载 + 解锁退避状态（[ShareBundle]）+ 后端工厂。
//!
//! V1 实现生产 [FileStore]（`<dataDir>/secret.key`，0600）与 [NullSecretStore]
//! （slots 自包含）；OS 后端（DPAPI/Keychain/libsecret）为**桩**：指纹正确、
//! 构造契约一致（libsecret 无 D-Bus 时明确失败），但不触真实钥匙串。

use std::path::{Path, PathBuf};

use crate::errors::{Result, VaultError};
use crate::format::KEY_SIZE;

/// 系统授权侧份额（S）的存取抽象。
pub trait SecretStore {
    fn backend(&self) -> &str;
    fn load(&self, key: &str) -> Result<Option<Vec<u8>>>;
    fn store(&self, key: &str, value: &[u8]) -> Result<()>;
    fn delete(&self, key: &str) -> Result<()>;
}

// ── ShareBundle ────────────────────────────────────────────────────

/// 份额 + 退避状态的同槽承载。布局（小端）：
/// `magic(4)="ASTB" | version(1)=1 | shareLen(1)=32 | share(32) | failures(i32) | until(i64)`
pub struct ShareBundle;

impl ShareBundle {
    pub const SIZE: usize = 50;
    const VERSION: u8 = 1;
    const MAGIC: [u8; 4] = *b"ASTB";
    const SHARE_OFFSET: usize = 6;
    const FAILURES_OFFSET: usize = 38;
    const UNTIL_OFFSET: usize = 42;
    pub const MAX_FAILURES: i32 = 10;

    /// 解码槽位值：
    ///   null / 32B legacy / 合法 bundle / 其他损坏 → (share, failures, until)。
    pub fn decode(raw: Option<&[u8]>) -> (Option<Vec<u8>>, i32, i64) {
        let raw = match raw {
            None => return (None, 0, 0),
            Some(r) => r,
        };
        if raw.len() == KEY_SIZE {
            return (Some(raw.to_vec()), 0, 0);
        }
        if raw.len() >= Self::SIZE
            && raw[0..4] == Self::MAGIC
            && raw[4] == Self::VERSION
            && raw[5] as usize == KEY_SIZE
        {
            let failures = i32::from_le_bytes([
                raw[Self::FAILURES_OFFSET],
                raw[Self::FAILURES_OFFSET + 1],
                raw[Self::FAILURES_OFFSET + 2],
                raw[Self::FAILURES_OFFSET + 3],
            ])
            .clamp(0, Self::MAX_FAILURES);
            let until = i64::from_le_bytes([
                raw[Self::UNTIL_OFFSET],
                raw[Self::UNTIL_OFFSET + 1],
                raw[Self::UNTIL_OFFSET + 2],
                raw[Self::UNTIL_OFFSET + 3],
                raw[Self::UNTIL_OFFSET + 4],
                raw[Self::UNTIL_OFFSET + 5],
                raw[Self::UNTIL_OFFSET + 6],
                raw[Self::UNTIL_OFFSET + 7],
            ]);
            let share = raw[Self::SHARE_OFFSET..Self::SHARE_OFFSET + KEY_SIZE].to_vec();
            return (Some(share), failures, until);
        }
        (None, 0, 0)
    }

    /// 编码份额 + 退避状态。
    pub fn encode(share: &[u8], failures: i32, until: i64) -> Result<Vec<u8>> {
        if share.len() != KEY_SIZE {
            return Err(VaultError::argument(format!("份额须为 {KEY_SIZE} 字节")));
        }
        let mut buf = vec![0u8; Self::SIZE];
        buf[0..4].copy_from_slice(&Self::MAGIC);
        buf[4] = Self::VERSION;
        buf[5] = KEY_SIZE as u8;
        buf[Self::SHARE_OFFSET..Self::SHARE_OFFSET + KEY_SIZE].copy_from_slice(share);
        let f = failures.clamp(0, Self::MAX_FAILURES);
        buf[Self::FAILURES_OFFSET..Self::FAILURES_OFFSET + 4].copy_from_slice(&f.to_le_bytes());
        buf[Self::UNTIL_OFFSET..Self::UNTIL_OFFSET + 8].copy_from_slice(&until.to_le_bytes());
        Ok(buf)
    }
}

// ── 后端实现 ────────────────────────────────────────────────────────

/// 自包含模式（slots）的无操作后端。
pub struct NullSecretStore;

impl SecretStore for NullSecretStore {
    fn backend(&self) -> &str {
        "none"
    }
    fn load(&self, _key: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    fn store(&self, _key: &str, _value: &[u8]) -> Result<()> {
        Ok(())
    }
    fn delete(&self, _key: &str) -> Result<()> {
        Ok(())
    }
}

/// 文件密钥后端：K 整体落盘 `<dataDir>/secret.key`（0600 原子写）。
pub struct FileStore {
    data_dir: String,
}

impl FileStore {
    pub fn new(data_dir: &str) -> Self {
        Self {
            data_dir: data_dir.to_string(),
        }
    }
    fn key_path(&self) -> PathBuf {
        Path::new(&self.data_dir).join("secret.key")
    }
}

impl SecretStore for FileStore {
    fn backend(&self) -> &str {
        "file"
    }
    fn load(&self, _key: &str) -> Result<Option<Vec<u8>>> {
        let path = self.key_path();
        if !path.exists() {
            return Ok(None);
        }
        let raw = std::fs::read(&path)?;
        // 槽位值：legacy 32B 原始 K，或含退避状态的 ShareBundle。
        if raw.len() == KEY_SIZE || raw.len() >= ShareBundle::SIZE {
            Ok(Some(raw))
        } else {
            Ok(None)
        }
    }
    fn store(&self, _key: &str, value: &[u8]) -> Result<()> {
        std::fs::create_dir_all(&self.data_dir)?;
        let path = self.key_path();
        let tmp = PathBuf::from(format!("{}.tmp", path.display()));
        std::fs::write(&tmp, value)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        }
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }
    fn delete(&self, _key: &str) -> Result<()> {
        let path = self.key_path();
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        Ok(())
    }
}

/// Linux Secret Service（libsecret）后端——**V1 桩**：指纹/构造契约一致，
/// 未接入真实 D-Bus 钥匙串（V1 以 FileStore/NullSecretStore 覆盖 headless 场景）。
pub struct LibsecretStore {
    _data_dir: String,
}

impl LibsecretStore {
    pub fn new(data_dir: &str) -> Result<Self> {
        if std::env::var("DBUS_SESSION_BUS_ADDRESS")
            .map(|v| v.is_empty())
            .unwrap_or(true)
        {
            return Err(VaultError::SecretStoreUnavailable(
                "Linux Secret Service 不可用（无 D-Bus session bus）：凭据持久化需降级为口令派生或禁用"
                    .to_string(),
            ));
        }
        Ok(Self {
            _data_dir: data_dir.to_string(),
        })
    }
}

impl SecretStore for LibsecretStore {
    fn backend(&self) -> &str {
        "libsecret"
    }
    fn load(&self, _key: &str) -> Result<Option<Vec<u8>>> {
        // V1 桩：无真实钥匙串访问，视为无份额（fail-closed）。
        Ok(None)
    }
    fn store(&self, _key: &str, _value: &[u8]) -> Result<()> {
        Err(VaultError::SecretStoreUnavailable(
            "Linux Secret Service 后端在 V1 中未实现（请使用 file 后端）".to_string(),
        ))
    }
    fn delete(&self, _key: &str) -> Result<()> {
        Ok(())
    }
}

/// Windows DPAPI 后端——V1 桩（仅非 Windows 构建编译；真实实现在 Windows 平台）。
#[cfg(windows)]
pub struct DpapiStore {
    _data_dir: String,
}

#[cfg(windows)]
impl DpapiStore {
    pub fn new(data_dir: &str) -> Self {
        Self {
            _data_dir: data_dir.to_string(),
        }
    }
}

#[cfg(windows)]
impl SecretStore for DpapiStore {
    fn backend(&self) -> &str {
        "dpapi"
    }
    fn load(&self, _key: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    fn store(&self, _key: &str, _value: &[u8]) -> Result<()> {
        Err(VaultError::SecretStoreUnavailable(
            "DPAPI 后端在 V1 中未实现".to_string(),
        ))
    }
    fn delete(&self, _key: &str) -> Result<()> {
        Ok(())
    }
}

/// macOS Keychain 后端——V1 桩（仅 macOS 构建编译）。
#[cfg(target_os = "macos")]
pub struct KeychainStore {
    _data_dir: String,
}

#[cfg(target_os = "macos")]
impl KeychainStore {
    pub fn new(data_dir: &str) -> Self {
        Self {
            _data_dir: data_dir.to_string(),
        }
    }
}

#[cfg(target_os = "macos")]
impl SecretStore for KeychainStore {
    fn backend(&self) -> &str {
        "keychain"
    }
    fn load(&self, _key: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    fn store(&self, _key: &str, _value: &[u8]) -> Result<()> {
        Err(VaultError::SecretStoreUnavailable(
            "Keychain 后端在 V1 中未实现".to_string(),
        ))
    }
    fn delete(&self, _key: &str) -> Result<()> {
        Ok(())
    }
}

/// 读 vault 文件头记录的后端指纹（无文件 / 头损坏 → None）。
fn read_vault_backend(data_dir: &str) -> Option<String> {
    let path = Path::new(data_dir).join(crate::service::VAULT_FILE_NAME);
    if !path.exists() {
        return None;
    }
    crate::format::read_header(&path.to_string_lossy())
        .ok()
        .and_then(|h| h.backend)
}

/// 平台安全存储工厂。
pub fn secret_store_factory(data_dir: &str) -> Result<Box<dyn SecretStore>> {
    let backend = read_vault_backend(data_dir);
    if backend.as_deref() == Some("file") {
        return Ok(Box::new(FileStore::new(data_dir)));
    }
    if std::env::var("ARCHOERA_VAULT_BACKEND").as_deref() == Ok("file") && backend.is_none() {
        return Ok(Box::new(FileStore::new(data_dir)));
    }
    let _ = &backend;
    #[cfg(windows)]
    {
        return Ok(Box::new(DpapiStore::new(data_dir)));
    }
    #[cfg(target_os = "macos")]
    {
        return Ok(Box::new(KeychainStore::new(data_dir)));
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        return Ok(Box::new(LibsecretStore::new(data_dir)?));
    }
    #[cfg(not(any(unix, windows)))]
    {
        Err(VaultError::SecretStoreUnavailable(
            "不支持的平台：无可用 OS 安全存储".to_string(),
        ))
    }
}

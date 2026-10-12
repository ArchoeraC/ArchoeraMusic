// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 凭据加密方案（security. 前缀）──────────────────────────────

/// 凭据加密方案（cookie/密码的落盘保护实现）：
///   'crypto'（LEGACY，默认推荐）：单因子——主密钥 K 整体存 OS 安全存储
///     （DPAPI/Keychain/libsecret），稳定、无份额配对丢失风险；
///   'file'（LEGACY 兼容）：单因子——主密钥 K 落盘 `secret.key`（0600），
///     免 OS 钥匙串，供无 Secret Service 的 headless/Docker 使用；
///     本地文件单点，泄露即全破，选用即显式接受降级；
///   'm1'（slots）：仅口令槽——主密钥 K 由 Argon2id(口令) 派生的 KEK 封装在
///     保险库槽位表中（自包含，免 OS 钥匙串）；每次启动输入口令解锁；
///   'm2a'（slots）：口令 + 本机 device.key 双因子槽 + 恢复槽——安全性最高，
///     初始化时一次性输出恢复码；丢失 device.key（换机）时用恢复码解锁；
///   'm2b'（slots）：仅设备槽——本机免密解锁，无口令、无恢复码；
///     device.key 丢失即无法恢复；
///   'vault'（历史 2-of-2，已移除）：非法值统一回退默认 crypto。
/// 各方案加密结构不兼容：切换需销毁重建（无迁移），旧凭据会被清空并需重新登录。
const credentialSchemeKey = 'security.scheme';

/// 首次启动「加密方案选择」对话框是否已展示（一次性，避免每次启动打扰）。
const credentialSchemeDialogShownKey = 'security.schemeDialogShown';

/// m2a 恢复码是否已由用户确认抄写/保存（一次性提醒；初始化/切换至 m2a 时复位）。
const m2aRecoveryAckedKey = 'security.m2aRecoveryAcked';

/// Argon2id 口令 KDF 强度预设（'low'|'medium'|'high'；默认 'medium'）。
///
/// **独立于加密方案键**：仅对 m1/m2a 的口令承载槽生效；crypto/file/m2b
/// 无口令 KDF，读取该值仅用于界面回显（不产生效果）。
const vaultKdfPresetKey = 'security.vaultKdfPreset';

const String defaultCredentialScheme = 'crypto';

/// 合法 KDF 预设集合（与 `vault_kdf.dart` 的预设 id 对齐）。
const Set<String> _vaultKdfPresetIds = {'low', 'medium', 'high'};

/// 凭据加密方案偏好。
extension SecurityPrefs on AppPrefs {
  /// 当前方案（非法值回退默认 crypto）。
  String get credentialScheme {
    final v = data[credentialSchemeKey];
    if (v is String &&
        (v == 'crypto' ||
            v == 'file' ||
            v == 'm1' ||
            v == 'm2a' ||
            v == 'm2b')) {
      return v;
    }
    return defaultCredentialScheme;
  }

  /// 首次启动方案对话框是否已展示。
  bool get schemeDialogShown =>
      data[credentialSchemeDialogShownKey] as bool? ?? false;

  /// m2a 恢复码是否已确认备份（false 时设置页显示持久「尚未备份」提醒）。
  bool get m2aRecoveryAcked =>
      data[m2aRecoveryAckedKey] as bool? ?? false;

  /// 当前 Argon2id 强度预设 id（'low'|'medium'|'high'；非法值回退 'medium'）。
  /// 仅 m1/m2a 生效；用于设置页回显与初始化时选取参数。
  String get vaultKdfPreset {
    final v = data[vaultKdfPresetKey];
    if (v is String && _vaultKdfPresetIds.contains(v)) return v;
    return 'medium';
  }

  AppPrefs copyWithCredentialScheme(String value) =>
      AppPrefs(initialData: {...data, credentialSchemeKey: value});

  AppPrefs copyWithSchemeDialogShown(bool value) =>
      AppPrefs(initialData: {...data, credentialSchemeDialogShownKey: value});

  AppPrefs copyWithM2aRecoveryAcked(bool value) =>
      AppPrefs(initialData: {...data, m2aRecoveryAckedKey: value});

  AppPrefs copyWithVaultKdfPreset(String value) =>
      AppPrefs(initialData: {...data, vaultKdfPresetKey: value});
}

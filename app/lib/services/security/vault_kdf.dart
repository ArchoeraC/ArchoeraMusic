// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Argon2id 口令 KDF 强度预设（用户可选；**仅作用于 m1/m2a 的口令承载槽**）。
///
/// 取值与 vault 侧 `VaultLimits.ValidateKdf` 区间一致
/// （m ∈ [8192, 262144] KiB、t ∈ [1, 16]、p ∈ [1, 8]）。数值越大越抗
/// GPU 爆破，但解锁越慢。预设集中定义于此，`VaultProcess` / 设置页 / 偏好
/// 均引用同一份常量，避免多处漂移。
class VaultKdfPreset {
  const VaultKdfPreset(this.id, this.mKiB, this.t, this.p);

  /// 稳定标识（持久化于 prefs：'low' | 'medium' | 'high'）。
  final String id;

  /// Argon2id 内存代价（KiB）。
  final int mKiB;

  /// Argon2id 迭代次数。
  final int t;

  /// Argon2id 并行度。
  final int p;
}

/// 低强度（32 MiB；解锁约 200ms）。
const VaultKdfPreset vaultKdfLow = VaultKdfPreset('low', 32768, 3, 1);

/// 中强度（64 MiB；默认；解锁约 400ms）。
const VaultKdfPreset vaultKdfMedium = VaultKdfPreset('medium', 65536, 3, 1);

/// 高强度（256 MiB；解锁约 1.5s）。
const VaultKdfPreset vaultKdfHigh = VaultKdfPreset('high', 262144, 4, 1);

/// 可选预设（低 → 高）。
const List<VaultKdfPreset> vaultKdfPresets = [
  vaultKdfLow,
  vaultKdfMedium,
  vaultKdfHigh,
];

/// 默认预设 id（中强度）。
const String defaultVaultKdfPresetId = 'medium';

/// id → 预设；未知/非法 id 回退默认中强度（不虚构新的 m/t/p）。
VaultKdfPreset vaultKdfPresetById(String? id) {
  for (final p in vaultKdfPresets) {
    if (p.id == id) return p;
  }
  return vaultKdfMedium;
}

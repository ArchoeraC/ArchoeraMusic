// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Vault（M 系：`slots-m1` / `m2a` / `m2b`）三档变体的**滑动条映射**——纯函数，可单测。
///
/// 顺序按**本机威胁模型强度**从左到右（滑动条的语义就是「越往右越强」）：
///
///   M2B 仅设备（本机免密，最弱） → M1 口令单因子 → M2A 口令 + 设备双因子 + 恢复码（最强）
///
/// **刻意不按代号字典序**（m1 / m2a / m2b）排列：代号序与强度序不一致，会让「滑到右边」的
/// 直觉语义含混。设置页把三档合并为**一个**「Vault（实验性）」选项，滑条在其中切换（见
/// `docs/vault-enhanced-scheme.md`）。
library;

/// 滑动条从左到右的变体顺序（见文件头说明）。
const List<String> kVaultSchemeSliderOrder = <String>['m2b', 'm1', 'm2a'];

/// 该方案是否属于 Vault（M 系）——决定设置页显示合并卡 + 变体滑条。
bool isVaultScheme(String scheme) => kVaultSchemeSliderOrder.contains(scheme);

/// 方案 → 滑条位置；不属于 M 系时回退到**最强档**（M2A）作为进入 Vault 的默认落点。
int vaultSchemeSliderIndex(String scheme) {
  final index = kVaultSchemeSliderOrder.indexOf(scheme);
  return index < 0 ? kVaultSchemeSliderOrder.length - 1 : index;
}

/// 滑条位置 → 方案（越界钳制：Slider 的浮点值 round 后理论上在界内，仍防御性收敛）。
String vaultSchemeAtSliderIndex(int index) =>
    kVaultSchemeSliderOrder[index.clamp(0, kVaultSchemeSliderOrder.length - 1)];

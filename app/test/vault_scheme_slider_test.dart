// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/settings/security/vault_scheme_slider.dart';

/// Vault（M 系）合并卡 + 变体滑条的映射纯单测。
///
/// 顺序约定：**按本机威胁模型强度从左到右**（M2B 仅设备 → M1 口令 → M2A 口令+设备），
/// 滑动条语义 = 越往右越强；不按代号字典序（m1/m2a/m2b）。
void main() {
  test('滑条顺序按强度：仅设备 → 口令 → 口令+设备', () {
    expect(kVaultSchemeSliderOrder, const ['m2b', 'm1', 'm2a']);
  });

  test('isVaultScheme 只认 M 系三档（LEGACY/FILK 不算）', () {
    expect(isVaultScheme('m1'), isTrue);
    expect(isVaultScheme('m2a'), isTrue);
    expect(isVaultScheme('m2b'), isTrue);
    expect(isVaultScheme('crypto'), isFalse);
    expect(isVaultScheme('file'), isFalse);
    expect(isVaultScheme(''), isFalse);
  });

  test('方案 ↔ 滑条位置互逆', () {
    for (final s in kVaultSchemeSliderOrder) {
      expect(vaultSchemeAtSliderIndex(vaultSchemeSliderIndex(s)), s);
    }
    expect(vaultSchemeSliderIndex('m2b'), 0);
    expect(vaultSchemeSliderIndex('m1'), 1);
    expect(vaultSchemeSliderIndex('m2a'), 2);
  });

  test('非 M 系回退到最强档（进入 Vault 的默认落点）', () {
    expect(vaultSchemeAtSliderIndex(vaultSchemeSliderIndex('crypto')), 'm2a');
    expect(vaultSchemeAtSliderIndex(vaultSchemeSliderIndex('file')), 'm2a');
  });

  test('越界钳制（Slider 浮点 round 的防御性收敛）', () {
    expect(vaultSchemeAtSliderIndex(-1), 'm2b');
    expect(vaultSchemeAtSliderIndex(99), 'm2a');
  });
}

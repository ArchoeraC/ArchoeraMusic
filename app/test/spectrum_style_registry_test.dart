// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱样式注册表守卫：
/// - `spectrumStyles`（偏好白名单）与注册表 id 集合必须一致，避免设置里能
///   选到未注册样式、或注册了却无法持久化；
/// - 未知 id 一律回退 `bars`（旧数据/降级安全）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/prefs_player.dart';
import 'package:archoera_music/widgets/player/spectrum_view/styles/spectrum_style_registry.dart';

void main() {
  test('注册表 id 与偏好白名单一致', () {
    final ids = spectrumStyleRenderers.map((style) => style.id).toSet();
    expect(ids, equals(spectrumStyles));
  });

  test('未知样式回退 bars', () {
    expect(spectrumStyleRendererFor('bars').id, 'bars');
    expect(spectrumStyleRendererFor('wave').id, 'wave');
    expect(spectrumStyleRendererFor('waveUp').id, 'waveUp');
    expect(spectrumStyleRendererFor('not-a-spectrum').id, 'bars');
    expect(spectrumStyleRendererFor('').id, 'bars');
  });

  test('每个频谱样式 id 唯一', () {
    final ids = spectrumStyleRenderers.map((style) => style.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}

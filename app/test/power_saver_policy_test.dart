// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 节能档位 → 渲染策略：最小化 / 隐藏到托盘直接停帧（0 帧），其余档位降频。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/power/power_saver.dart';

void main() {
  test('最小化 / 托盘 → 直接停止渲染', () {
    final p = powerSaverRenderPolicy(PowerSaverReason.minimized);
    expect(p.stopRendering, isTrue);
    expect(p.interval, Duration.zero);
  });

  test('失焦 / 熄屏 → 1 FPS 降帧（不停帧）', () {
    for (final r in [PowerSaverReason.unfocused, PowerSaverReason.screenOff]) {
      final p = powerSaverRenderPolicy(r);
      expect(p.stopRendering, isFalse, reason: '$r 不应停帧');
      expect(p.interval, const Duration(seconds: 1), reason: '$r 应为 1 FPS');
    }
  });

  test('前台正常 → 满帧', () {
    final p = powerSaverRenderPolicy(PowerSaverReason.none);
    expect(p.stopRendering, isFalse);
    expect(p.interval, Duration.zero);
  });
}

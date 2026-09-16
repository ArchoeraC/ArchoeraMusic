// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 自适应画质服务回归测试：档位→renderScale 纯映射、默认停用、启停安全。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/render/quality_governor.dart';
import 'package:archoera_music/services/render/render_quality_service.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 内存偏好 Notifier（不落盘）：仅覆盖自适应画质 setter 以免测试写盘。
class _TestPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();

  @override
  void setAdaptiveRenderQuality(bool value) {
    state = state.copyWithAdaptiveRenderQuality(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('renderScaleForTier（纯映射）', () {
    test('full → 1.0 / balanced → 0.85 / performance → 0.7', () {
      expect(renderScaleForTier(RenderQualityTier.full), 1.0);
      expect(renderScaleForTier(RenderQualityTier.balanced), 0.85);
      expect(renderScaleForTier(RenderQualityTier.performance), 0.7);
    });
  });

  group('RenderQualityService', () {
    test('默认停用且档位为 full（不注册任何回调）', () {
      final service = RenderQualityService();
      expect(service.enabled, isFalse);
      expect(service.tier, RenderQualityTier.full);
      service.dispose();
    });

    test('启用后停用：复位 full 并注销回调', () {
      final service = RenderQualityService();
      service.setEnabled(true);
      expect(service.enabled, isTrue);
      service.setEnabled(false);
      expect(service.enabled, isFalse);
      expect(service.tier, RenderQualityTier.full);
      service.dispose();
    });

    test('重复 setEnabled 幂等，dispose 安全', () {
      final service = RenderQualityService();
      service.setEnabled(false);
      service.setEnabled(true);
      service.setEnabled(true);
      service.dispose();
    });
  });

  group('renderQualityProvider', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [appPrefsProvider.overrideWith(_TestPrefsNotifier.new)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('默认关闭：服务停用且档位 full', () {
      final c = container();
      expect(c.read(renderQualityProvider), RenderQualityTier.full);
      expect(c.read(renderQualityProvider.notifier).service.enabled, isFalse);
    });

    test('偏好切换即时启用 / 停用服务', () {
      final c = container();
      final controller = c.read(renderQualityProvider.notifier);
      final prefs = c.read(appPrefsProvider.notifier);
      expect(controller.service.enabled, isFalse);

      prefs.setAdaptiveRenderQuality(true);
      expect(controller.service.enabled, isTrue);

      prefs.setAdaptiveRenderQuality(false);
      expect(controller.service.enabled, isFalse);
      expect(c.read(renderQualityProvider), RenderQualityTier.full);
    });
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 渲染帧数上限：偏好收敛、FPS → 最小帧间隔、节能档位合并、滑块颜色阈值。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/power/frame_governor.dart';
import 'package:archoera_music/settings/settings_widgets.dart';
import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('渲染帧数偏好', () {
    test('默认 60，越界值收敛到 30~165', () {
      expect(AppPrefs().renderFps, kRenderFpsDefault);
      expect(AppPrefs(initialData: {renderFpsKey: 5}).renderFps, kRenderFpsMin);
      expect(
        AppPrefs(initialData: {renderFpsKey: 999}).renderFps,
        kRenderFpsMax,
      );
      // JSON 里的数字可能是 double（手改偏好文件）：取整后再收敛。
      expect(AppPrefs(initialData: {renderFpsKey: 144.6}).renderFps, 144);
    });

    test('写入同样收敛，不写非法类型以外的键', () {
      final prefs = AppPrefs();
      expect(prefs.copyWithRenderFps(1).renderFps, kRenderFpsMin);
      expect(prefs.copyWithRenderFps(400).renderFps, kRenderFpsMax);
      expect(prefs.copyWithRenderFps(144).renderFps, 144);
    });
  });

  group('frameIntervalForFps', () {
    test('目标帧率不低于刷新率时不节流', () {
      expect(frameIntervalForFps(60, displayRefreshRate: 60), Duration.zero);
      expect(frameIntervalForFps(165, displayRefreshRate: 60), Duration.zero);
      expect(frameIntervalForFps(144, displayRefreshRate: 144), Duration.zero);
      // 刷新率未知（0）时仍然按上限节流。
      expect(frameIntervalForFps(60), isNot(Duration.zero));
    });

    test('低于刷新率时按目标间隔留 4% 余量（至少 0.2ms、至多 1ms）', () {
      // 30 FPS ≈ 33.33ms，余量封顶 1ms，避免与 vsync 擦肩而过丢帧。
      expect(
        frameIntervalForFps(30, displayRefreshRate: 60).inMicroseconds,
        closeTo(32333, 2),
      );
      // 90 FPS ≈ 11.11ms，余量 4% ≈ 0.44ms。
      expect(
        frameIntervalForFps(90, displayRefreshRate: 144).inMicroseconds,
        closeTo(10667, 2),
      );
    });

    test('上限 165 FPS 也至少保留 1ms 间隔；0 = 不限制', () {
      expect(
        frameIntervalForFps(165, displayRefreshRate: 240).inMicroseconds,
        greaterThanOrEqualTo(1000),
      );
      expect(frameIntervalForFps(0, displayRefreshRate: 60), Duration.zero);
      expect(frameIntervalForFps(-5, displayRefreshRate: 60), Duration.zero);
    });
  });

  group('effectiveFrameInterval', () {
    test('取更严格（帧率更低）的一个', () {
      expect(
        effectiveFrameInterval(
          const Duration(seconds: 1),
          const Duration(milliseconds: 16),
        ),
        const Duration(seconds: 1),
      );
      expect(
        effectiveFrameInterval(Duration.zero, const Duration(milliseconds: 16)),
        const Duration(milliseconds: 16),
      );
      // 节能前台（不限）+ 用户上限 30 FPS → 用户上限生效。
      expect(
        effectiveFrameInterval(
          Duration.zero,
          frameIntervalForFps(30, displayRefreshRate: 60),
        ),
        frameIntervalForFps(30, displayRefreshRate: 60),
      );
      // 未知上限也保持「两个都不限制」。
      expect(
        effectiveFrameInterval(Duration.zero, Duration.zero),
        Duration.zero,
      );
    });
  });

  group('renderFpsSliderColor', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF5B8CFF));

    test('≤60 用主题色，61~100 黄色，>100 红色', () {
      expect(renderFpsSliderColor(scheme, 30), scheme.primary);
      expect(renderFpsSliderColor(scheme, 60), scheme.primary);
      expect(renderFpsSliderColor(scheme, 61), kRenderFpsWarnColor);
      expect(renderFpsSliderColor(scheme, 100), kRenderFpsWarnColor);
      expect(renderFpsSliderColor(scheme, 101), scheme.error);
      expect(renderFpsSliderColor(scheme, 165), scheme.error);
    });
  });
}

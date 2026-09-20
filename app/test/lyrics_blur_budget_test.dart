// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 失焦「帧预算守卫」与档位解析的单元测试（纯函数，不需要 widget 环境）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_blur_budget.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';

void main() {
  group('LyricsBlurBudget', () {
    test('窗口未满不下结论', () {
      final b = LyricsBlurBudget(windowFrames: 10, minJankFrames: 8);
      for (var i = 0; i < 9; i++) {
        expect(b.onFrame(30, uiMs: 2), isFalse);
      }
      expect(b.sampledFrames, 9);
    });

    test('窗口内超预算帧数达到阈值才建议降级', () {
      final b = LyricsBlurBudget(windowFrames: 10, minJankFrames: 8);
      var fired = false;
      // 7 帧超预算 + 3 帧正常 = 窗口满但不到阈值。
      for (var i = 0; i < 10; i++) {
        fired = b.onFrame(i < 7 ? 30 : 5, uiMs: 2) || fired;
      }
      expect(fired, isFalse, reason: '只有 7 帧超预算（< 8）');
      expect(b.jankFrames, 7);

      // 再来 8 帧超预算（把窗口里的正常帧挤出去）→ 触发。
      for (var i = 0; i < 8 && !fired; i++) {
        fired = b.onFrame(30, uiMs: 2);
      }
      expect(fired, isTrue);
      expect(b.jankFrames, greaterThanOrEqualTo(8));
    });

    test('UI 线程也超预算的帧不计入（那是 UI 的锅，不是失焦）', () {
      final b = LyricsBlurBudget(windowFrames: 10, minJankFrames: 6);
      for (var i = 0; i < 10; i++) {
        expect(b.onFrame(30, uiMs: 20), isFalse);
      }
      expect(b.jankFrames, 0);
    });

    test('reset 清空窗口', () {
      final b = LyricsBlurBudget(windowFrames: 4, minJankFrames: 4);
      for (var i = 0; i < 3; i++) {
        b.onFrame(30, uiMs: 1);
      }
      b.reset();
      expect(b.sampledFrames, 0);
      expect(b.jankFrames, 0);
    });
  });

  group('resolveLyricsBlurMode', () {
    test('默认整层档（层数恒定，弱机友好）', () {
      expect(
        resolveLyricsBlurMode(enableBlur: true, autoDegraded: false),
        LyricsBlurMode.panel,
      );
    });

    test('关闭开关 → off', () {
      expect(
        resolveLyricsBlurMode(enableBlur: false, autoDegraded: false),
        LyricsBlurMode.off,
      );
    });

    test('自动降级 → off', () {
      expect(
        resolveLyricsBlurMode(enableBlur: true, autoDegraded: true),
        LyricsBlurMode.off,
      );
    });

    test('显式覆盖优先于一切（含关闭开关与降级）', () {
      expect(
        resolveLyricsBlurMode(
          enableBlur: false,
          override: LyricsBlurMode.perLine,
          autoDegraded: true,
        ),
        LyricsBlurMode.perLine,
      );
    });
  });

  group('lyricsBlurOverrideFrom', () {
    test('识别三种档位与别名', () {
      expect(lyricsBlurOverrideFrom('perline'), LyricsBlurMode.perLine);
      expect(lyricsBlurOverrideFrom(' PER-LINE '), LyricsBlurMode.perLine);
      expect(lyricsBlurOverrideFrom('per_line'), LyricsBlurMode.perLine);
      expect(lyricsBlurOverrideFrom('panel'), LyricsBlurMode.panel);
      expect(lyricsBlurOverrideFrom('off'), LyricsBlurMode.off);
      expect(lyricsBlurOverrideFrom('none'), LyricsBlurMode.off);
      expect(lyricsBlurOverrideFrom('0'), LyricsBlurMode.off);
    });

    test('无法识别 → null（走默认档位）', () {
      expect(lyricsBlurOverrideFrom(null), isNull);
      expect(lyricsBlurOverrideFrom(''), isNull);
      expect(lyricsBlurOverrideFrom('fancy'), isNull);
    });
  });
}

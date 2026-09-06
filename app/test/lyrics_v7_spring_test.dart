// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Spring1D 弹簧引擎 + lyrics_v7 布局工具的单元测试。
///
/// 弹簧断言覆盖：临界/过阻尼（含 soft）单调收敛、delayMs 延迟队列
/// （未到期返回原值/到期向 target）、hardSet 立即到位、
/// 默认欠阻尼参数下 300ms 内基本收敛。
/// 布局断言覆盖：行高实测（主行 + 翻译小字）与自然中心累计。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_layout.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/spring.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Spring1D', () {
    test('过阻尼/soft 分支单调收敛到 target 且不越过', () {
      for (final params in <SpringParams>[
        const SpringParams(damping: 60), // 60 > 2·√(90·0.9) = 18 → 过阻尼
        const SpringParams(soft: true),
      ]) {
        final s = Spring1D(params: params);
        s.hardSet(0);
        s.setTarget(100);

        var prev = s.current;
        var monotonic = true;
        var overshoot = false;
        double? arrivedAt;
        var t = 0.0;
        while (t < 2.5) {
          s.update(0.01);
          t += 0.01;
          if (s.current < prev) monotonic = false;
          if (s.current > 100) overshoot = true;
          prev = s.current;
          arrivedAt ??= s.arrived() ? t : null;
        }

        expect(monotonic, isTrue, reason: '无振荡分支应逐帧单调趋近 target');
        expect(overshoot, isFalse, reason: '不应越过 target');
        expect(arrivedAt, isNotNull, reason: '应在 2.5s 内稳定');
        expect(s.current, closeTo(100, 1e-4));
      }
    });

    test('delayMs 未到期保持原值，到期后向 target 运动', () {
      final s = Spring1D();
      s.hardSet(0);
      s.setTarget(100, delayMs: 200);

      // 前 100ms：延迟未过，位置保持原值 0
      for (var i = 0; i < 10; i++) {
        s.update(0.01);
      }
      expect(s.delayMs, closeTo(100, 1e-6));
      expect(s.current, closeTo(0, 1e-9));
      expect(s.arrived(), isFalse);

      // 到 190ms 仍保持原值
      for (var i = 0; i < 9; i++) {
        s.update(0.01);
      }
      expect(s.current, closeTo(0, 1e-9));

      // 第 200ms 恰好到期：开始向 target 运动
      s.update(0.01);
      expect(s.current, greaterThan(0));
      expect(s.current, lessThan(100));
      expect(s.delayMs, 0);
      expect(s.targetPosition, 100);

      // 给足时间后收敛到 target
      var t = 0.21;
      while (t < 2.5) {
        s.update(0.01);
        t += 0.01;
      }
      expect(s.arrived(), isTrue);
      expect(s.current, closeTo(100, 1e-4));
    });

    test('hardSet 立即到位且不随后续 update 漂移', () {
      final s = Spring1D();
      s.setTarget(50);
      s.update(0.02); // 先动一下
      expect(s.current, greaterThan(0));
      expect(s.arrived(), isFalse);

      s.hardSet(123.5);
      expect(s.current, 123.5);
      expect(s.targetPosition, 123.5);
      expect(s.velocity, 0);
      expect(s.delayMs, 0);
      expect(s.arrived(), isTrue);

      s.update(0.05);
      s.update(0.02);
      expect(s.current, 123.5);
    });

    test('默认参数（欠阻尼）下 300ms 内基本收敛（误差 < 1）', () {
      // 默认 mass0.9/damping15/stiffness90 阻尼比 ≈ 0.83，轻微欠阻尼。
      // 小位移（6px）下 300ms 的解析误差约 0.7px，满足 < 1 收敛判据。
      final s = Spring1D();
      s.hardSet(0);
      s.setTarget(6);
      for (var i = 0; i < 75; i++) {
        s.update(0.004); // 合计 300ms
      }
      expect((s.targetPosition - s.current).abs(), lessThan(1.0));
      expect(s.current, greaterThan(4), reason: '应已走过大部分路程');
      expect(s.current, lessThan(6.5), reason: '轻微欠阻尼不应明显过冲');
    });
  });

  group('lyrics_layout', () {
    final groups = <LyricGroup>[
      const LyricGroup(original: LyricLine(timeMs: 0, text: '晴天')),
      LyricGroup(
        original: const LyricLine(timeMs: 0, text: '故事的小黄花'),
        translation: 'The little yellow flowers',
      ),
      const LyricGroup(original: LyricLine(timeMs: 0, text: '从出生那年就飘着')),
    ];
    const fontSize = 20.0;
    const maxWidth = 400.0;

    test('computeLineHeights 主行 + 翻译小字累加', () {
      final heights = computeLineHeights(
        groups,
        fontSize: fontSize,
        maxWidth: maxWidth,
      );
      // Ahem 测试字体行高 = fontSize：无翻译组 20，
      // 带翻译组 = 主行 + max(3, fs*gapEm) + fs*transScale
      expect(heights, hasLength(3));
      expect(heights[0], closeTo(20, 0.01));
      expect(
        heights[1],
        closeTo(
          fontSize +
              (fontSize * kMainTranslationGapEm < 3
                  ? 3
                  : fontSize * kMainTranslationGapEm) +
              fontSize * kTranslationFontScale,
          0.01,
        ),
      );
      expect(heights[2], closeTo(20, 0.01));

      final noTrans = computeLineHeights(
        groups,
        fontSize: fontSize,
        maxWidth: maxWidth,
        showTranslation: false,
      );
      expect(noTrans[1], closeTo(20, 0.01));
    });

    test('computeCenters 按 半高+间隙+半高 累计', () {
      const heights = <double>[20, 34];
      const gap = 8.0;
      final centers = computeCenters(heights, gapPx: gap);
      expect(centers[0], 10); // h0/2
      expect(centers[1], closeTo(20 + gap + 17, 1e-9)); // h0 + gap + h1/2
    });

    test('空输入返回空列表', () {
      expect(
        computeLineHeights(const [], fontSize: 20, maxWidth: 400),
        isEmpty,
      );
      expect(computeCenters(const []), isEmpty);
    });
  });
}

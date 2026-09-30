// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 合成扫亮测试：传统单行歌词（无逐字时间）按行窗口推算逐字片段，
/// 让主行与翻译 / 音译都能扫亮。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/engine/lyric_pipeline.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_word_anim.dart';

void main() {
  group('synthesizeSweepFragments', () {
    test('CJK 逐字、拼接与原文完全一致、标记 synthetic', () {
      final f = synthesizeSweepFragments('你好世界', 0, 5000)!;
      expect(f.map((e) => e.text).join(), '你好世界');
      expect(f.map((e) => e.text).toList(), ['你', '好', '世', '界']);
      expect(f.every((e) => e.synthetic), isTrue);
      // 估算 4 × 240 = 960ms 内扫完（窗口 5000ms 有余亮）。
      expect(f.last.startMs + f.last.durationMs!, 960);
      expect(f.first.startMs, 0);
    });

    test('拉丁按空白分词、空白附于前词', () {
      final f = synthesizeSweepFragments('Hello world', 0, 3000)!;
      expect(f.map((e) => e.text).join(), 'Hello world');
      expect(f.map((e) => e.text).toList(), ['Hello ', 'world']);
      // 权重 5:5 → 各占一半估算时长（1200ms）。
      expect(f[0].durationMs, 1200);
      expect(f[1].durationMs, 1200);
    });

    test('中英混排：CJK 逐字、拉丁成词，拼接不乱', () {
      final f = synthesizeSweepFragments('Hello 世界 world', 0, 10000)!;
      expect(f.map((e) => e.text).join(), 'Hello 世界 world');
      expect(f.map((e) => e.text).toList(), ['Hello ', '世', '界 ', 'world']);
    });

    test('窗口远长于估算 → 扫亮在估算时长内完成；窗口短 → 按窗口扫完', () {
      // 超长窗口：估算钳制到上限（总权重 × 240，上限 10000）。
      final long = synthesizeSweepFragments('短', 0, 20000)!;
      expect(long.single.durationMs, kSyntheticSweepMinMs);
      // 短窗口：整体不超过窗口。
      final short = synthesizeSweepFragments('AABB', 0, 400)!;
      expect(
        short.last.startMs + short.last.durationMs!,
        lessThanOrEqualTo(400),
      );
    });

    test('空文本 / 非正窗口返回 null', () {
      expect(synthesizeSweepFragments('', 0, 1000), isNull);
      expect(synthesizeSweepFragments('  ', 0, 1000), isNull);
      expect(synthesizeSweepFragments('abc', 1000, 1000), isNull);
      expect(synthesizeSweepFragments('abc', 2000, 1000), isNull);
    });
  });

  group('SyntheticSweepProcessor', () {
    const pipeline = LyricPipeline([SyntheticSweepProcessor()]);

    test('无逐字歌词 + 翻译 / 音译都被补齐', () {
      final out = pipeline.process(
        [
          LyricGroup(
            original: const LyricLine(timeMs: 0, text: '你好世界'),
            translation: 'hello world',
            romaji: 'ni hao shi jie',
            endMs: 4000,
          ),
        ],
        const LyricProcessContext(),
      );
      final g = out.single;
      expect(g.fragments, isNotNull);
      expect(g.fragments!.map((e) => e.text).join(), '你好世界');
      expect(g.translationFragments, isNotNull);
      expect(g.translationFragments!.map((e) => e.text).join(), 'hello world');
      expect(g.romajiFragments, isNotNull);
      expect(g.romajiFragments!.map((e) => e.text).join(), 'ni hao shi jie');
    });

    test('已有真实逐字片段不被覆盖（原对象透传）', () {
      final withFrags = LyricGroup(
        original: const LyricLine(timeMs: 0, text: 'AB'),
        fragments: const [
          LyricFragment(text: 'A', startMs: 0, durationMs: 500),
          LyricFragment(text: 'B', startMs: 500, durationMs: 500),
        ],
        endMs: 1000,
      );
      final out = pipeline.process(
        [withFrags],
        const LyricProcessContext(),
      );
      expect(identical(out.single, withFrags), isTrue);
    });

    test('syntheticSweep=false 时不处理', () {
      final g = LyricGroup(
        original: const LyricLine(timeMs: 0, text: '你好'),
        translation: 'hi',
        endMs: 2000,
      );
      final out = pipeline.process(
        [g],
        const LyricProcessContext(syntheticSweep: false),
      );
      expect(out.single.fragments, isNull);
      expect(out.single.translationFragments, isNull);
    });

    test('末行无 endMs 时用默认窗口兜底', () {
      final out = pipeline.process(
        [LyricGroup(original: const LyricLine(timeMs: 1000, text: '尾行'))],
        const LyricProcessContext(),
      );
      expect(out.single.fragments, isNotNull);
    });
  });

  group('resolveWordAnim：合成片段不触发长音强调', () {
    test('同长度时长下，合成片段无辉光/缩放，真实片段有', () {
      final real = resolveWordAnim(
        text: '长',
        index: 0,
        count: 1,
        relStartMs: 0,
        durationMs: 2000,
        lineRelMs: 1000,
        fontSize: 18,
      );
      final synth = resolveWordAnim(
        text: '长',
        index: 0,
        count: 1,
        relStartMs: 0,
        durationMs: 2000,
        lineRelMs: 1000,
        fontSize: 18,
        synthetic: true,
      );
      expect(real.glowAlpha, greaterThan(0));
      expect(synth.glowAlpha, 0);
      expect(synth.scale, 1.0);
    });
  });
}

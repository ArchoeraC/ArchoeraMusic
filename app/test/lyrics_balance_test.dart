// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 普通歌词平衡换行回归：行数不变、各行长度均衡、逐字片段不丢时间轴。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/widgets/player/lyrics_view/lyrics_balance.dart';

const _style = TextStyle(fontSize: 14);
const _width = 14.0 * 10; // Ahem：每字 14px，一行 10 字。

LyricGroup groupOf(String text, {List<LyricFragment>? fragments}) => LyricGroup(
  original: LyricLine(timeMs: 0, text: text),
  fragments: fragments,
  endMs: 5000,
);

BalancedLyric balance(LyricGroup group) => balanceLyricLine(
  group,
  maxWidth: _width,
  style: _style,
  textScaler: TextScaler.noScaling,
);

void main() {
  test('自然折行不均衡时重新分配断点，且行数不变', () {
    // 15 字 / 每行 10 字：自然折行是 10 + 5，平衡后应为 7 + 8（或 8 + 7）。
    final group = groupOf('一二三四五六七八九十一二三四五');
    final result = balance(group);

    expect(result.balanced, isTrue);
    final lines = result.text.split('\n');
    expect(lines, hasLength(2));
    expect(lines.map((e) => e.length).toList(), [7, 8]);
    expect(lines.every((e) => e.length <= 10), isTrue);
  });

  test('本来就放得下一行时不改动', () {
    final group = groupOf('一二三四五');
    final result = balance(group);
    expect(result.balanced, isFalse);
    expect(result.text, '一二三四五');
  });

  test('拉丁按词切分，不在单词内部断行', () {
    final group = groupOf('hello world archoera music player');
    final result = balance(group);
    expect(result.balanced, isTrue);
    // 断点只发生在单词之间：把换行还原成空格后与原词序列一致。
    expect(
      result.text.replaceAll('\n', ' ').split(RegExp(r'\s+')),
      group.original.text.split(' '),
    );
    for (final line in result.text.split('\n')) {
      expect(line.trim(), isNotEmpty);
    }
  });

  test('逐字行只在片段之间插入换行，不丢时间轴', () {
    final fragments = <LyricFragment>[
      for (var i = 0; i < 15; i++)
        LyricFragment(
          text: '一二三四五六七八九十一二三四五'[i],
          startMs: i * 200,
          durationMs: 200,
        ),
    ];
    final group = groupOf(
      fragments.map((f) => f.text).join(),
      fragments: fragments,
    );
    final result = balance(group);

    expect(result.balanced, isTrue);
    expect(result.fragments, isNotNull);
    final out = result.fragments!;
    expect(out.where((f) => f.text == '\n'), hasLength(1));
    // 原始 15 个字的起始时间都保留（换行片段除外）。
    final starts = [
      for (final f in out)
        if (f.text != '\n') f.startMs,
    ];
    expect(starts, [for (var i = 0; i < 15; i++) i * 200]);
    expect(result.text.split('\n').map((e) => e.length), [7, 8]);
  });

  test('显式换行的歌词不参与平衡', () {
    final group = groupOf('一二三四五六七八九十\n二三四五');
    final result = balance(group);
    expect(result.balanced, isFalse);
    expect(result.text, group.original.text);
  });
}

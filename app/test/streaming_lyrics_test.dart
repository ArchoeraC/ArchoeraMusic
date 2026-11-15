// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体逐字歌词归一化：服务端可能给传统 YRC、新版 YRC、QRC 或
/// `[ms,dur]` 行头；归一化后必须能被现有歌词引擎解析。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/lyrics/sources/streaming_lyric_source.dart';
import 'package:archoera_music/services/streaming/songloft/songloft_client.dart';

void main() {
  test('逐字格式识别：新版 YRC 不能被误判为 QRC', () {
    expect(detectStreamingLyricFormat('[0,2000](0,1000,0)晴(1000,1000,0)天'), 'yrc');
    expect(detectStreamingLyricFormat('[0,2000]晴(0,1000)天(1000,1000)'), 'qrc');
    expect(detectStreamingLyricFormat('[00:00.000]<0,1000>晴<1000,1000>天'), 'yrc');
    expect(detectStreamingLyricFormat('[00:00.000]普通歌词'), isNull);
  });
  test('传统 YRC 原样交给引擎', () {
    const raw = '[00:00.000]<0,1000>晴<1000,1000>天';
    final out = normalizeStreamingWordLyric(raw, 'yrc')!;
    expect(out.format, 'yrc');
    expect(out.content, raw);
    final groups = parseLyricGroups(content: out.content, format: out.format);
    expect(groups.single.original.text, '晴天');
  });

  test('新版 YRC（[ms,dur](start,dur,flag)字）转传统 YRC', () {
    const raw = '[1200,2000](1200,800,0)晴(2000,1200,0)天';
    final out = normalizeStreamingWordLyric(raw, 'yrc')!;
    expect(out.format, 'yrc');
    final groups = parseLyricGroups(content: out.content, format: out.format);
    expect(groups.single.original.timeMs, 1200);
    expect(groups.single.original.text, '晴天');
    expect(groups.single.fragments?.map((f) => f.text).join(), '晴天');
  });

  test('非标准 [ms,dur] 行头 + <rel,dur> 字级：只重写行头', () {
    const raw = '[0,2000]<0,1000>晴<1000,1000>天';
    final out = normalizeStreamingWordLyric(raw, 'yrc')!;
    expect(out.content, startsWith('[00:00.000]<0,1000>晴'));
    final groups = parseLyricGroups(content: out.content, format: out.format);
    expect(groups.single.original.text, '晴天');
  });

  test('QRC 原样返回，引擎按 qrc 归一化', () {
    const raw = '[0,2000]晴(0,1000)天(1000,1000)';
    final out = normalizeStreamingWordLyric(raw, 'qrc')!;
    expect(out.format, 'qrc');
    expect(out.content, raw);
    final groups = parseLyricGroups(content: out.content, format: out.format);
    expect(groups.single.original.text, '晴天');
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 内置广告清洗（全音源）：判定 + 歌词管线过滤。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/lyrics/ad_filter.dart';
import 'package:archoera_music/services/lyrics/engine/lyric_pipeline.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';

void main() {
  test('isAdMetadataText：命中站点推广，放过正规歌词', () {
    expect(isAdMetadataText('资源来自Neko云音乐 Resources from Neko Cloud Music'), isTrue);
    expect(isAdMetadataText('获取更多无损音乐https://music.cnmsb.xin/'), isTrue);
    expect(isAdMetadataText('更多免费无损音乐就来Neko云音乐'), isTrue);
    expect(isAdMetadataText('关注公众号：xxx'), isTrue);
    expect(isAdMetadataText('[00:12.34]晴天'), isFalse);
    expect(isAdMetadataText('故事的小黄花'), isFalse);
    expect(isAdMetadataText(''), isFalse);
  });

  test('AdLyricProcessor：删除广告行，保留正文（强内置，无需开关）', () {
    final groups = [
      LyricGroup(
        original: LyricLine(
          timeMs: 50,
          text: '资源来自Neko云音乐 Resources from Neko Cloud Music',
        ),
      ),
      LyricGroup(
        original: LyricLine(
          timeMs: 100,
          text: '获取更多无损音乐https://music.cnmsb.xin/',
        ),
      ),
      LyricGroup(original: LyricLine(timeMs: 12340, text: '故事的小黄花')),
      LyricGroup(original: LyricLine(timeMs: 15000, text: '从出生那年就飘着')),
    ];
    final out = LyricPipeline.standard.process(
      groups,
      const LyricProcessContext(),
    );
    expect(
      out.map((g) => g.original.text).toList(),
      ['故事的小黄花', '从出生那年就飘着'],
    );
    // 时间戳/其余字段保留
    expect(out.first.original.timeMs, 12340);
  });
}

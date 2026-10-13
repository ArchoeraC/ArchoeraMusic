// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词命中**行内片段**纯策略层单测（无 FFI / 无 DB / 无 Flutter widget）。
///
/// 覆盖：
/// - 空查询 / 空行 → 不读歌词（零成本）；
/// - 元数据（标题 / 歌手 / 专辑）有字面高亮 → 不读歌词、无片段；
/// - 元数据无字面高亮且歌词字面命中 → 生成 snippet（含命中串）；
/// - 拼音 / 首字母命中（拉丁查询 + 汉字歌词）无字面片段 → 不出现（边界）；
/// - 每页行数上限。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/scanner/tracks_db.dart';
import 'package:archoera_music/services/search/search_lyric_snippet.dart';

TrackRow _row({
  required String id,
  String title = 'Title',
  List<String> artists = const ['Artist'],
  String? album,
}) => TrackRow(
  id: id,
  path: '/m/$id.mp3',
  title: title,
  track: null,
  artistNames: artists,
  albumName: album,
  albumYear: null,
  durationMs: 1000,
  cover: null,
  codec: null,
  sampleRate: null,
  bitRate: null,
  channels: null,
  bitsPerSample: null,
  fileSize: 0,
  fileMtime: 0,
  lyrics: null,
);

/// 记录每次读取请求的歌词替身。
class _Lyrics {
  _Lyrics(this.data);
  final Map<String, String> data;
  final List<List<String>> calls = [];

  Map<String, String> load(List<String> ids) {
    calls.add(ids);
    return {
      for (final id in ids)
        if (data[id] != null) id: data[id]!,
    };
  }
}

void main() {
  test('空查询 / 空行：不读歌词，返回空映射', () {
    final lyrics = _Lyrics({'1': '我爱你中国'});
    expect(
      buildLyricSnippets(
        [_row(id: '1')],
        '   ',
        loadLyrics: lyrics.load,
      ),
      isEmpty,
    );
    expect(
      buildLyricSnippets(const [], '中国', loadLyrics: lyrics.load),
      isEmpty,
    );
    expect(lyrics.calls, isEmpty, reason: '空查询 / 空行必须零成本，不读歌词');
  });

  test('元数据（标题 / 歌手 / 专辑）有字面高亮：不读歌词、无片段', () {
    final lyrics = _Lyrics({'1': '我爱你中国'});
    final rows = [
      _row(id: '1', title: '中国话'),
      _row(id: '2', artists: ['中国风']),
      _row(id: '3', album: '中国'),
    ];
    final out = buildLyricSnippets(rows, '中国', loadLyrics: lyrics.load);
    expect(out, isEmpty);
    expect(lyrics.calls, isEmpty, reason: '元数据已命中：无需读歌词');
  });

  test('元数据无字面高亮且歌词字面命中：生成含命中串的片段', () {
    final lyrics = _Lyrics({'1': '我们都有一个家名字叫中国'});
    final out = buildLyricSnippets(
      [_row(id: '1', title: 'Nihao', album: 'World')],
      '中国',
      loadLyrics: lyrics.load,
      radius: 3,
    );
    expect(out.keys, ['1']);
    expect(out['1'], contains('中国'));
    expect(out['1'], startsWith('…'));
    expect(lyrics.calls, [
      ['1'],
    ]);
  });

  test('歌词无字面命中（拼音查询）→ 无片段（边界：拼音命中无字面区间）', () {
    final lyrics = _Lyrics({'1': '我爱你中国'});
    final out = buildLyricSnippets(
      [_row(id: '1', title: 'Nihao')],
      'woai', // 拼音命中歌词，但无字面区间
      loadLyrics: lyrics.load,
    );
    expect(out, isEmpty);
    expect(lyrics.calls, hasLength(1), reason: '仍会读歌词，但 snippet 为 null');
  });

  test('每页行数上限：超过 maxRows 只处理前 maxRows 行', () {
    final lyrics = _Lyrics({
      for (var i = 0; i < 10; i++) '$i': '字字字 中国 字字字',
    });
    final rows = [for (var i = 0; i < 10; i++) _row(id: '$i')];
    final out = buildLyricSnippets(
      rows,
      '中国',
      loadLyrics: lyrics.load,
      maxRows: 3,
    );
    expect(out.keys.toSet(), {'0', '1', '2'});
    expect(lyrics.calls.single, ['0', '1', '2']);
  });
}

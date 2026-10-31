// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 视频源（B 站）歌词跨平台补全：标题清洗 + 候选匹配放宽。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/lyric/types.dart';
import 'package:archoera_music/apis/lyric/utils.dart';
import 'package:archoera_music/services/netease/track.dart';

Track _bili(String title, {String artist = '某UP主', int duration = 0}) => Track(
  id: 'BV1Cjxy68EKv',
  title: title,
  source: 'bilibili',
  duration: duration,
  artists: [TrackArtist(name: artist)],
);

LyricCandidate<Map<String, String>> _candidate(
  String name, {
  String artist = '',
  int? duration,
}) => LyricCandidate(
  name: name,
  artist: artist,
  duration: duration,
  extra: const {},
);

void main() {
  group('bilibiliLyricTitle', () {
    test('优先取《…》里的歌名', () {
      expect(bilibiliLyricTitle('【原创曲】为女则刚！原创歌曲《女也》完整版来了'), '女也');
      expect(bilibiliLyricTitle('【4K修复】《晴天》官方MV'), '晴天');
      expect(bilibiliLyricTitle('《电影名》主题曲《歌名》'), '歌名');
    });

    test('没有书名号时清理包装与修饰词', () {
      expect(bilibiliLyricTitle('【MV】七里香（完整版）'), '七里香');
      expect(bilibiliLyricTitle('【高音质】夜曲 官方MV'), '夜曲');
      expect(bilibiliLyricTitle('[4K] 稻香 1080P'), '稻香');
      expect(bilibiliLyricTitle('  - 晴天 -  '), '晴天');
    });

    test('非视频源保持原曲名', () {
      final track = Track(id: '1', title: '【测试】歌名', source: 'netease');
      expect(lyricSearchTitle(track), '【测试】歌名');
    });
  });

  group('视频源歌词关键词', () {
    test('只取清洗后的歌名，不拼 UP 主名', () {
      expect(buildLyricSearchKeyword(_bili('【原创】《女也》完整版')), '女也');
    });

    test('普通源仍拼曲名 + 歌手', () {
      const track = Track(
        id: '1',
        title: '晴天',
        source: 'netease',
        artists: [TrackArtist(name: '周杰伦')],
      );
      expect(buildLyricSearchKeyword(track), '晴天 周杰伦');
    });
  });

  group('视频源候选匹配', () {
    test('UP 主不是演唱者时仍可按歌名命中', () {
      final best = pickBestCandidate([
        _candidate('女也', artist: '楼亭君', duration: 300000),
        _candidate('别的歌', artist: '楼亭君', duration: 300000),
      ], _bili('《女也》完整版', duration: 300000));
      expect(best?.name, '女也');
    });

    test('同名但时长相差过大仍被丢弃', () {
      final best = pickBestCandidate([
        _candidate('女也', artist: '别人', duration: 90000),
      ], _bili('《女也》', duration: 300000));
      expect(best, isNull);
    });

    test('歌手命中时优先选更匹配的候选', () {
      final best = pickBestCandidate([
        _candidate('女也', artist: '别人', duration: 300000),
        _candidate('女也', artist: '楼亭君', duration: 300000),
      ], _bili('《女也》', artist: '楼亭君', duration: 300000));
      expect(best?.artist, '楼亭君');
    });
  });
}

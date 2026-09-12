// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Fuck DJ Mode 识别单元测试。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/dj_mode.dart';

Track _t(String title, {String artist = 'X', String? album}) => Track(
  id: '1',
  title: title,
  artists: [TrackArtist(name: artist)],
  album: album == null ? null : TrackAlbum(name: album),
);

void main() {
  group('shouldSkipDjTrack 基础关键词（始终生效）', () {
    test('DJ / 中文 / 版本号', () {
      expect(shouldSkipDjTrack(_t('DJ版')), isTrue);
      expect(shouldSkipDjTrack(_t('My DJ')), isTrue);
      expect(shouldSkipDjTrack(_t('晴天 (抖音热歌)')), isTrue);
      expect(shouldSkipDjTrack(_t('慢摇串烧')), isTrue);
      expect(shouldSkipDjTrack(_t('Song 0.8x')), isTrue);
      expect(shouldSkipDjTrack(_t('Song (0.9)')), isTrue);
    });

    test('增强词默认不生效', () {
      expect(shouldSkipDjTrack(_t('Song (Remix)')), isFalse);
      expect(shouldSkipDjTrack(_t('Nightcore - Song')), isFalse);
      expect(shouldSkipDjTrack(_t('喊麦之王')), isFalse);
      expect(shouldSkipDjTrack(_t('Bounce Track')), isFalse);
      expect(shouldSkipDjTrack(_t('Hardstyle Anthem')), isFalse);
      expect(shouldSkipDjTrack(_t('Song (Mix)')), isFalse);
    });
  });

  group('shouldSkipDjTrack 增强关键词（enhanced）', () {
    test('ASCII 增强词', () {
      expect(shouldSkipDjTrack(_t('Song (Remix)'), enhanced: true), isTrue);
      expect(
        shouldSkipDjTrack(_t('Song (Club Mix)'), enhanced: true),
        isTrue,
      );
      expect(
        shouldSkipDjTrack(_t('Nightcore - Song'), enhanced: true),
        isTrue,
      );
      expect(
        shouldSkipDjTrack(_t('Song (Sped Up)'), enhanced: true),
        isTrue,
      );
      expect(shouldSkipDjTrack(_t('Bounce Track'), enhanced: true), isTrue);
      expect(
        shouldSkipDjTrack(_t('Hardstyle Anthem'), enhanced: true),
        isTrue,
      );
    });

    test('中文增强词', () {
      expect(shouldSkipDjTrack(_t('喊麦之王'), enhanced: true), isTrue);
      expect(shouldSkipDjTrack(_t('电音串烧'), enhanced: true), isTrue);
      expect(shouldSkipDjTrack(_t('车载口水歌'), enhanced: true), isTrue);
    });
  });

  group('shouldSkipDjTrack 自定义关键词', () {
    test('逗号 / 分号 / 换行分隔', () {
      expect(shouldSkipDjTrack(_t('My Cover Song'), custom: 'cover'), isTrue);
      expect(
        shouldSkipDjTrack(_t('Song (伴奏)'), custom: '翻唱，伴奏'),
        isTrue,
      );
      expect(
        shouldSkipDjTrack(_t('Karaoke Night'), custom: 'cover;karaoke'),
        isTrue,
      );
      expect(shouldSkipDjTrack(_t('普通歌曲'), custom: 'cover, karaoke'), isFalse);
    });
  });

  group('shouldSkipDjTrack 不误伤', () {
    test('含 dj 的普通词 / 正常数字', () {
      expect(shouldSkipDjTrack(_t('Adjust'), enhanced: true), isFalse);
      expect(shouldSkipDjTrack(_t('Adjacent'), enhanced: true), isFalse);
      expect(shouldSkipDjTrack(_t('Version 10.8'), enhanced: true), isFalse);
      expect(shouldSkipDjTrack(_t('普通歌曲'), enhanced: true), isFalse);
    });

    test('歌手 / 专辑也参与判定', () {
      expect(shouldSkipDjTrack(_t('Song', artist: 'DJ Mike')), isTrue);
      expect(
        shouldSkipDjTrack(_t('Song', album: '车载大碟'), enhanced: true),
        isTrue,
      );
    });
  });
}

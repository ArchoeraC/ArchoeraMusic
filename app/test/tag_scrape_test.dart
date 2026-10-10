// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 单曲在线刮削纯逻辑单测（`services/scraper/tag_editor_service.dart`）。
///
/// 覆盖：刮削选项 → 原生 config JSON 映射（含 workers 省略 / 数据源与
/// 封面歌词开关）、刮削结果 JSON → [ScrapedTrack] 映射（字段 / 封面 base64
/// 解码 / 损坏 base64 / sources / 缺字段容错）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/scraper/tag_editor_service.dart';

void main() {
  group('TrackScrapeOptions.toJson', () {
    test('默认全开且省略 workers', () {
      final json = const TrackScrapeOptions().toJson();
      expect(json['useMusicBrainz'], isTrue);
      expect(json['useDeezer'], isTrue);
      expect(json['useItunes'], isTrue);
      expect(json['useNetease'], isTrue);
      expect(json['useQQMusic'], isTrue);
      expect(json['useKugou'], isTrue);
      expect(json['useKuwo'], isTrue);
      expect(json['useMigu'], isTrue);
      expect(json['useAcoustID'], isTrue);
      expect(json['embedMetadata'], isTrue);
      expect(json['embedCover'], isTrue);
      expect(json['embedLyrics'], isTrue);
      expect(json.containsKey('concurrentWorkers'), isFalse);
    });

    test('按开关映射并在 workers > 0 时带入并发数', () {
      final json = const TrackScrapeOptions(
        musicBrainz: false,
        netease: false,
        acoustId: false,
        fetchCover: false,
        fetchLyrics: false,
        workers: 4,
      ).toJson();
      expect(json['useMusicBrainz'], isFalse);
      expect(json['useNetease'], isFalse);
      expect(json['useAcoustID'], isFalse);
      expect(json['useDeezer'], isTrue);
      expect(json['embedCover'], isFalse);
      expect(json['embedLyrics'], isFalse);
      expect(json['concurrentWorkers'], 4);
    });
  });

  group('ScrapedTrack.fromJson', () {
    test('完整字段 + 封面 base64 + sources', () {
      final cover = base64Encode([1, 2, 3, 4]);
      final r = ScrapedTrack.fromJson({
        'found': true,
        'title': 'Title',
        'artist': 'Artist',
        'album': 'Album',
        'albumArtist': 'Album Artist',
        'composer': 'Composer',
        'genre': 'Rock',
        'lyrics': '[00:00] hi',
        'coverMime': 'image/jpeg',
        'coverBase64': cover,
        'trackNumber': 3,
        'discNumber': 1,
        'year': 2024,
        'sources': ['musicbrainz', 'netease', ''],
      });
      expect(r.found, isTrue);
      expect(r.title, 'Title');
      expect(r.artist, 'Artist');
      expect(r.album, 'Album');
      expect(r.albumArtist, 'Album Artist');
      expect(r.composer, 'Composer');
      expect(r.genre, 'Rock');
      expect(r.lyrics, '[00:00] hi');
      expect(r.coverMime, 'image/jpeg');
      expect(r.coverBytes, [1, 2, 3, 4]);
      expect(r.trackNumber, 3);
      expect(r.discNumber, 1);
      expect(r.year, 2024);
      expect(r.sources, ['musicbrainz', 'netease']);
    });

    test('缺字段容错：found 假、无封面、空 sources', () {
      final r = ScrapedTrack.fromJson(const {});
      expect(r.found, isFalse);
      expect(r.title, '');
      expect(r.coverBytes, isNull);
      expect(r.trackNumber, 0);
      expect(r.sources, isEmpty);
    });

    test('损坏的封面 base64 按无封面处理', () {
      final r = ScrapedTrack.fromJson(const {
        'found': true,
        'title': 'T',
        'coverBase64': '***not-base64***',
      });
      expect(r.coverBytes, isNull);
      expect(r.title, 'T');
    });

    test('数字可为字符串（容错）', () {
      final r = ScrapedTrack.fromJson(const {
        'found': true,
        'trackNumber': '7',
        'discNumber': 2,
        'year': '1999',
      });
      expect(r.trackNumber, 7);
      expect(r.discNumber, 2);
      expect(r.year, 1999);
    });
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/downloader/download_platform.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/source/media_request_headers.dart';
import 'package:archoera_music/services/source/source_platform.dart';
import 'package:archoera_music/widgets/dialogs/collection_platform.dart';

void main() {
  group('Bilibili 注册表', () {
    test('SourcePlatform 能力位', () {
      final platform = sourcePlatform('bilibili');
      expect(platform.source, 'bilibili');
      expect(platform.searchable, isTrue);
      expect(platform.supportsCoverSearch, isFalse);
      expect(platform.inAggregate, isFalse);
      expect(platform.downloadable, isTrue);
      expect(platform.downloadRequiresLogin, isTrue);
      expect(platform.trackMenuArtistDownload, isTrue);
      expect(platform.trackMenuArtist, isFalse);
      expect(platform.trackMenuDetail, isTrue);
      expect(platform.trackMenuLikeComment, isFalse);
      expect(platform.trackMenuComment, isTrue);
      expect(platform.comments?.source, 'bilibili');
      expect(platform.supportedQualities, const [
        'lq',
        'sq',
        'hq',
        'lossless',
        'hi-res',
      ]);
      expect(platform.mediaHeaders['Referer'], 'https://www.bilibili.com/');
    });

    test('B 站没有收藏 / 播放列表适配器，禁止回退写入 NT', () {
      expect(sourcePlatform('bilibili').collections, isNull);
      expect(sourceSupportsLike('bilibili'), isFalse);
      expect(sourceSupportsComment('bilibili'), isTrue);
      expect(hasCollectionAdapter('bilibili'), isFalse);
      // 回退仍存在，但写操作必须先经 hasCollectionAdapter 判断。
      expect(collectionPlatform('bilibili').source, 'netease');
      expect(hasCollectionAdapter('netease'), isTrue);
    });

    test('DownloadPlatform 落盘为 m4a', () {
      final platform = downloadPlatform('bilibili');
      expect(platform.nativeResolver, isTrue);
      expect(platform.playbackFallback, isTrue);
      expect(platform.supportedQualities, const [
        'lq',
        'sq',
        'hq',
        'lossless',
        'hi-res',
      ]);
      const track = Track(id: 'BV1Cjxy68EKv:1', title: 'x', source: 'bilibili');
      expect(platform.fileExtensionOverride(track, 'hq'), 'm4a');
      expect(platform.qualityKey('hq', 'm4a'), 'aac');
      expect(platform.qualityKey('lossless', 'm4a'), 'flac');
      final headers = platform.requestHeaders(track, 'hq');
      expect(headers, contains(const ['Referer', 'https://www.bilibili.com/']));
    });

    test('Track JSON 保留 bvid/cid', () {
      const track = Track(
        id: 'BV1Cjxy68EKv:123',
        title: '视频',
        source: 'bilibili',
        bilibili: BilibiliTrackInfo(
          bvid: 'BV1Cjxy68EKv',
          cid: '123',
          pageTitle: 'P1',
        ),
      );
      final restored = Track.fromJson(track.toJson());
      expect(restored.bilibili?.bvid, 'BV1Cjxy68EKv');
      expect(restored.bilibili?.cid, '123');
      expect(restored.bilibili?.pageTitle, 'P1');
    });

    test('B 站图片带 Referer/UA', () {
      final headers = mediaHeadersForUrl(
        'https://i0.hdslb.com/bfs/archive/example.jpg',
      );
      expect(headers?['Referer'], 'https://www.bilibili.com/');
      expect(headers?['User-Agent'], isNotEmpty);
    });
  });
}

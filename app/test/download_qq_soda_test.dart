// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 下载请求构造：QQMusic / 汽水来源接入（离线）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/downloader/download_controller.dart';
import 'package:archoera_music/services/netease/track.dart';

void main() {
  test('QQMusic：source/platformId/quality 透传', () {
    const track = Track(
      id: '97773',
      title: '晴天',
      source: 'qqmusic',
      artists: [TrackArtist(name: '周杰伦')],
    );
    final req = buildDownloadRequest(track, quality: 'lossless');
    expect(req['source'], 'qqmusic');
    expect(req['platformId'], '97773');
    expect(req['trackId'], '97773');
    expect(req['quality'], 'lossless');
    expect(req['title'], '晴天');
    expect(req['artist'], '周杰伦');
    expect(req['extra'], isEmpty);
  });

  test('汽水：source 透传，extra 为空', () {
    const track = Track(
      id: '7678897838486882344',
      title: '晴天（杰伦）',
      source: 'soda',
    );
    final req = buildDownloadRequest(track);
    expect(req['source'], 'soda');
    expect(req['platformId'], '7678897838486882344');
    expect(req['extra'], isEmpty);
  });

  test('kugou 仍带 hashes/sizes extra', () {
    const track = Track(
      id: 'abc',
      title: 't',
      source: 'kugou',
      kugou: KugouTrackInfo(hash: 'H', sizes: {'320k': 1}),
    );
    final req = buildDownloadRequest(track);
    expect(req['source'], 'kugou');
    expect((req['extra'] as Map)['sizes'], isNotNull);
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 下载请求构造：QQMusic 来源接入（离线）。
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

  test('neko：携带标准 LRC 歌词（强制重写）；无歌词时该字段为 null', () {
    const withLyrics = Track(
      id: '33814',
      title: '三拜红尘凉',
      source: 'neko',
      artists: [TrackArtist(name: '尹昔眠')],
      lyrics: '[00:01.00]标准歌词',
    );
    final req = buildDownloadRequest(withLyrics);
    expect(req['source'], 'neko');
    expect(req['lyrics'], '[00:01.00]标准歌词');

    const noLyrics = Track(id: '1', title: 't', source: 'neko');
    expect(buildDownloadRequest(noLyrics)['lyrics'], isNull);
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

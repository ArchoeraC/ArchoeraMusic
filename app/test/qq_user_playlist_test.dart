// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 用户歌单 / 收藏（fcgi GET）单测（不联网，注入 fake 传输）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/qqmusic/core/request.dart';
import 'package:archoera_music/apis/qqmusic/modules/user_playlist.dart';
import 'package:archoera_music/services/netease/track.dart';

void main() {
  late QmHttpGetTransport original;

  setUp(() {
    original = qmHttpGetTransport;
    // 未登录 → 各模块返回 301。
  });

  tearDown(() {
    qmHttpGetTransport = original;
  });

  test('未登录：user_created_diss / profile_order_* 返回 301', () async {
    qmHttpGetTransport = (uri, {extraHeaders}) async => const {};
    expect((await qmUserCreatedDiss(const {})) as Map, containsPair('code', 301));
    expect(
      (await qmProfileOrderPlaylists(const {})) as Map,
      containsPair('code', 301),
    );
    expect(
      (await qmProfileOrderSongs(const {})) as Map,
      containsPair('code', 301),
    );
  });

  test('QQ 封面：优先 song[cover]，否则由 albumMid 现算', () {
    final withCover = Track.fromQqMusicSong({
      'id': '1',
      'mid': 'm1',
      'name': 'n',
      'albumMid': 'AM',
      'cover': 'https://y.gtimg.cn/music/photo_new/T002R300x300M000PMID.jpg',
    });
    expect(withCover.cover, contains('PMID'));

    final fromMid = Track.fromQqMusicSong({
      'id': '2',
      'mid': 'm2',
      'name': 'n2',
      'albumMid': 'AM2',
    });
    expect(fromMid.cover, contains('AM2'));
  });
}

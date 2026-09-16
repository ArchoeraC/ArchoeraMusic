// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 用户歌单 / 收藏（fcgi GET）单测（不联网，注入 fake 传输）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/qqmusic/core/config.dart';
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
    expect(
      (await qmUserCreatedDiss(const {})) as Map,
      containsPair('code', 301),
    );
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

  test('qmNormalizeCover：协议相对 / http 统一升级 https', () {
    expect(
      qmNormalizeCover('//qpic.y.qq.com/a.jpg'),
      'https://qpic.y.qq.com/a.jpg',
    );
    expect(
      qmNormalizeCover('http://y.gtimg.cn/b.jpg'),
      'https://y.gtimg.cn/b.jpg',
    );
    expect(qmNormalizeCover('https://x/y.jpg'), 'https://x/y.jpg');
    expect(qmNormalizeCover('  '), '');
    expect(qmNormalizeCover(null), '');
  });

  group('QM 收藏歌单封面（已登录 + fake 传输）', () {
    setUp(() {
      qmMergeQQMusicCookies({'qm_keyst': 'k', 'qm_str_musicid': '12345'});
      qmHttpGetTransport = (uri, {extraHeaders}) async {
        if (uri.path.contains('fcg_user_created_diss')) {
          return {
            'code': 0,
            'data': {
              'list': [
                {
                  'dissid': 42,
                  'dissname': '旧接口歌单',
                  'imgurl': '//qpic.y.qq.com/old.jpg',
                  'song_count': 3,
                },
              ],
            },
          };
        }
        if (uri.path.contains('fcg_get_profile_order_asset')) {
          if (uri.queryParameters['reqtype'] == '1') {
            return {
              'code': 0,
              'data': {
                'totalsong': 1,
                'songlist': [
                  {
                    'data': {
                      'songmid': 'mid1',
                      'songid': 1,
                      'songname': '收藏曲',
                      'albummid': 'AM',
                      'interval': 200,
                    },
                  },
                ],
              },
            };
          }
          return {
            'code': 0,
            'data': {
              'cdlist': [
                {
                  'dissid': 99,
                  'dissname': '收藏歌单',
                  'songnum': 5,
                  'listennum': 1,
                  'logo': '//qpic.y.qq.com/logo.jpg',
                  'nickname': '某人',
                },
              ],
            },
          };
        }
        return const {};
      };
    });

    tearDown(qmClearQQMusicCookies);

    test('收藏歌单封面 logo 归一为 https', () async {
      final body = await qmProfileOrderPlaylists({'limit': 10}) as Map;
      final first = (body['playlists'] as List).first as Map;
      expect(first['cover'], 'https://qpic.y.qq.com/logo.jpg');
    });

    test('自建歌单兼容旧 list 数组（imgurl）并归一封面', () async {
      final body = await qmUserCreatedDiss({'limit': 10}) as Map;
      final first = (body['playlists'] as List).first as Map;
      expect(first['cover'], 'https://qpic.y.qq.com/old.jpg');
      expect(first['name'], '旧接口歌单');
    });

    test('profile_order_songs duration 归一为毫秒', () async {
      final body = await qmProfileOrderSongs({'num': 10}) as Map;
      final first = (body['songs'] as List).first as Map;
      expect(first['duration'], 200 * 1000);
    });
  });
}

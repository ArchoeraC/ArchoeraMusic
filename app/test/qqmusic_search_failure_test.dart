// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQ 搜索（签名桌面协议）单测（**不联网**，注入 fake 传输）。
///
/// 覆盖：
/// - `qmZzcSign` 与独立实现向量对照；
/// - 请求形状：`musics.fcg?sign=` + `comm.ct=19` + `DoSearchForQQMusicDesktop`；
/// - 四类（单曲/歌手/专辑/歌单）`search_type` 与解析（含完整音质字段）；
/// - 错误归一：风控（`2001` / `meta.is_filter<0`）→ risk，业务码 → code，
///   传输错误 → transient 且**不自动重试**；
/// - 单页上限：`num_per_page` 收敛为 50（歌手 30）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/qqmusic/api.dart';
import 'package:archoera_music/apis/qqmusic/core/request.dart';
import 'package:archoera_music/apis/qqmusic/core/sign.dart';
import 'package:archoera_music/services/qqmusic/qqmusic_api.dart';

/// 桌面成功响应包装（node-key 与移动端 `request` 不同）。
Map<String, dynamic> _nodeOk(Map<String, dynamic> data) => {
  'code': 0,
  'music.search.SearchCgiService': {'code': 0, 'data': data},
};

/// 构造 `data`：`body.<key>.list` + `meta`。
Map<String, dynamic> _data(String key, List<Object> list, {int? sum}) => {
  'meta': {'sum': sum ?? list.length, 'is_filter': 0},
  'body': {
    key: {'list': list},
  },
};

/// 实测桌面单曲条目（含完整音质字段）。
Map<String, dynamic> _song() => {
  'id': 97773,
  'mid': '0039MnYb0qxYhV',
  'title': '晴天',
  'interval': 269,
  'singer': [
    {'id': 4558, 'mid': '003Nz2So3XXYek', 'name': '周杰伦'},
  ],
  'album': {'id': 8220, 'mid': '000MkMni19ClKG', 'name': '叶惠美'},
  'file': {
    'media_mid': '003Qui1q2u1Zho',
    'size_128mp3': 4317292,
    'size_320mp3': 10792943,
    'size_flac': 55397039,
    'size_192ogg': 5860576,
    'size_ape': 0,
    'size_new': [186980254, 31168013],
    'hires_sample': 96000,
    'hires_bitdepth': 24,
  },
  'pay': {'pay_play': 0, 'pay_month': 0, 'price_album': 0},
};

Map<String, dynamic> _album() => {
  'albumID': 87495226,
  'albumMID': '0041WVfh2vtlJE',
  'albumName': '太阳之子',
  'albumPic':
      'http://y.gtimg.cn/music/photo_new/T002R180x180M0000041WVfh2vtlJE_1.jpg',
  'singerMID': '0025NhlN2yWrP4',
  'singerName': '周杰伦',
  'singer_list': [
    {'id': 4558, 'mid': '0025NhlN2yWrP4', 'name': '周杰伦'},
  ],
  'song_count': 13,
};

Map<String, dynamic> _artist() => {
  'singerID': 4558,
  'singerMID': '0025NhlN2yWrP4',
  'singerName': '<em>周杰伦</em>',
  'singerPic':
      'http://y.gtimg.cn/music/photo_new/T001R150x150M0000025NhlN2yWrP4_11.jpg',
  'albumNum': 43,
  'songNum': 1012,
};

Map<String, dynamic> _playlist() => {
  'dissid': '7039749142',
  'dissname': '百听不厌的周杰伦',
  'imgurl': 'http://qpic.y.qq.com/music_cover/abc/300?n=1',
  'creator': {'name': '今晚月色很美'},
  'listennum': 411944869,
  'song_count': 99,
};

void main() {
  final api = QqMusicApi();
  late QmHttpTransport original;

  setUp(() {
    original = qmHttpTransport;
    qmClearCache();
  });

  tearDown(() => qmHttpTransport = original);

  group('qmZzcSign（独立实现向量对照）', () {
    test('与 baka qq.js:315 算法逐位一致', () {
      expect(
        qmZzcSign('zzc-sign-test-vector'),
        'zzc6f13ac4f6yhijjglgit0iit3ntggcepr1sae4144e4',
      );
      expect(
        qmZzcSign('{"comm":{"ct":"19"},"key":"zzc"}'),
        'zzc12693f47o1awwp9am4hva3yo8qklh51s35204376',
      );
      expect(
        qmZzcSign('DoSearchForQQMusicDesktop'),
        'zzc69858ccnofrgj9b1gy6ohf9mphfdguwkia8deec8e2',
      );
    });
  });

  group('请求形状', () {
    test('走 musics.fcg?sign + ct=19 + DoSearchForQQMusicDesktop', () async {
      Map<String, dynamic>? sent;
      String? sentUrl;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        sent = body;
        sentUrl = url;
        return _nodeOk(_data('song', <Object>[]));
      };

      await qmCall('search', {
        'keywords': '周杰伦',
        'page': 2,
        'limit': 50,
        'type': 0,
      });

      expect(
        sentUrl,
        startsWith('https://u.y.qq.com/cgi-bin/musics.fcg?sign=zzc'),
      );
      final comm = sent!['comm'] as Map;
      expect(comm['ct'], '19');
      expect(comm['cv'], '2151');
      final node = sent!['music.search.SearchCgiService'] as Map;
      expect(node['method'], 'DoSearchForQQMusicDesktop');
      final param = node['param'] as Map;
      expect(param['remoteplace'], 'txt.newclient.top');
      expect(param['search_type'], 0);
      expect(param['page_num'], 2);
      expect(param['num_per_page'], 50);
      expect(param['searchid'], matches(RegExp(r'^[0-9A-F]{32}[0-9]{5}$')));
    });

    test('四类 search_type 映射（0/1/2/3），num_per_page 收敛为 50', () async {
      final types = <int>[];
      final nums = <int>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        final node = body['music.search.SearchCgiService'] as Map;
        final param = node['param'] as Map;
        types.add(param['search_type'] as int);
        nums.add(param['num_per_page'] as int);
        return _nodeOk(_data('song', <Object>[]));
      };

      var i = 0;
      for (final t in [0, 1, 2, 3]) {
        await qmCall('search', {
          'keywords': 'x',
          'limit': 80,
          'type': t,
          'timestamp': i++,
        });
      }
      expect(types, [0, 1, 2, 3]);
      expect(nums, [50, 50, 50, 50]);
    });
  });

  group('四类解析', () {
    test('单曲 type0 → Track（含完整音质字段）', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async =>
          _nodeOk(_data('song', [_song()], sum: 999));

      final r = await api.searchSongs('晴天 周杰伦', page: 1, limit: 30);
      expect(r.items, hasLength(1));
      expect(r.items.first.title, '晴天');
      expect(r.items.first.source, 'qqmusic');
      expect(r.items.first.qqmusic!.mid, '0039MnYb0qxYhV');
      expect(r.items.first.qqmusic!.mediaMid, '003Qui1q2u1Zho');
      expect(r.total, 999);
      expect(r.hasMore, isTrue);
    });

    test('模块输出携带 sizeHiRes / hires_*', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async =>
          _nodeOk(_data('song', [_song()]));

      final body =
          await qmCall('search', {'keywords': 'x', 'limit': 30, 'type': 0})
              as Map;
      final s = (body['songs'] as List).first as Map;
      expect(s['sizeHiRes'], 186980254);
      expect(s['hiResSampleRate'], 96000);
      expect(s['hiResBitDepth'], 24);
      expect(s['size320'], 10792943);
      expect(s['sizeFlac'], 55397039);
    });

    test('歌手 type1 → CoverItem（去除 <em> 高亮）', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async =>
          _nodeOk(_data('singer', [_artist()], sum: 1));

      final r = await api.searchArtists('周杰伦', page: 1, limit: 50);
      expect(r.items, hasLength(1));
      expect(r.items.first.id, '0025NhlN2yWrP4');
      expect(r.items.first.title, '周杰伦');
      expect(r.items.first.cover, startsWith('https://y.gtimg.cn'));
      expect(r.items.first.source, 'qqmusic');
    });

    test('专辑 type2 → CoverItem', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async =>
          _nodeOk(_data('album', [_album()], sum: 820));

      final r = await api.searchAlbums('周杰伦', page: 1, limit: 50);
      expect(r.items, hasLength(1));
      expect(r.items.first.id, '87495226');
      expect(r.items.first.title, '太阳之子');
      expect(r.items.first.cover, startsWith('https://y.gtimg.cn'));
      expect(r.items.first.trackCount, 13);
      expect(r.total, 820);
    });

    test('歌单 type3 → CoverItem（creator / 曲目数）', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async =>
          _nodeOk(_data('songlist', [_playlist()], sum: 300));

      final r = await api.searchPlaylists('周杰伦', page: 1, limit: 50);
      expect(r.items, hasLength(1));
      expect(r.items.first.id, '7039749142');
      expect(r.items.first.title, '百听不厌的周杰伦');
      expect(r.items.first.subtitle, '今晚月色很美');
      expect(r.items.first.trackCount, 99);
      expect(r.total, 300);
    });
  });

  group('错误归一', () {
    test('node.code=2001 → risk（不自动重试，只发一次）', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        return {
          'code': 0,
          'music.search.SearchCgiService': {
            'code': 2001,
            'data': {'body': <String, Object>{}, 'meta': {'sum': 0}},
          },
        };
      };

      await expectLater(
        api.searchSongs('周杰伦'),
        throwsA(
          isA<QqApiException>()
              .having((e) => e.kind, 'kind', QmErrorKind.risk)
              .having((e) => e.innerCode, 'innerCode', 2001),
        ),
      );
      expect(calls, 1, reason: '风控错误不应重试（防刷高风控）');
    });

    test('code0 但 meta.is_filter<0（额外验证过滤为空）→ risk', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        return {
          'code': 0,
          'music.search.SearchCgiService': {
            'code': 0,
            'data': {
              'body': <String, Object>{},
              'meta': {'is_filter': -12, 'estimate_sum': 74266, 'sum': 0},
            },
          },
        };
      };

      await expectLater(
        api.searchSongs('周杰伦'),
        throwsA(
          isA<QqApiException>()
              .having((e) => e.kind, 'kind', QmErrorKind.risk)
              .having((e) => e.innerCode, 'innerCode', 2001),
        ),
      );
      expect(calls, 1);
    });

    test('普通非零业务码（node.code=700）→ code 错误', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async => {
        'code': 0,
        'music.search.SearchCgiService': {
          'code': 700,
          'data': {'body': <String, Object>{}, 'meta': {'sum': 0}},
        },
      };

      await expectLater(
        api.searchSongs('周杰伦'),
        throwsA(
          isA<QqApiException>()
              .having((e) => e.kind, 'kind', QmErrorKind.code)
              .having((e) => e.code, 'code', 700),
        ),
      );
    });

    test('传输级错误 → transient，退避重试 3 次', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        throw Exception('socket timeout');
      };

      await expectLater(
        api.searchSongs('周杰伦'),
        throwsA(
          isA<QqApiException>()
              .having((e) => e.kind, 'kind', QmErrorKind.transient),
        ),
      );
      expect(calls, 3, reason: '初次 + 2 次退避重试');
    });

    test('空关键词 → 空结果且不发起请求', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        return _nodeOk(_data('song', <Object>[]));
      };

      final r = await api.searchSongs('   ');
      expect(r.items, isEmpty);
      expect(r.total, 0);
      expect(calls, 0);
    });
  });

  group('评论', () {
    Map<String, dynamic> resp({int total = 2, bool hasMore = false}) => {
      'code': 0,
      'request': {
        'code': 0,
        'data': {
          'CommentList': {
            'Comments': [
              {
                'CmId': 'c1',
                'Nick': '梦醒',
                'Avatar': 'https://thirdqq.qlogo.cn/a.jpg',
                'Content': '好听',
                'PraiseNum': 12,
                'PubTime': '1700000000',
                'SubComments': [
                  {
                    'CmId': 'r1',
                    'Nick': '甲',
                    'Content': '同感',
                    'PraiseNum': 1,
                    'PubTime': '1700000001',
                  },
                ],
              },
            ],
            'Total': total,
            'HasMore': hasMore ? 1 : 0,
          },
        },
      },
    };

    test('songComments(hot) → 归一评论 + 方法/参数', () async {
      Map<String, dynamic>? sent;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        sent = body;
        return resp(total: 56, hasMore: true);
      };

      final page = await api.songComments(
        '0039MnYb0qxYhV',
        page: 2,
        limit: 10,
        hot: true,
      );
      final req = sent!['request'] as Map;
      expect(req['module'], 'music.globalComment.CommentRead');
      expect(req['method'], 'GetHotCommentList');
      final param = req['param'] as Map;
      expect(param['BizType'], 1);
      expect(param['BizId'], '0039MnYb0qxYhV');
      expect(param['PageNum'], 1);
      expect(param['PageSize'], 10);
      expect(param['HotType'], 1);

      expect(page.list, hasLength(1));
      final c = page.list.first;
      expect(c.id, 'c1');
      expect(c.userName, '梦醒');
      expect(c.text, '好听');
      expect(c.likedCount, 12);
      expect(c.time, 1700000000000);
      expect(c.reply, hasLength(1));
      expect(c.reply.first.text, '同感');
      expect(page.total, 56);
      expect(page.hasMore, isTrue);
    });

    test('songComments(new) → GetNewCommentList', () async {
      Map<String, dynamic>? sent;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        sent = body;
        return resp();
      };
      await api.songComments('0039MnYb0qxYhV');
      final req = sent!['request'] as Map;
      expect(req['method'], 'GetNewCommentList');
    });

    test('空 mid → 空页且不发起请求', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        return resp();
      };
      final page = await api.songComments('');
      expect(page.list, isEmpty);
      expect(calls, 0);
    });
  });
}

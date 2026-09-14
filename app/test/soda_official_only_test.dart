// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda）免登录 API 单测（**不联网**，注入 fake 传输）。
///
/// 覆盖：
/// - **官方域名硬校验**：非官方 host 直接拒绝、永不发起；
/// - 搜索（Android，三分类）、SEO 单曲（元数据 + KRC 歌词 + 取流 URL）、
///   `PlayInfo` 取流、PC 歌单详情、PC 专辑详情；
/// - 所有出站 host 均 ∈ 官方白名单（`api.qishui.com` / `beta-luna.douyin.com`
///   / `vod-luna.douyin.com`）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/soda/api.dart';
import 'package:archoera_music/apis/soda/core/config.dart';
import 'package:archoera_music/apis/soda/core/request.dart';

Map<String, dynamic> _cover() => {
  'uri': 'cover-uri',
  'template_prefix': 'p',
  'urls': ['https://p3-luna.douyinpic.com/img/cover-uri'],
};

Map<String, dynamic> _track({
  String id = '1001',
  String name = '晴天',
  bool vip = false,
}) => {
  'id': id,
  'name': name,
  'duration': 269000,
  'artists': [
    {'id': 'a1', 'name': '周杰伦'},
    {'id': 'a2', 'name': '方文山'},
  ],
  'album': {'id': 'al1', 'name': '叶惠美', 'url_cover': _cover()},
  'label_info': {'only_vip_playable': vip},
};

Map<String, dynamic> _searchResp(String key, List<Map<String, dynamic>> items) => {
  'status_info': {'log_id': 'x'},
  'result_groups': [
    {
      'data': items.map((e) => {'entity': {key: e}}).toList(),
    },
  ],
};

void main() {
  final hosts = <String>[];
  late SodaHttpTransport original;
  late void Function(Uri) capture;

  setUp(() {
    original = sodaHttpTransport;
    sodaClearCache();
    hosts.clear();
    capture = (Uri uri) => hosts.add(uri.host);
  });

  tearDown(() => sodaHttpTransport = original);

  group('官方域名硬校验', () {
    test('非官方 host 直接拒绝，且不调用传输', () {
      var called = false;
      sodaHttpTransport = (uri, {headers}) async {
        called = true;
        return <String, dynamic>{};
      };
      expect(
        () => sodaGetJson(Uri.parse('https://evil.example.com/luna')),
        throwsA(isA<SodaRequestException>()),
      );
      expect(called, isFalse);
    });
  });

  group('搜索（Android，三分类）', () {
    test('单曲：解析 id/时长/歌手/封面，出站仅 api.qishui.com', () async {
      sodaHttpTransport = (uri, {headers}) async {
        capture(uri);
        return _searchResp('track', [_track()]);
      };

      final body =
          await sodaCall('search', {'keywords': '晴天', 'type': 0}) as Map;
      final songs = body['songs'] as List;
      expect(songs, hasLength(1));
      final s = songs.first as Map;
      expect(s['id'], '1001');
      expect(s['name'], '晴天');
      expect(s['duration'], 269000);
      expect(s['artist'], '周杰伦 / 方文山');
      expect(s['album'], '叶惠美');
      expect(
        s['cover'],
        'https://p3-luna.douyinpic.com/img/cover-uri~p-resize:960:960.png',
      );
      expect(s['vip'], isFalse);
      expect(hosts, everyElement(sodaOfficialHosts.contains));
      expect(hosts, contains('api.qishui.com'));
    });

    test('专辑 / 歌单分类', () async {
      sodaHttpTransport = (uri, {headers}) async {
        capture(uri);
        if (uri.path.endsWith('/album')) {
          return _searchResp('album', [
            {
              'id': 'al1',
              'name': '半岛铁盒',
              'artists': [
                {'id': 'a1', 'name': '周杰伦'},
              ],
              'company': '杰威尔',
              'count_tracks': 10,
              'url_cover': _cover(),
            },
          ]);
        }
        return _searchResp('playlist', [
          {
            'id': 'pl1',
            'title': '周杰伦合集',
            'owner': {'nickname': '我'},
            'count_tracks': 20,
            'url_cover': _cover(),
          },
        ]);
      };

      final albumBody =
          await sodaCall('search', {'keywords': 'x', 'type': 1}) as Map;
      final a = (albumBody['albums'] as List).first as Map;
      expect(a['id'], 'al1');
      expect(a['name'], '半岛铁盒');
      expect(a['artist'], '周杰伦');
      expect(a['trackCount'], 10);

      final plBody =
          await sodaCall('search', {'keywords': 'y', 'type': 2}) as Map;
      final p = (plBody['playlists'] as List).first as Map;
      expect(p['id'], 'pl1');
      expect(p['name'], '周杰伦合集');
      expect(p['creator'], '我');
      expect(p['trackCount'], 20);
      expect(hosts, everyElement(sodaOfficialHosts.contains));
    });
  });

  group('SEO 单曲 / 取流', () {
    test('seo_track：元数据 + KRC 歌词 + playerInfoUrl', () async {
      sodaHttpTransport = (uri, {headers}) async {
        capture(uri);
        return {
          'status_code': 0,
          'seo_track': {
            'track': _track(),
            'lyric': {
              'content': '[15278,3319]<0,403,0>雨<560,403,0>下',
            },
          },
          'track_player': {
            'url_player_info':
                'https://vod-luna.douyin.com/?Action=GetPlayInfo&Version=2019-03-15',
          },
        };
      };

      final body = await sodaCall('seo_track', {'id': '1001'}) as Map;
      expect((body['track'] as Map)['name'], '晴天');
      expect('${body['lyric']}', startsWith('[15278,3319]'));
      expect(
        '${body['playerInfoUrl']}',
        startsWith('https://vod-luna.douyin.com/'),
      );
      expect(hosts, contains('api.qishui.com'));
    });

    test('play_info：挑选最高码率 MainPlayUrl + PlayAuth', () async {
      sodaHttpTransport = (uri, {headers}) async {
        capture(uri);
        return {
          'Result': {
            'Data': {
              'PlayInfoList': [
                {
                  'MainPlayUrl': 'https://cdn/low.m4a',
                  'PlayAuth': 'auth-low',
                  'Bitrate': 65598,
                  'Quality': 'medium',
                  'Format': 'm4a',
                },
                {
                  'MainPlayUrl': 'https://cdn/high.m4a',
                  'PlayAuth': 'auth-high',
                  'Bitrate': 258000,
                  'Quality': 'highest',
                  'Format': 'm4a',
                },
              ],
            },
          },
        };
      };

      final body = await sodaCall('play_info', {
        'url': 'https://vod-luna.douyin.com/?Action=GetPlayInfo',
      }) as Map;
      expect(body['url'], 'https://cdn/high.m4a');
      expect(body['playAuth'], 'auth-high');
      expect(body['bitrate'], 258000);
      expect(hosts, contains('vod-luna.douyin.com'));
    });

    test('play_info 无流 → code 404', () async {
      sodaHttpTransport = (uri, {headers}) async => {
        'ResponseMetadata': {
          'Error': {'Message': 'not found', 'Code': 'X'},
        },
        'Result': {
          'Data': {'PlayInfoList': <Object>[]},
        },
      };
      final body = await sodaCall('play_info', {
        'url': 'https://vod-luna.douyin.com/?x=1',
      }) as Map;
      expect(body['code'], 404);
    });
  });

  group('详情', () {
    test('PC 歌单：playlist + media_resources 曲目 + 游标', () async {
      sodaHttpTransport = (uri, {headers}) async {
        capture(uri);
        return {
          'status_info': {'log_id': 'x'},
          'has_more': true,
          'next_cursor': 'c2',
          'playlist': {'id': 'pl1', 'title': '合集'},
          'media_resources': [
            {
              'entity': {
                'track_wrapper': {'track': _track(id: 't1')},
              },
            },
          ],
        };
      };

      final body = await sodaCall('playlist', {'id': 'pl1'}) as Map;
      expect((body['playlist'] as Map)['name'], '合集');
      final songs = body['songs'] as List;
      expect(songs, hasLength(1));
      expect((songs.first as Map)['id'], 't1');
      expect(body['nextCursor'], 'c2');
      expect(body['hasMore'], isTrue);
      expect(hosts, contains('api.qishui.com'));
    });

    test('PC 专辑：album_info + tracks', () async {
      sodaHttpTransport = (uri, {headers}) async {
        capture(uri);
        return {
          'album_info': {
            'id': 'al1',
            'name': '半岛铁盒',
            'artists': [
              {'id': 'a1', 'name': '周杰伦'},
            ],
            'count_tracks': 1,
            'url_cover': _cover(),
          },
          'tracks': [_track(id: 't9')],
        };
      };

      final body = await sodaCall('album', {'id': 'al1'}) as Map;
      expect((body['album'] as Map)['name'], '半岛铁盒');
      expect((body['album'] as Map)['trackCount'], 1);
      final songs = body['songs'] as List;
      expect((songs.first as Map)['id'], 't9');
      expect(hosts, everyElement(sodaOfficialHosts.contains));
    });
  });
}

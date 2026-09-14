// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda）service 门面单测（**不联网**，注入 fake 传输）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:archoera_music/apis/soda/api.dart';
import 'package:archoera_music/apis/soda/core/config.dart';
import 'package:archoera_music/apis/soda/core/request.dart';
import 'package:archoera_music/services/soda/soda_api.dart';

Map<String, dynamic> _cover() => {
  'uri': 'c',
  'template_prefix': 'p',
  'urls': ['https://p3-luna.douyinpic.com/img/c'],
};

Map<String, dynamic> _track() => {
  'id': '1001',
  'name': '晴天',
  'duration': 269000,
  'artists': [
    {'id': 'a1', 'name': '周杰伦'},
  ],
  'album': {'id': 'al1', 'name': '叶惠美', 'url_cover': _cover()},
  'label_info': {'only_vip_playable': false},
};

void main() {
  final api = SodaApi();
  final hosts = <String>[];
  late SodaHttpTransport original;

  setUp(() {
    original = sodaHttpTransport;
    sodaClearCache();
    hosts.clear();
  });

  tearDown(() => sodaHttpTransport = original);

  test('searchSongs → Track（source=soda，出站仅官方）', () async {
    sodaHttpTransport = (uri, {headers}) async {
      hosts.add(uri.host);
      return {
        'result_groups': [
          {
            'data': [
              {'entity': {'track': _track()}},
            ],
          },
        ],
      };
    };

    final r = await api.searchSongs('晴天');
    expect(r.items, hasLength(1));
    final t = r.items.first;
    expect(t.id, '1001');
    expect(t.title, '晴天');
    expect(t.source, 'soda');
    expect(t.artistNames, '周杰伦');
    expect(t.album?.name, '叶惠美');
    expect(t.duration, 269000);
    expect(hosts, everyElement(sodaOfficialHosts.contains));
  });

  test('resolvePlayUrl：video_model 多档按 quality 选择', () async {
    sodaHttpTransport = (uri, {headers}) async {
      hosts.add(uri.host);
      if (uri.path.contains('/search/')) {
        return {
          'result_groups': [
            {
              'data': [
                {'entity': {'track': _track()}},
              ],
            },
          ],
        };
      }
      return {
        'status_code': 0,
        'seo_track': {
          'track': _track(),
          'lyric': {'content': ''},
        },
        'track_player': {
          'video_model_type': 1,
          'video_model': jsonEncode({
            'video_list': [
              {
                'main_url': 'https://cdn/highest.m4a',
                'video_meta': {'quality': 'highest', 'bitrate': 257557},
              },
              {
                'main_url': 'https://cdn/lossless.flac',
                'video_meta': {'quality': 'lossless', 'bitrate': 1000000},
              },
            ],
          }),
        },
      };
    };

    final track = (await api.searchSongs('x')).items.first;
    final url = await api.resolvePlayUrl(track, quality: 'lossless');
    expect(url, 'https://cdn/lossless.flac');
    // 请求 lossless 时无该档则降级
    final hq = await api.resolvePlayUrl(track, quality: 'hq');
    expect(hq, 'https://cdn/highest.m4a');
    expect(hosts, everyElement(sodaOfficialHosts.contains));
  });

  test('resolvePlayUrl：试听片段（video_model_type=2）→ 抛错', () async {
    sodaHttpTransport = (uri, {headers}) async {
      if (uri.path.contains('/search/')) {
        return {
          'result_groups': [
            {
              'data': [
                {'entity': {'track': _track()}},
              ],
            },
          ],
        };
      }
      return {
        'status_code': 0,
        'seo_track': {
          'track': _track(),
          'lyric': {'content': ''},
        },
        'track_player': {'video_model_type': 2, 'video_model': '{}'},
      };
    };
    final track = (await api.searchSongs('x')).items.first;
    await expectLater(
      api.resolvePlayUrl(track),
      throwsA(isA<SodaApiException>()),
    );
  });

  test('lyricRaw：返回 KRC 逐字原文', () async {
    sodaHttpTransport = (uri, {headers}) async {
      if (uri.path.contains('/search/')) {
        return {
          'result_groups': [
            {
              'data': [
                {'entity': {'track': _track()}},
              ],
            },
          ],
        };
      }
      return {
        'status_code': 0,
        'seo_track': {
          'track': _track(),
          'lyric': {'content': '[15278,3319]<0,403,0>雨<560,403,0>下'},
        },
        'track_player': {'url_player_info': ''},
      };
    };
    final r = await api.searchSongs('x');
    final krc = await api.lyricRaw(r.items.first);
    expect(krc, startsWith('[15278,3319]'));
  });

  test('songComments → 归一评论 + 偏移分页', () async {
    late Uri captured;
    sodaHttpTransport = (uri, {headers}) async {
      hosts.add(uri.host);
      captured = uri;
      return {
        'status_code': 0,
        'comments': [
          {
            'id': 'c1',
            'content': '好听',
            'count_digged': 12,
            'time_created': 1700000000,
            'ip_label': '浙江',
            'user': {
              'id': 'u1',
              'nickname': '梦醒',
              'medium_avatar_url': _cover(),
            },
          },
        ],
        'count': 56,
        'has_more': true,
      };
    };

    final page = await api.songComments('1001', page: 2, limit: 20);
    expect(page.list, hasLength(1));
    final c = page.list.first;
    expect(c.id, 'c1');
    expect(c.userName, '梦醒');
    expect(c.text, '好听');
    expect(c.likedCount, 12);
    expect(c.location, '浙江');
    expect(c.time, 1700000000000);
    expect(page.total, 56);
    expect(page.hasMore, isTrue);
    expect(captured.path, '/luna/pc/comments');
    expect(captured.queryParameters['cursor'], '20');
    expect(captured.queryParameters['group_id'], '1001');
    expect(hosts, everyElement(sodaOfficialHosts.contains));
  });

  test('songComments：hot → group_type=1', () async {
    late Uri captured;
    sodaHttpTransport = (uri, {headers}) async {
      captured = uri;
      return {
        'status_code': 0,
        'comments': const [],
        'count': 0,
        'has_more': false,
      };
    };
    await api.songComments('1001', hot: true);
    expect(captured.queryParameters['group_type'], '1');
  });

  test('sendComment：POST JSON + 登录 cookie', () async {
    final original = sodaRawTransport;
    late String method;
    late Uri uri;
    String? capturedBody;
    sodaRawTransport = (m, u, {body, headers, cookieHeader}) async {
      method = m;
      uri = u;
      capturedBody = body;
      return const SodaRawResult({'status_code': 0}, {});
    };
    addTearDown(() => sodaRawTransport = original);

    await api.sendComment('1001', '好听');
    expect(method, 'POST');
    expect(uri.path, '/luna/pc/comments/create');
    expect(jsonDecode(capturedBody!), {
      'group_id': '1001',
      'text': '好听',
      'group_type': 0,
    });
  });

  test('sendComment：非 0 → 抛错', () async {
    final original = sodaRawTransport;
    sodaRawTransport = (m, u, {body, headers, cookieHeader}) async =>
        const SodaRawResult({
          'status_code': 1000004,
          'status_info': {'status_msg': 'ERR_INVALID_PARAM'},
        }, {});
    addTearDown(() => sodaRawTransport = original);

    await expectLater(
      api.sendComment('1001', 'x'),
      throwsA(isA<SodaApiException>()),
    );
  });
}

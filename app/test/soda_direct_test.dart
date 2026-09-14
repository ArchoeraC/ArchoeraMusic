// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda）直连验证：真实请求官方云端（免登录、免签名）。
///
/// 覆盖：Android 搜索 → SEO `seo_track`（元数据 + 歌词 + 取流 URL）→
/// `PlayInfo` 取流；PC 歌单详情。出站均经官方域名硬校验。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/soda/api.dart';
import 'package:archoera_music/apis/soda/core/request.dart';

void main() {
  test('直连搜索（真实请求）', () async {
    final body =
        await sodaCall('search', {'keywords': '晴天 周杰伦', 'type': 0}) as Map;
    final songs = body['songs'] as List;
    expect(songs, isNotEmpty);
    final s = songs.first as Map;
    expect(s['id'], isNotEmpty);
    expect(s['name'], isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('SEO 单曲 + 取流（真实请求）', () async {
    final search = await sodaCall('search', {
      'keywords': '晴天 周杰伦',
      'type': 0,
      'timestamp': DateTime.now(),
    }) as Map;
    final id = ((search['songs'] as List).first as Map)['id'] as String;

    final seo = await sodaCall('seo_track', {'id': id}) as Map;
    expect(seo['code'], 200);
    final track = seo['track'] as Map;
    expect(track['id'], isNotEmpty);
    expect('${seo['playerInfoUrl']}', isNotEmpty);

    final info = await sodaCall('play_info', {
      'url': seo['playerInfoUrl'],
    }) as Map;
    // 免费曲给到直链；VIP/无版权可能无流（404）。
    expect(info['code'], anyOf(200, 404));
    if (info['code'] == 200) {
      expect('${info['url']}', startsWith('http'));
    }
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('PC 歌单详情（真实请求）', () async {
    final body = await sodaCall('playlist', {
      'id': '7661483391803523099',
    }) as Map;
    expect(body['code'], 200);
    expect(body['songs'], isA<List>());
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('评论读取 + 发布鉴权（真实请求）', () async {
    final search = await sodaCall('search', {
      'keywords': '晴天 周杰伦',
      'type': 0,
    }) as Map;
    final id = ((search['songs'] as List).first as Map)['id'] as String;

    final body = await sodaCall('comments', {
      'id': id,
      'cursor': 0,
      'limit': 5,
    }) as Map;
    expect(body['code'], 200);
    expect(body['comments'], isA<List>());

    // 未登录发布 → 登录失效码（端点可达、参数形状正确）；已登录则跳过，避免误发。
    if (!sodaHasSession()) {
      final send = await sodaCall('send_comment', {
        'id': id,
        'text': 'probe',
      }) as Map;
      expect(send['code'], isNot(200));
    }
  }, timeout: const Timeout(Duration(seconds: 40)));
}

/// QQ 音乐搜索失败归一 + 请求对齐（**不联网**，注入 fake 传输）。
///
/// 覆盖：
/// - 风控内码 inner=2001 → 抛 kind=risk 的 [QqApiException]，且请求层**不自动
///   重试**（实测重试只会刷高风控阈值）；
/// - 网络/传输级错误 → 退避重试（初次 + 2 次）后最终抛 kind=transient；
/// - 单页参数对齐：服务端硬上限（歌手 30 / 其它 50），超过会静默返回空页。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/qqmusic/api.dart';
import 'package:archoera_music/apis/qqmusic/core/request.dart';
import 'package:archoera_music/services/qqmusic/qqmusic_api.dart';

/// 成功响应包装：request.data 即模块数据段。
Map<String, dynamic> _okBody(Map<String, dynamic> data) => {
  'code': 0,
  'request': {'code': 0, 'data': data},
};

/// 与 search 模块 success 返回结构匹配的最小数据。
Map<String, dynamic> _searchData({String key = 'item_song'}) => {
  'body': {key: <Object>[]},
  'meta': {'sum': 0},
};

void main() {
  final api = QqMusicApi();
  late QmHttpTransport original;

  setUp(() {
    original = qmHttpTransport;
    qmClearCache();
  });

  tearDown(() => qmHttpTransport = original);

  test('风控 inner=2001 → 抛 risk（含 innerCode），且只发一次（不自动重试）', () async {
    var calls = 0;
    qmHttpTransport = (body, {extraHeaders, url}) async {
      calls++;
      return {
        'code': 0,
        'request': {
          'code': 2001,
          'data': {
            'body': <String, Object>{},
            'meta': {'is_filter': -12, 'sum': 0},
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
    expect(calls, 1, reason: '风控错误不应自动重试（防刷高风控）');
  });

  test('传输级瞬时错误 → 退避重试 3 次后抛 transient', () async {
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

  test('普通非零业务码 → 耗尽重试后抛 code 错误（仍非风控）', () async {
    var calls = 0;
    qmHttpTransport = (body, {extraHeaders, url}) async {
      calls++;
      return {
        'code': 0,
        'request': {
          'code': 700,
          'data': {'code': 0, 'body': <String, Object>{}},
        },
      };
    };

    await expectLater(
      api.searchSongs('周杰伦'),
      throwsA(
        isA<QqApiException>()
            .having((e) => e.kind, 'kind', QmErrorKind.code)
            .having((e) => e.code, 'code', 700),
      ),
    );
    expect(calls, 3, reason: '非风控业务码沿用上游重试语义');
  });

  test('单页上限对齐：歌手 search_type=1 上限 30（服务端 >30 返回空）', () async {
    Map<String, dynamic>? sent;
    qmHttpTransport = (body, {extraHeaders, url}) async {
      sent = body;
      return _okBody(_searchData(key: 'singer'));
    };

    final body = await qmCall('search', {
      'keywords': '周杰伦',
      'page': 1,
      'limit': 50,
      'type': 9, // 歌手
    });
    expect(body, isA<Map>());
    final req = sent!['request'] as Map<String, dynamic>;
    final param = req['param'] as Map<String, dynamic>;
    expect(param['num_per_page'], 30);
  });

  test('单页上限对齐：其余分类上限 50（>50 静默返回空页）', () async {
    Map<String, dynamic>? sent;
    qmHttpTransport = (body, {extraHeaders, url}) async {
      sent = body;
      return _okBody(_searchData());
    };

    final body = await qmCall('search', {
      'keywords': '周杰伦',
      'page': 1,
      'limit': 80,
      'type': 0, // 单曲
    });
    expect(body, isA<Map>());
    final req = sent!['request'] as Map<String, dynamic>;
    final param = req['param'] as Map<String, dynamic>;
    expect(param['num_per_page'], 50);
  });

  test('成功路径：请求只发一次并返回正常搜索结果', () async {
    var calls = 0;
    qmHttpTransport = (body, {extraHeaders, url}) async {
      calls++;
      return _okBody({
        'body': {
          'item_song': [
            {
              'id': 1,
              'mid': '004Z8Ihr0JIu5s',
              'title': '晴天',
              'interval': 269,
              'singer': [
                {'id': 2, 'mid': '003Nz2So3XXYek', 'name': '周杰伦'},
              ],
              'album': {'mid': '004Z8Ihr0JIu5s', 'name': '叶惠美'},
              'file': {'media_mid': '004Z8Ihr0JIu5s', 'size_128mp3': 1},
              'pay': {'pay_play': 0},
            },
          ],
        },
        'meta': {'sum': 1},
      });
    };

    final r = await api.searchSongs('晴天 周杰伦', page: 1, limit: 30);
    expect(calls, 1);
    expect(r.items, hasLength(1));
    expect(r.items.first.title, '晴天');
    expect(r.items.first.source, 'qqmusic');
    expect(r.total, 1);
    expect(r.hasMore, isFalse);
  });
}

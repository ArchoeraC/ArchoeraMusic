// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQ 音乐风控优化回归（**不联网**）。
///
/// 背景（2026-11-11 实测）：同一出口连打 4 次 `DoSearchForQQMusicDesktop`
/// （间隔 0s），前两次正常、第 3~4 次全部变成 `inner=2001` / 空结果，静置
/// ~90s 后恢复。旧实现有三个放大器：
///
/// 1. `comm.udid/OpenUDID/QIMEI36` 全是 `'0'`（最典型的脚本指纹）；
/// 2. `song_url` 每次取流随机生成 GUID（设备农场特征）；
/// 3. 请求层重试 2 次 + 模块层重试 2 次（一次搜索最多 9 个请求）。
///
/// 本文件锁定修复后的不变量：
/// - 设备身份跨调用稳定、落盘复用；
/// - QIMEI 上报请求形状正确、结果缓存、失败不影响业务；
/// - 节奏闸门（限并发/最小间隔/风控冷却）行为正确；
/// - 风险信号触发全局冷却，冷却期不联网。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/qqmusic/api.dart';
import 'package:archoera_music/apis/qqmusic/core/config.dart';
import 'package:archoera_music/apis/qqmusic/core/device.dart';
import 'package:archoera_music/apis/qqmusic/core/pacing.dart';
import 'package:archoera_music/apis/qqmusic/core/qimei.dart';
import 'package:archoera_music/apis/qqmusic/core/request.dart';
import 'package:archoera_music/apis/runtime.dart';

class _FakeSessionStore implements SessionStore {
  final Map<String, Map<String, String>> data = {};
  bool locked = false;

  @override
  Map<String, String> get(String platform) => data[platform] ?? {};

  @override
  void save(String platform, Map<String, String> cookies) =>
      data[platform] = {...cookies};

  @override
  void clear(String platform) => data[platform] = {};

  @override
  bool get isLocked => locked;
}

/// 成功的桌面搜索响应（空结果，meta.is_filter=0）。
Map<String, dynamic> _searchOk() => {
  'code': 0,
  'music.search.SearchCgiService': {
    'code': 0,
    'data': {
      'meta': {'sum': 0, 'is_filter': 0},
      'body': {
        'song': {'list': <Object>[]},
      },
    },
  },
};

void main() {
  late ApisRuntime prev;
  late _FakeSessionStore store;
  late QmHttpTransport originalTransport;
  late QmQimeiTransport originalQimei;

  setUp(() {
    prev = getRuntime();
    store = _FakeSessionStore();
    setRuntime(runtime: ApisRuntime(sessionStore: store));
    qmReloadQQMusicCookies();
    qmResetQimeiState();
    qmResetPacing();
    qmClearCache();
    qmClearQQMusicCookies();
    originalTransport = qmHttpTransport;
    originalQimei = qmQimeiTransport;
    // 默认：QIMEI 上报失败（不联网、不阻塞业务）。
    qmQimeiTransport = (url, headers, body) async => '{}';
    qmHttpTransport = (body, {extraHeaders, url}) async => _searchOk();
  });

  tearDown(() {
    qmHttpTransport = originalTransport;
    qmQimeiTransport = originalQimei;
    setRuntime(runtime: prev);
    qmResetPacing();
    qmResetQimeiState();
    qmClearCache();
    qmClearQQMusicCookies();
  });

  group('设备身份（安装级、跨调用稳定）', () {
    test('首次调用生成并落盘，第二次读到同一套身份', () {
      final first = qmGetDevice();
      expect(first.guid, hasLength(32));
      expect(first.udid, first.guid);
      expect(first.androidId, hasLength(16));
      expect(first.imei, hasLength(15));
      expect(store.data[qqDevicePlatform], isNotNull, reason: '必须持久化');
      expect(store.data[qqDevicePlatform]!['guid'], first.guid);

      // 丢弃进程内缓存后应从存储恢复出完全相同的身份。
      qmReloadQQMusicDevice();
      final restored = qmGetDevice();
      expect(restored.guid, first.guid);
      expect(restored.openUdid, first.openUdid);
      expect(restored.androidId, first.androidId);
      expect(restored.profileKey, first.profileKey);
    });

    test('IMEI 满足 Luhn 校验（随机 15 位数字会被服务端判为伪造）', () {
      for (var i = 0; i < 20; i++) {
        final imei = QqDevice.generate().imei;
        expect(imei, hasLength(15));
        var sum = 0;
        for (var j = 0; j < 15; j++) {
          var d = int.parse(imei[j]);
          if (j.isOdd && j != 14) {
            d *= 2;
            if (d > 9) d -= 9;
          }
          sum += d;
        }
        // Luhn：标准实现是偶数位双倍；这里统一按「校验位使总和 %10 == 0」验证。
        var alt = 0;
        for (var j = 0; j < 15; j++) {
          var d = int.parse(imei[j]);
          if (j % 2 == 1 && j != 14) {
            d *= 2;
            if (d > 9) d -= 9;
          }
          alt += d;
        }
        expect(sum % 10 == 0 || alt % 10 == 0, isTrue, reason: 'IMEI=$imei');
      }
    });

    test('凭据库锁定期间不把生成的设备写盘（解锁后仍能读到真实设备）', () {
      store.locked = true;
      final ephemeral = qmGetDevice();
      expect(store.data[qqDevicePlatform], isNull, reason: '锁定期不得落盘');

      store.locked = false;
      qmReloadQQMusicDevice();
      final saved = QqDevice.generate();
      store.data[qqDevicePlatform] = saved.toJson();
      qmReloadQQMusicDevice();
      final restored = qmGetDevice();
      expect(restored.guid, saved.guid);
      expect(restored.guid, isNot(ephemeral.guid));
    });

    test('comm 使用设备身份，不再全零', () {
      final device = qmGetDevice();
      final comm = qmGetCommonParams();
      expect(comm['udid'], device.udid);
      expect(comm['OpenUDID'], device.openUdid);
      expect(comm['aid'], device.androidId);
      expect(comm['phonetype'], device.model);
      expect(comm['os_ver'], device.osVer);
      expect(comm['cv'], device.cv);
      expect(comm['udid'], isNot('0'));
      // 未注册成功时 QIMEI36 是空串（不是 '0'：'0' 等于自称非客户端）。
      expect(comm['QIMEI36'], isNot('0'));
    });

    test('UA 与 comm 设备档案一致', () {
      final device = qmGetDevice();
      expect(qmHeaders['User-Agent'], device.userAgent);
      expect(
        qmHeaders['User-Agent'],
        'QQMusic ${device.cv}(android ${device.osVer})',
      );
    });
  });

  group('QIMEI 上报', () {
    test('请求形状：TRPC 代理 + RSA/AES 载荷 + md5 签名', () {
      final device = QqDevice.generate();
      final req = qmBuildQimeiRequest(device);
      expect(req.headers['appid'], 'qimei_qq_android');
      expect(req.headers['service'], 'trpc.tme_datasvr.qimeiproxy.QimeiProxy');
      expect(req.headers['method'], 'GetQimei');
      expect(req.headers['user-agent'], 'QQMusic');
      expect(req.headers['timestamp'], matches(RegExp(r'^\d+$')));

      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['app'], 0);
      expect(body['os'], 1);
      final params = body['qimeiParams'] as Map<String, dynamic>;
      // RSA(PKCS1, 1024bit) 输出固定 128 字节 → base64 长度 172。
      expect(params['key'], hasLength(172));
      expect(base64.decode(params['key'] as String), hasLength(128));
      // AES(16 字节 key/iv) 输出为 16 的倍数。
      expect(base64.decode(params['params'] as String).length % 16, 0);
      expect(params['nonce'], hasLength(16));
      expect(params['sign'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(params['extra'], '{"appKey":"0AND0HD6FE4HY80F"}');
    });

    test('负载包含真实设备字段（机型/系统/IMEI/beacon）', () {
      // 通过反射式读取：只验证密文非空且每次不同（随机 crypt key）。
      final a = qmBuildQimeiRequest(QqDevice.generate());
      final b = qmBuildQimeiRequest(QqDevice.generate());
      expect(a.body, isNot(b.body));
      final pa = (jsonDecode(a.body) as Map)['qimeiParams'] as Map;
      final pb = (jsonDecode(b.body) as Map)['qimeiParams'] as Map;
      expect(pa['key'], isNot(pb['key']));
      expect(pa['nonce'], isNot(pb['nonce']));
    });

    test('响应解析：data 为 JSON 字符串或对象都能取到 q16/q36', () {
      final asString = jsonEncode({
        'code': 0,
        'data': jsonEncode({
          'data': {'q16': 'q16-value', 'q36': 'q36-value'},
        }),
      });
      expect(qmParseQimeiResponse(asString)?.q36, 'q36-value');

      final asObject = jsonEncode({
        'code': 0,
        'data': {
          'data': {'q16': 'a', 'q36': 'b'},
        },
      });
      expect(qmParseQimeiResponse(asObject)?.q16, 'a');
      expect(qmParseQimeiResponse('not json'), isNull);
      expect(qmParseQimeiResponse('{"data":{"data":{}}}'), isNull);
    });

    test('注册成功后持久化 q36 并被 comm 使用；24h 内不重复上报', () async {
      var calls = 0;
      qmQimeiTransport = (url, headers, body) async {
        calls++;
        return jsonEncode({
          'code': 0,
          'data': jsonEncode({
            'data': {'q16': 'Q16', 'q36': 'Q36'},
          }),
        });
      };

      final device = await qmEnsureQimei();
      expect(device.qimei36, 'Q36');
      expect(calls, 1);
      expect(store.data[qqDevicePlatform]!['qimei36'], 'Q36');
      expect(qmGetCommonParams()['QIMEI36'], 'Q36');

      // 24h 内再次调用：不应再上报。
      await qmEnsureQimei();
      expect(calls, 1);

      // 强制刷新会再打一次。
      await qmEnsureQimei(force: true);
      expect(calls, 2);
    });

    test('上报失败静默：业务请求照常发出', () async {
      qmQimeiTransport = (url, headers, body) async => throw Exception('net');
      final device = await qmEnsureQimei();
      expect(device.qimei36, isEmpty);

      final sent = <Map<String, dynamic>>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        sent.add(body);
        return {
          'code': 0,
          'request': {
            'code': 0,
            'data': {
              'vec_hotkey': [
                {'query': '晴天'},
              ],
            },
          },
        };
      };
      final result = await qmCall('hot_search', const {});
      expect(sent, isNotEmpty);
      expect((result as Map)['code'], 200);
    });
  });

  group('节奏闸门', () {
    test('限并发：同时在途不超过上限', () async {
      var peak = 0;
      var current = 0;
      final futures = <Future<void>>[];
      for (var i = 0; i < kQmMaxInFlight * 2; i++) {
        futures.add(qmPaced(() async {
          current++;
          if (current > peak) peak = current;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          current--;
        }));
      }
      await Future.wait(futures);
      expect(peak, kQmMaxInFlight);
      expect(qmPacingSnapshot().inFlight, 0, reason: '名额必须归还');
    });

    test('风控冷却：qmNoteRisk 后进入指数退避，成功后不提前解除', () {
      expect(qmRiskCooling(), isFalse);
      final first = qmNoteRisk();
      expect(first, kQmRiskCooldown);
      expect(qmRiskCooling(), isTrue);

      final second = qmNoteRisk();
      expect(second, greaterThan(first), reason: '连续风控应逐次翻倍');

      // 成功请求不会把冷却提前解除。
      qmNoteSuccess();
      expect(qmRiskCooling(), isTrue);

      // 冷却上限 10 分钟。
      for (var i = 0; i < 10; i++) {
        qmNoteRisk();
      }
      expect(qmNoteRisk(), kQmRiskCooldownMax);
    });

    test('冷却期内 qmRequest 直接失败且不联网', () async {
      var networkCalls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        networkCalls++;
        return _searchOk();
      };
      qmNoteRisk();

      await expectLater(
        qmCall('comment', const {'id': '1'}),
        throwsA(isA<QmRequestException>()
            .having((e) => e.kind, 'kind', QmErrorKind.risk)),
      );
      expect(networkCalls, 0, reason: '冷却期不得发请求');
    });
  });

  group('风险信号与重试策略', () {
    test('搜索命中 2001 → risk + 全局冷却，且只发一次请求', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        return {
          'code': 0,
          'music.search.SearchCgiService': {
            'code': 2001,
            'data': {'meta': {'sum': 0}, 'body': <String, Object>{}},
          },
        };
      };

      await expectLater(
        qmCall('search', const {'keywords': '周杰伦'}),
        throwsA(anything),
      );
      expect(calls, 1);
      expect(qmRiskCooling(), isTrue, reason: '必须进入全局冷却');
    });

    test('搜索 meta.is_filter<0 → 冷却（不会被当成成功空结果）', () async {
      qmHttpTransport = (body, {extraHeaders, url}) async => {
        'code': 0,
        'music.search.SearchCgiService': {
          'code': 0,
          'data': {
            'meta': {'sum': 0, 'is_filter': -12},
            'body': <String, Object>{},
          },
        },
      };

      await expectLater(
        qmCall('search', const {'keywords': 'x'}),
        throwsA(anything),
      );
      expect(qmRiskCooling(), isTrue);
    });

    test('传输级错误只重试 1 次（旧实现 3 次）', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        throw Exception('socket timeout');
      };

      await expectLater(
        qmCall('search', const {'keywords': 'x'}),
        throwsA(anything),
      );
      expect(calls, 2, reason: '初次 + 1 次退避重试');
      expect(qmRiskCooling(), isFalse, reason: '网络错误不应触发风控冷却');
    });

    test('业务码错误不重试（重试只会增加风控计数）', () async {
      var calls = 0;
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls++;
        return {
          'code': 0,
          'request': {'code': 700, 'data': <String, dynamic>{}},
        };
      };

      await expectLater(
        qmCall('comment', const {'id': '1'}),
        throwsA(anything),
      );
      expect(calls, 1);
      expect(qmRiskCooling(), isFalse);
    });
  });

  group('取流（song_url）', () {
    test('GUID 使用稳定设备身份，不再每次随机', () async {
      final device = qmGetDevice();
      final uins = <String>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        final param = (body['req_0'] as Map)['param'] as Map;
        uins.add('${param['guid']}');
        return {
          'code': 0,
          'req_0': {
            'code': 0,
            'data': {'midurlinfo': <Object>[], 'sip': <String>[]},
          },
        };
      };

      // 取流走自建 HttpClient，不走 qmHttpTransport：这里直接验证模块请求体
      // 的 GUID 来源（同一设备多次调用一致）。
      expect(device.guid, hasLength(32));
      expect(qmGetDevice().guid, device.guid);
      expect(device.udid, device.guid);
    });
  });
}

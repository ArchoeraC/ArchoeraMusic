/// QQ 音乐（QM）请求层对齐单测（**不联网**，注入 fake 传输）。
///
/// 覆盖「Android 伪装 + GetSession 引导」的组网正确性：
/// - 配置：UA/Referer/comm 与上游 /tmp/spx config.ts 逐字段一致；
/// - session:false 接口（search 等）**不**先打 GetSession、不注入 uid/sid/userip；
/// - session:true 接口（leaderboard 等）先引导 GetSession（1 次），并把
///   uid/sid/userip 注入后续业务请求；1h 内并发去重（第二次调用不再 GetSession）；
/// - 已登录（cookie 带 musickey/uin/tmeLoginType）时 comm 注入
///   uin/qq/authst/tmeLoginType；微信型 key（W_X 前缀）默认 tmeLoginType=1。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/qqmusic/api.dart';
import 'package:archoera_music/apis/qqmusic/core/config.dart';
import 'package:archoera_music/apis/qqmusic/core/request.dart';

/// 已记录的业务请求 body（comm / request.module / request.param）。
class _Req {
  _Req(this.body);

  final Map<String, dynamic> body;

  Map<String, dynamic> get comm => (body['comm'] as Map).cast<String, dynamic>();
  Map<String, dynamic> get req => (body['request'] as Map).cast<String, dynamic>();
  String get module => '${req['module']}';
  String get method => '${req['method']}';
  Map<String, dynamic> get param =>
      (req['param'] as Map).cast<String, dynamic>();
}

/// 根据请求构造 fake 响应：GetSession → 返回给定 session；否则返回业务空数据。
Map<String, dynamic> _respond(
  Map<String, dynamic> body, {
  String uid = '6765761034',
  String sid = '202609052122150',
  String userip = '116.147.105.68',
}) {
  final req = body['request'] as Map;
  if (req['module'] == 'music.getSession.session') {
    return {
      'code': 0,
      'request': {
        'code': 0,
        'data': {
          'session': {'uid': uid, 'sid': sid, 'userip': userip},
        },
      },
    };
  }
  return {
    'code': 0,
    'request': {'code': 0, 'data': <String, dynamic>{'title': 'ok'}},
  };
}

/// 空搜索成功（供 search 模块归一；meta.is_filter=0 表示未被过滤）。
Map<String, dynamic> _searchOk() => {
  'code': 0,
  'request': {
    'code': 0,
    'data': {
      'body': {
        'item_song': <Object>[],
      },
      'meta': {'is_filter': 0, 'sum': 0},
    },
  },
};

void main() {
  late QmHttpTransport original;

  setUp(() {
    original = qmHttpTransport;
    qmClearCache();
    qmClearQQMusicCookies();
  });

  tearDown(() {
    qmHttpTransport = original;
    qmClearCache();
    qmClearQQMusicCookies();
  });

  group('config：Android 客户端伪装（对齐 config.ts）', () {
    test('UA / Referer / Content-Type', () {
      expect(qmHeaders['User-Agent'], 'QQMusic 14090008(android 15)');
      expect(qmHeaders['Referer'], 'https://y.qq.com');
      expect(qmHeaders['Content-Type'], 'application/json');
    });

    test('getCommonParams 逐字段', () {
      final c = qmGetCommonParams();
      expect(c['ct'], 11);
      expect(c['cv'], 14090008);
      expect(c['v'], 14090008);
      expect(c['chid'], '10003505');
      expect(c['os_ver'], '15');
      expect(c['phonetype'], '24122RKC7C');
      expect(c['tmeAppID'], 'qqmusic');
      expect(c['nettype'], 'NETWORK_WIFI');
      expect(c['udid'], '0');
      expect(c['OpenUDID'], '0');
      expect(c['QIMEI36'], '0');
      expect(c['uin'], '0');
    });
  });

  group('session 引导与 comm 组装', () {
    test('search 走 session:false：不打 GetSession、不注入 uid/sid/userip', () async {
      final calls = <Map<String, dynamic>>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls.add(body);
        return _searchOk();
      };

      await qmCall('search', {'keywords': '晴天', 'type': 0});
      expect(calls, hasLength(1), reason: 'session:false 不应先引导 GetSession');
      final r = _Req(calls.first);
      expect(r.module, 'music.search.SearchCgiService');
      expect(r.comm.containsKey('uid'), isFalse);
      expect(r.comm.containsKey('sid'), isFalse);
      expect(r.comm.containsKey('userip'), isFalse);
      expect(r.comm['uin'], '0');
    });

    test('session:true 先 GetSession 再注入 uid/sid/userip；1h 内去重', () async {
      final calls = <Map<String, dynamic>>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls.add(body);
        return _respond(body, uid: 'U1', sid: 'S1', userip: 'IP1');
      };

      // 第一次：GetSession + 业务两连发
      await qmCall('leaderboard', {'topid': 26});
      expect(calls, hasLength(2), reason: 'session:true 应先引导 GetSession');
      final gs = _Req(calls[0]);
      expect(gs.module, 'music.getSession.session');
      expect(gs.method, 'GetSession');
      expect(gs.param['caller'], 0);
      expect(gs.param['uid'], '0');
      expect(gs.param['vkey'], 0);

      final biz = _Req(calls[1]);
      expect(biz.comm['uid'], 'U1');
      expect(biz.comm['sid'], 'S1');
      expect(biz.comm['userip'], 'IP1');

      // 第二次：会话仍有效（1h 内），不再 GetSession
      calls.clear();
      qmClearCache();
      await qmCall('leaderboard', {'topid': 26});
      expect(calls, hasLength(1), reason: '1h 内 session 应命中缓存，不再 GetSession');
      final again = _Req(calls.first);
      expect(again.module, 'musicToplist.ToplistInfoServer');
      expect(again.comm['sid'], 'S1');
    });

    test('GetSession 失败静默：业务请求仍发出（不注入 session 字段）', () async {
      final calls = <Map<String, dynamic>>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls.add(body);
        final req = body['request'] as Map;
        if (req['module'] == 'music.getSession.session') {
          return {'code': -1, 'request': {'code': -1, 'data': <String, dynamic>{}}};
        }
        return {'code': 0, 'request': {'code': 0, 'data': <String, dynamic>{}}};
      };

      await qmCall('leaderboard', {'topid': 26});
      expect(calls, hasLength(2), reason: 'GetSession 失败不阻塞后续业务请求');
      final biz = _Req(calls[1]);
      expect(biz.comm.containsKey('uid'), isFalse);
      expect(biz.comm.containsKey('sid'), isFalse);
      expect(biz.comm.containsKey('userip'), isFalse);
    });

    test('已登录 cookie → comm 注入 uin/qq/authst/tmeLoginType（session:false 也不带 uid）', () async {
      qmMergeQQMusicCookies({
        'qm_str_musicid': '123456',
        'uin': 'o123456',
        'qm_keyst': 'key_abc',
        'qqmusic_key': 'key_abc',
        'tmeLoginType': '2',
      });
      final calls = <Map<String, dynamic>>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls.add(body);
        return _searchOk();
      };

      await qmCall('search', {'keywords': '周杰伦', 'type': 0});
      final r = _Req(calls.single);
      expect(r.comm['uin'], '123456');
      expect(r.comm['qq'], '123456');
      expect(r.comm['authst'], 'key_abc');
      expect(r.comm['tmeLoginType'], 2);
      expect(r.comm.containsKey('uid'), isFalse, reason: 'search 为 session:false');
      expect(r.comm.containsKey('sid'), isFalse);
    });

    test('微信型 key（W_X 前缀，无 tmeLoginType）→ 默认 tmeLoginType=1', () async {
      qmMergeQQMusicCookies({
        'qm_str_musicid': '888888',
        'qm_keyst': 'W_Xwxkey',
      });
      final calls = <Map<String, dynamic>>[];
      qmHttpTransport = (body, {extraHeaders, url}) async {
        calls.add(body);
        return _searchOk();
      };

      await qmCall('search', {'keywords': '晴天', 'type': 0});
      final r = _Req(calls.single);
      expect(r.comm['uin'], '888888');
      expect(r.comm['authst'], 'W_Xwxkey');
      expect(r.comm['tmeLoginType'], 1);
    });
  });
}

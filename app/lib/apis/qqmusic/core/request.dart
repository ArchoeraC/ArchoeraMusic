/// QM 请求层——对齐 apis/qqmusic/core/request.ts。
///
/// - 统一走 u.y.qq.com/cgi-bin/musicu.fcg 的 `{ comm, request: {module, method, param} }` 协议
/// - 首次请求前先调 music.getSession.session 拿 uid/sid/userip，缓存 1 小时
/// - 没有加密：API 本身明文 JSON POST，靠 UA + QIMEI36 等 comm 字段伪装客户端
library;

import 'dart:convert';
import 'dart:io';

import 'config.dart';

/// Session 字段（可能缺失则下次请求会自动补拿）
class QmSessionCache {
  String? uid;
  String? sid;
  String? userip;
  int expireAt = 0;
}

QmSessionCache _session = QmSessionCache();
Future<void>? _initPromise;

/// 重试次数与退避
const _maxRetry = 2;
const _retryBackoff = 300;

Future<void> _delay(int ms) => Future.delayed(Duration(milliseconds: ms));

/// 直接发起一次 fcg POST（不做 session 注入，用于初始化自身）
Future<Map<String, dynamic>> _postRaw(Map<String, dynamic> body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.postUrl(Uri.parse(qmApiUrl));
    qmHeaders.forEach((k, v) => req.headers.set(k, v));
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

/// 初始化 / 刷新 session（1h 过期）；并发安全：同一时刻只发一次
Future<void> _ensureSession() {
  if (_session.uid != null && _session.expireAt > DateTime.now().millisecondsSinceEpoch) {
    return Future.value();
  }
  final pending = _initPromise;
  if (pending != null) return pending;

  final p = () async {
    try {
      final body = {
        'comm': qmGetCommonParams(),
        'request': {
          'module': 'music.getSession.session',
          'method': 'GetSession',
          'param': {'caller': 0, 'uid': '0', 'vkey': 0},
        },
      };
      final data = await _postRaw(body);
      final request = data['request'];
      final reqCode = request is Map ? request['code'] : 0;
      if (data['code'] == 0 && reqCode == 0) {
        final requestData = request is Map ? request['data'] : null;
        final info = requestData is Map ? (requestData['session'] as Map?) ?? const {} : const {};
        _session
          ..uid = info['uid'] as String?
          ..sid = info['sid'] as String?
          ..userip = info['userip'] as String?
          ..expireAt = DateTime.now().millisecondsSinceEpoch + qmSessionTtl;
      }
    } catch (_) {
      // session 失败不阻塞后续调用，大部分接口无 session 也能回结果
    } finally {
      _initPromise = null;
    }
  }();

  _initPromise = p;
  return p;
}

/// 发送一次 musicu.fcg 请求，返回 request.data 的业务数据段
Future<T> qmRequest<T>(
  String module,
  String method,
  Map<String, dynamic> param,
) async {
  await _ensureSession();

  final comm = <String, Object>{
    ...qmGetCommonParams(),
    if (_session.uid != null) 'uid': _session.uid!,
    if (_session.sid != null) 'sid': _session.sid!,
    if (_session.userip != null) 'userip': _session.userip!,
  };

  final body = <String, dynamic>{'comm': comm, 'request': {'module': module, 'method': method, 'param': param}};

  // QM 后端偶发瞬时错误
  Object? lastErr;
  for (var attempt = 0; attempt <= _maxRetry; attempt++) {
    try {
      final data = await _postRaw(body);
      final outerCode = data['code'] ?? 0;
      final request = data['request'];
      final innerCode = request is Map ? (request['code'] ?? 0) : 0;
      if (outerCode != 0 || innerCode != 0) {
        throw StateError('QM API 错误: outer=$outerCode inner=$innerCode');
      }
      final reqData = request is Map ? request['data'] : null;
      return reqData as T;
    } catch (err) {
      lastErr = err;
      if (attempt < _maxRetry) await _delay(_retryBackoff);
    }
  }
  throw lastErr ?? StateError('QM request failed');
}

/// 调试用：取当前 session 快照
Map<String, Object?> qmGetSession() => {
      'uid': _session.uid,
      'sid': _session.sid,
      'userip': _session.userip,
      'expireAt': _session.expireAt,
    };

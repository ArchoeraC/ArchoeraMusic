/// QM 请求层——对齐 apis/qqmusic/core/request.ts。
///
/// - 统一走 u.y.qq.com/cgi-bin/musicu.fcg 的 `{ comm, request: {module, method, param} }` 协议
/// - 首次请求前先调 music.getSession.session 拿 uid/sid/userip，缓存 1 小时
/// - 无加密：API 本身明文 JSON POST，靠 UA + QIMEI36 等 comm 字段伪装客户端
/// - 登录态：Cookie（qm_keyst / qm_str_musicid / p_skey 等）经宿主
///   [getRuntime().sessionStore]（平台键 'qqmusic'）持久化，请求自动注入
/// - 登出 / 登录变更会使匿名 session 失效（避免跨账号复用）
library;

import 'dart:convert';
import 'dart:io';

import '../../runtime.dart';
import 'config.dart';
import 'credential.dart';

/// QM 错误分类（请求层归一后供上层展示/重试决策）。
enum QmErrorKind {
  /// 网络错误 / 超时 / 非 JSON 等瞬时问题（可自动重试后仍失败的最终态）。
  transient,

  /// 其它非零业务码（outer/inner 非 0 且未被识别为风控）。
  code,

  /// 风控 / 限流拦截（实测 inner=2001：`meta.is_filter=-12` + 空结果体）。
  risk,
}

/// QM 请求层异常：携带 outer/inner 业务码与分类。
///
/// - [retryable] 仅表示「请求层已做自动重试」的最终态；对风控（risk）错误，
///   请求层**不自动重试**（重试只会刷高风控阈值），交由上层提示后手动重试。
class QmRequestException implements Exception {
  const QmRequestException(
    this.message, {
    this.kind = QmErrorKind.code,
    this.outer,
    this.inner,
    this.retryable = false,
  });

  final String message;
  final QmErrorKind kind;
  final int? outer;
  final int? inner;
  final bool retryable;

  /// 展示用错误码（优先内码，其次外码）。
  int? get code => inner ?? outer;

  @override
  String toString() => message;
}

/// 可注入的传输层（测试用 fake；默认走 dart:io HttpClient 直连）。
typedef QmHttpTransport = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> body, {
  Map<String, String>? extraHeaders,
  String? url,
});

/// Session 字段（可能缺失则下次请求会自动补拿）
class QmSessionCache {
  String? uid;
  String? sid;
  String? userip;
  int expireAt = 0;
}

QmSessionCache _session = QmSessionCache();
Future<void>? _initPromise;

/// 客户端会话代际：cookie 变更（登录/登出）时 +1，使在途旧 session 失效。
int _sessionGeneration = 0;

/// 内存中的用户 cookie（null = 尚未从宿主 store 加载）。
Map<String, String>? _userCookies;

/// 重试次数与退避
const _maxRetry = 2;
const _retryBackoffMs = 300;

/// 风控 / 限流内码（实测 search 被拦时 `request.code=2001`，
/// `data.meta.is_filter=-12`、结果体为空）。
const int _qmRiskInnerCode = 2001;

/// 当前传输实现（默认直连；测试注入 fake 后由 [qmPostRaw] 统一出口）。
QmHttpTransport qmHttpTransport = _defaultTransport;

Future<void> _delay(int ms) => Future.delayed(Duration(milliseconds: ms));

/// 业务码解析：JSON 数字可能为 int/double，统一转 int。
int _codeOf(Object? v) =>
    v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

/// 读取内存或宿主存储中的 QM cookies。
Map<String, String> qmGetQQMusicCookies() {
  if (_userCookies != null) return _userCookies!;
  _userCookies = Map<String, String>.of(getRuntime().sessionStore.get('qqmusic'));
  return _userCookies!;
}

/// 更新 QM cookies 并落盘（登录 / 凭据刷新成功后调用）。
void qmMergeQQMusicCookies(Map<String, String> cookies) {
  final current = qmGetQQMusicCookies();
  _userCookies = <String, String>{...current, ...cookies};
  getRuntime().sessionStore.save('qqmusic', _userCookies!);
  _invalidateSession();
}

/// 清空 QM cookies 登录态（登出）。
void qmClearQQMusicCookies() {
  _userCookies = <String, String>{};
  getRuntime().sessionStore.clear('qqmusic');
  _invalidateSession();
}

/// 提取当前登录 uin（纯数字形式；未登录返回 '0'）。
String qmGetQQMusicUin() {
  final cookies = qmGetQQMusicCookies();
  final raw =
      (cookies['qm_str_musicid'] ??
          cookies['uin'] ??
          cookies['wxuin'] ??
          cookies['p_uin'] ??
          '')
          .trim();
  return raw.startsWith('o') ? raw.substring(1) : (raw.isEmpty ? '0' : raw);
}

/// 当前是否有可用登录 key（影响 song_url / 会员接口行为）。
bool qmHasQQMusicLogin() {
  final cookies = qmGetQQMusicCookies();
  final uin = qmGetQQMusicUin();
  return uin != '0' &&
      (cookies['qm_keyst']?.isNotEmpty == true ||
          cookies['qqmusic_key']?.isNotEmpty == true ||
          cookies['pskey']?.isNotEmpty == true ||
          cookies['p_skey']?.isNotEmpty == true ||
          cookies['skey']?.isNotEmpty == true);
}

/// 使当前客户端会话失效，避免账号变化后继续复用旧会话。
void _invalidateSession() {
  _sessionGeneration++;
  _session = QmSessionCache();
}

/// 直接发起一次 fcg POST（自动注入 Cookie；供内部 session 初始化使用）。
///
/// 传输级错误（网络/超时/非 JSON 响应）抛 [QmRequestException]（kind=transient、
/// retryable=true），由 [qmRequest] 决定是否重试。
Future<Map<String, dynamic>> qmPostRaw(
  Map<String, dynamic> body, {
  Map<String, String>? extraHeaders,
  String? url,
}) {
  return qmHttpTransport(body, extraHeaders: extraHeaders, url: url);
}

/// 默认传输：dart:io HttpClient 直连 musicu.fcg。
Future<Map<String, dynamic>> _defaultTransport(
  Map<String, dynamic> body, {
  Map<String, String>? extraHeaders,
  String? url,
}) async {
  final cookies = qmGetQQMusicCookies();
  final cookieStr = qmSessionToCookieHeader(cookies);
  final headers = <String, String>{
    ...qmHeaders,
    'Cookie': ?cookieStr,
    ...?extraHeaders,
  };
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.postUrl(Uri.parse(url ?? qmApiUrl));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final status = res.statusCode;
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (status < 200 || status >= 300) {
      throw QmRequestException(
        'QM HTTP $status',
        kind: QmErrorKind.transient,
        retryable: true,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      throw QmRequestException(
        'QM 响应不是合法 JSON（HTTP $status）',
        kind: QmErrorKind.transient,
        retryable: true,
      );
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw QmRequestException(
      'QM 响应结构异常（HTTP $status）',
      kind: QmErrorKind.transient,
      retryable: true,
    );
  } on QmRequestException {
    rethrow;
  } catch (err) {
    throw QmRequestException(
      'QM 网络请求失败: $err',
      kind: QmErrorKind.transient,
      retryable: true,
    );
  } finally {
    client.close();
  }
}

/// 初始化 / 刷新 session（1h 过期）；并发安全：同一时刻只发一次。
Future<void> _ensureSession() {
  if (_session.uid != null && _session.expireAt > DateTime.now().millisecondsSinceEpoch) {
    return Future.value();
  }
  final pending = _initPromise;
  if (pending != null) return pending;

  final p = () async {
    final generation = _sessionGeneration;
    try {
      final uin = qmGetQQMusicUin();
      final comm = <String, Object>{
        ...qmGetCommonParams(),
        if (uin.isNotEmpty && uin != '0') 'uin': uin,
      };
      final body = {
        'comm': comm,
        'request': {
          'module': 'music.getSession.session',
          'method': 'GetSession',
          'param': {'caller': 0, 'uid': uin, 'vkey': 0},
        },
      };
      final data = await qmPostRaw(body);
      if (generation != _sessionGeneration) return;
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

/// 发送一次 musicu.fcg 请求，返回 request.data 的业务数据段。
///
/// [session] 为 false 时不先取匿名 session（热搜/评论/搜索等非必要接口）；
/// [comm] 可追加 comm 字段（如登录扫描接口的 tmeLoginType）。
Future<T> qmRequest<T>(
  String module,
  String method,
  Map<String, dynamic> param, {
  bool session = true,
  Map<String, dynamic>? comm,
}) async {
  if (session) await _ensureSession();

  final uin = qmGetQQMusicUin();
  final cookies = qmGetQQMusicCookies();
  final musickey = cookies['qm_keyst'] ?? cookies['qqmusic_key'];
  final tmeLoginType = cookies['tmeLoginType'];
  final loginType = tmeLoginType != null
      ? int.tryParse(tmeLoginType)
      : (musickey?.startsWith('W_X') == true ? 1 : 2);

  final baseComm = <String, Object>{
    ...qmGetCommonParams(),
    if (uin.isNotEmpty && uin != '0') ...{'uin': uin, 'qq': uin},
    if (musickey != null && musickey.isNotEmpty) ...{
      'authst': musickey,
      'tmeLoginType': loginType ?? 2,
    },
    if (session && _session.uid != null) 'uid': _session.uid!,
    if (session && _session.sid != null) 'sid': _session.sid!,
    if (session && _session.userip != null) 'userip': _session.userip!,
    ...?comm,
  };

  final body = <String, dynamic>{
    'comm': baseComm,
    'request': {'module': module, 'method': method, 'param': param},
  };

  // 瞬时网络错误自动重试（带退避）；业务码错误：
  // - inner/outer = 2001（风控/限流）**不自动重试**，直接抛 risk，避免刷高风控；
  // - 其余非零业务码按上游做法退避重试后再抛 code。
  Object? lastErr;
  for (var attempt = 0; attempt <= _maxRetry; attempt++) {
    try {
      final data = await qmPostRaw(body);
      final outerCode = _codeOf(data['code']);
      final request = data['request'];
      final innerCode =
          request is Map ? _codeOf(request['code']) : 0;
      if (outerCode == 0 && innerCode == 0) {
        final reqData = request is Map ? request['data'] : null;
        return reqData as T;
      }
      final risk =
          outerCode == _qmRiskInnerCode || innerCode == _qmRiskInnerCode;
      if (risk) {
        throw QmRequestException(
          'QQ 音乐接口拦截：请求过于频繁或触发风控'
          '（outer=$outerCode inner=$innerCode）',
          kind: QmErrorKind.risk,
          outer: outerCode,
          inner: innerCode,
        );
      }
      if (attempt < _maxRetry) {
        await _delay(_retryBackoffMs * (attempt + 1));
        continue;
      }
      throw QmRequestException(
        'QM API 错误: outer=$outerCode inner=$innerCode',
        kind: QmErrorKind.code,
        outer: outerCode,
        inner: innerCode,
      );
    } on QmRequestException {
      // 已归一为最终错误（risk 立即抛；code 在耗尽重试后抛）：不再自动重试
      rethrow;
    } catch (err) {
      // 传输级（网络/超时/JSON）错误
      lastErr = err;
      if (attempt < _maxRetry) {
        await _delay(_retryBackoffMs * (attempt + 1));
        continue;
      }
    }
  }
  throw QmRequestException(
    'QQ 音乐请求失败: $lastErr',
    kind: QmErrorKind.transient,
    retryable: false,
  );
}

/// 调试用：取当前 session 快照。
Map<String, Object?> qmGetSession() => {
  'uid': _session.uid,
  'sid': _session.sid,
  'userip': _session.userip,
  'expireAt': _session.expireAt,
};

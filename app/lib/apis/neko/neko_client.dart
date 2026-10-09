// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic REST 传输层（实验性音源）。
///
/// 与 NT/KG/QM 的签名加密协议不同：Neko 是**统一 REST + 不透明 token**
/// （64 位十六进制）。请求头按当前服务端 / 官方客户端规范使用
/// `Authorization: Bearer <token>`（服务端同时兼容裸 token，见
/// `RequestAuthUtil` / `RedisTokenStore`）。本文件只做「HTTP + JSON + SSE」
/// 且与宿主无关（无 Riverpod / 无状态），由 `services/neko/neko_api.dart`
/// 组织业务并注入 token。
///
/// 注意：Neko 业务层大量使用 HTTP 200 + `{"success": false, "message": ...}`
/// 表达失败，故传输层**只在 HTTP 非 2xx 时抛错**，业务成败由上层判 `success`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/neko/neko_identity.dart';
import 'neko_replay.dart';

/// 默认服务器地址（可在设置中修改）。
const String kDefaultNekoBaseUrl = 'https://music.nekocore.cn';

/// 归一化服务器地址：补 scheme、去尾部 `/`；空值回退默认地址。
String normalizeNekoBaseUrl(String? raw) {
  var s = (raw ?? '').trim();
  if (s.isEmpty) return kDefaultNekoBaseUrl;
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'https://$s';
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 错误类别（用于 UI 文案分派）。
enum NekoErrorKind {
  /// 网络不可达 / 超时 / 非 JSON 响应。
  network,

  /// 未登录 / token 失效（HTTP 401）。
  auth,

  /// 资源不存在（HTTP 404）。
  notFound,

  /// 业务失败（HTTP 200 + `success:false`，或其它非 2xx）。
  api,
}

/// Neko 接口异常。
class NekoApiException implements Exception {
  NekoApiException(
    this.message, {
    this.statusCode,
    this.kind = NekoErrorKind.api,
  });

  final String message;
  final int? statusCode;
  final NekoErrorKind kind;

  @override
  String toString() => message;
}

/// SSE 事件（`event:` + 拼接后的 `data:`）。
class NekoSseEvent {
  const NekoSseEvent({required this.event, required this.data});

  final String event;
  final String data;
}

/// ── 请求防重放 nonce 池（对齐官方 PC 端 `ReplayNonceStore`）──────────────
///
/// 服务端对全部动态接口（`/api/*`、`/loser/*`）强制要求一次性 `X-Neko-Nonce`：
/// 缺失/重放/过期返回 `409`（`X-Neko-Replay-Status: missing|invalid`）。
///
/// 领取 nonce **必须先换题再兑换**：`GET /api/replay/challenge` 换题 → 后台 isolate
/// 解出 `proof` → `GET /api/replay/nonce?challenge=&proof=` 兑换读 / 写两类 nonce。
/// 不带挑战的裸领取会被新服务端拒绝（`409`）；为兼容尚未提供挑战接口的旧服务端，
/// 换题返回 `404` 时回退为不带挑战的领取（对齐官方 PC 端）。
///
/// 这里按站点批量预取，用后即弃；本地 90s 提前作废（服务端 120s）。nonce 绑定领取时的
/// 出口 IP，故换 IP/代理时可能 `invalid`，由调用方换新重试一次兜住。
class _NekoNonce {
  const _NekoNonce(this.value, this.issuedAt);

  final String value;
  final DateTime issuedAt;
}

/// 换题得到的挑战：`id` 为 `challenge`，`seed` + `difficulty` 用于在后台解出 `proof`。
class _NekoChallenge {
  const _NekoChallenge({
    required this.id,
    required this.seed,
    required this.difficulty,
  });

  final String id;
  final String seed;
  final int difficulty;
}

/// 换题结果。
sealed class _ChallengeFetch {
  const _ChallengeFetch();
}

/// 换题成功，得到一道待解的挑战。
class _ChallengeReady extends _ChallengeFetch {
  const _ChallengeReady(this.challenge);

  final _NekoChallenge challenge;
}

/// 换题失败（网络错误 / 非 2xx / 响应无法识别）：本轮放弃，交给下次补领。
class _ChallengeUnavailable extends _ChallengeFetch {
  const _ChallengeUnavailable();
}

/// 服务端未提供挑战接口（HTTP 404）：回退为不带挑战的旧领取方式。
class _ChallengeNotSupported extends _ChallengeFetch {
  const _ChallengeNotSupported();
}

/// 兑换 nonce 的结果。
enum _ClaimOutcome {
  /// 已领取到 nonce（列表可能为空）。
  done,

  /// 挑战失效 / 解答不合格（`400` / `409`）：换新题重解一次。
  retry,

  /// 限额（`429`）/ 服务不可用（`503`）/ 网络错误：本轮打住，不紧循环撞限额。
  abort,
}

/// 单次 GET 的原始结果（状态码 + 解析出的 JSON）。
class _NekoHttpGet {
  const _NekoHttpGet(this.status, this.json);

  final int status;
  final Map<String, dynamic>? json;
}

class _NekoNoncePool {
  _NekoNoncePool(this.baseUrl);

  final String baseUrl;

  static const int _batch = 16; // 服务端上限 64；官方 PC 端取 16
  static const int _lowWater = 4;
  static const Duration _localMaxAge = Duration(seconds: 90);
  static const Duration _timeout = Duration(seconds: 12);

  /// 一轮领取里「换题 → 解题 → 兑换」的最大尝试次数（对齐官方 PC 端）。
  static const int _maxClaimAttempts = 2;

  final List<_NekoNonce> _read = [];
  final List<_NekoNonce> _write = [];
  Future<void>? _refilling;

  bool get _isLow => _read.length < _lowWater || _write.length < _lowWater;

  /// 取一个 nonce（[write] = 写类别，否则读类别）；池空时先补领，仍无则 null。
  Future<String?> take({required bool write}) async {
    var nonce = _pop(write);
    if (nonce != null) {
      if (_isLow) unawaited(_refill());
      return nonce;
    }
    await _refill();
    nonce = _pop(write);
    return nonce;
  }

  /// 服务端判定重放/失效：清空并补领（下次请求用新 nonce）。
  void noteRejected() {
    _read.clear();
    _write.clear();
    unawaited(_refill());
  }

  String? _pop(bool write) {
    final pool = write ? _write : _read;
    final now = DateTime.now();
    while (pool.isNotEmpty) {
      final entry = pool.removeAt(0);
      if (now.difference(entry.issuedAt) < _localMaxAge) return entry.value;
    }
    return null;
  }

  Future<void> _refill() {
    final pending = _refilling;
    if (pending != null) return pending;
    final future = _fetch();
    _refilling = future;
    return future.whenComplete(() {
      if (identical(_refilling, future)) _refilling = null;
    });
  }

  /// 一轮领取：换题 → 解题 → 兑换；被拒（`400` / `409`）换新题重解一次。
  Future<void> _fetch() async {
    for (var attempt = 0; attempt < _maxClaimAttempts; attempt++) {
      final fetched = await _requestChallenge();
      switch (fetched) {
        case _ChallengeUnavailable():
          return;
        case _ChallengeNotSupported():
          // 旧服务端（无挑战接口）：回退为不带挑战直接领取。
          await _claim(challenge: null, proof: null);
          return;
        case _ChallengeReady(challenge: final challenge):
          final proof = await nekoSolveProof(
            challenge.seed,
            challenge.difficulty,
          );
          if (proof == null) return;
          final outcome = await _claim(challenge: challenge, proof: proof);
          if (outcome == _ClaimOutcome.retry) continue;
          return;
      }
    }
  }

  /// 换题：`GET /api/replay/challenge`，区分「成功 / 失败 / 旧服务端（404）」。
  Future<_ChallengeFetch> _requestChallenge() async {
    final res = await _getJson('/api/replay/challenge', {
      'read': '$_batch',
      'write': '$_batch',
    });
    if (res == null) return const _ChallengeUnavailable();
    // 旧服务端还没有挑战接口：回退为不带挑战的领取（新服务端会拒绝，无副作用）。
    if (res.status == 404) return const _ChallengeNotSupported();
    if (res.status < 200 || res.status >= 300) {
      return const _ChallengeUnavailable();
    }
    final data = res.json?['data'];
    if (data is! Map) return const _ChallengeUnavailable();
    final algorithm = data['algorithm']?.toString() ?? '';
    final id = data['challenge']?.toString() ?? '';
    final seed = data['seed']?.toString() ?? '';
    final difficulty = (data['difficulty'] as num?)?.toInt() ?? -1;
    // 算法不认识就不盲解（服务端换算法时下个版本再适配）。
    if (algorithm != kNekoPowAlgorithm ||
        id.isEmpty ||
        seed.isEmpty ||
        difficulty < 0) {
      return const _ChallengeUnavailable();
    }
    return _ChallengeReady(
      _NekoChallenge(id: id, seed: seed, difficulty: difficulty),
    );
  }

  /// 兑换 nonce：带 `challenge` / `proof`（旧服务端回退时改带 `read` / `write`）。
  Future<_ClaimOutcome> _claim({
    required _NekoChallenge? challenge,
    required String? proof,
  }) async {
    final res = await _getJson('/api/replay/nonce', {
      if (challenge != null) 'challenge': challenge.id,
      if (challenge != null && proof != null) 'proof': proof,
      if (challenge == null) 'read': '$_batch',
      if (challenge == null) 'write': '$_batch',
    });
    if (res == null) return _ClaimOutcome.abort;
    // 领取被拒（挑战缺失 / 失效 / 解答不合格统一回 409）：换题重解一次。
    if (res.status == 400 || res.status == 409) return _ClaimOutcome.retry;
    if (res.status < 200 || res.status >= 300) return _ClaimOutcome.abort;
    final data = res.json?['data'];
    final nonces = data is Map ? data['nonces'] : null;
    if (nonces is! Map) return _ClaimOutcome.abort;
    final now = DateTime.now();
    void append(List<_NekoNonce> pool, Object? raw) {
      if (raw is! List) return;
      for (final value in raw) {
        final s = value?.toString() ?? '';
        if (s.isNotEmpty) pool.add(_NekoNonce(s, now));
      }
    }

    append(_read, nonces['read']);
    append(_write, nonces['write']);
    return _ClaimOutcome.done;
  }

  /// 单次 GET（自动带分层客户端身份头）；网络错误 / 非 JSON 返回 null。
  Future<_NekoHttpGet?> _getJson(
    String path,
    Map<String, String> query,
  ) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final uri = Uri.parse(baseUrl)
          .resolve(path)
          .replace(queryParameters: query);
      final req = await client.getUrl(uri).timeout(_timeout);
      // 领取接口自身豁免 nonce，但仍需携带分层客户端身份（防爬过滤器按 UA 判定）。
      nekoRequestHeaders.forEach(req.headers.set);
      final res = await req.close().timeout(_timeout);
      final text = await res.transform(utf8.decoder).join().timeout(_timeout);
      Map<String, dynamic>? json;
      if (text.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) json = decoded;
        } catch (_) {
          // 非 JSON 响应：按状态码处理
        }
      }
      return _NekoHttpGet(res.statusCode, json);
    } catch (_) {
      // 领取失败：按无 nonce 继续，由上层收到 409 后兜底
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

final Map<String, _NekoNoncePool> _noncePools = {};
_NekoNoncePool _noncePoolFor(String baseUrl) =>
    _noncePools.putIfAbsent(baseUrl, () => _NekoNoncePool(baseUrl));

/// 路径是否需要防重放 nonce（与后端 `ReplayProtectionFilter` 豁免清单一致）。
bool nekoNeedsNonce(String path, String method) {
  var p = path;
  final q = p.indexOf('?');
  if (q >= 0) p = p.substring(0, q);
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  final verb = method.toUpperCase();
  if (verb == 'OPTIONS' || verb == 'HEAD') return false;
  const exemptPaths = {
    '/api/replay/challenge',
    '/api/replay/nonce',
    '/api/music/latest',
    '/api/music/ranking',
    '/api/payment/zpay/notify',
    '/api/user/qrlogin/status',
  };
  if (exemptPaths.contains(p)) return false;
  const exemptPrefixes = ['/api/music/cover/', '/api/user/avatar/'];
  for (final prefix in exemptPrefixes) {
    if (p.startsWith(prefix)) return false;
  }
  if (p.endsWith('/pull')) return false;
  return p.startsWith('/api/') || p.startsWith('/loser/');
}

/// 单次 Neko 请求的原始结果（供 [NekoClient._send] 判断换 nonce / 换身份重试）。
class _NekoRawResponse {
  const _NekoRawResponse(
    this.status,
    this.decoded,
    this.replayRejected,
    this.degraded,
  );

  final int status;
  final Map<String, dynamic>? decoded;
  final bool replayRejected;

  /// 被服务端按爬虫降级（SEO HTML / 403 拒绝），而非真实业务响应。
  final bool degraded;
}

/// 判断响应是否为服务端「防爬降级」的表现，而非真实业务响应。
///
/// 服务端对判定为爬虫的请求：`GET`/`HEAD` 返回 **SEO HTML**（HTTP 200，
/// `text/html`），其它方法返回 **403** `{"success":false,"message":"请求已拒绝"}`。
/// 客户端据此把「本体标识被降级」与「真实业务失败 / 未登录」区分开：前者切换
/// 到回退身份重试一次，后者照常按业务错误处理——绝不把 SEO HTML 当成空业务结果。
bool nekoIsDegradedResponse({
  required int status,
  String? contentType,
  required String body,
}) {
  final ct = (contentType ?? '').toLowerCase();
  final trimmed = body.trim();
  final looksHtml = ct.contains('text/html') ||
      trimmed.startsWith('<') ||
      trimmed.startsWith('<!');
  if (status == 200 || status == 304) {
    // 200 + SEO HTML：GET 被降级直出页面。
    return looksHtml;
  }
  if (status == 403) {
    // 非 GET 被拒：优先看空体 / HTML；JSON 403 只认服务端统一的拒绝文案。
    return looksHtml || trimmed.isEmpty || body.contains('请求已拒绝');
  }
  return false;
}

/// Neko REST 客户端（不可变：baseUrl / token 变化时重新构造）。
class NekoClient {
  NekoClient({String? baseUrl, this.token})
    : baseUrl = normalizeNekoBaseUrl(baseUrl);

  /// 归一化后的服务器根地址（无尾斜杠）。
  final String baseUrl;

  /// 登录 token（未登录为 null）。
  final String? token;

  static const Duration _timeout = Duration(seconds: 12);

  Uri _uri(String path, [Map<String, String>? query]) {
    final parsed = Uri.parse(path);
    final Uri u;
    if (parsed.hasScheme) {
      // 已是绝对地址（如解析后的媒体直链）→ 原样使用。
      u = parsed;
    } else {
      final base = Uri.parse(baseUrl);
      // path 以 `/` 开头 → resolve 直接替换路径。
      u = base.resolve(path.startsWith('/') ? path : '/$path');
    }
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  /// 拼接资源绝对地址（封面 / 音频等；已是绝对地址则原样返回）。
  String resolveUrl(String pathOrUrl) {
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }
    return '$baseUrl${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
  }

  void _applyHeaders(HttpClientRequest req, String? contentType) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    nekoRequestHeaders.forEach(req.headers.set);
    if (contentType != null) {
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    final t = token;
    if (t != null && t.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
    }
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
  }) => _send('GET', path, query: query);

  Future<Map<String, dynamic>> postJson(String path, {Object? body}) =>
      _send('POST', path, body: body);

  Future<Map<String, dynamic>> deleteJson(
    String path, {
    Map<String, String>? query,
  }) => _send('DELETE', path, query: query);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final protected = nekoNeedsNonce(path, method);
    final write = method.toUpperCase() != 'GET';
    _NekoRawResponse? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      final nonce = protected
          ? await _noncePoolFor(baseUrl).take(write: write)
          : null;
      final res = await _sendOnce(
        method,
        path,
        query: query,
        body: body,
        nonce: nonce,
      );
      last = res;
      // 缺 nonce / 已失效：换新 nonce 重试一次（被拒请求不会执行，无重复副作用）。
      if (res.replayRejected && attempt < 2) {
        _noncePoolFor(baseUrl).noteRejected();
        continue;
      }
      break;
    }
    final res = last!;
    // 被防爬降级（SEO HTML / 拒绝体）：明确报错，绝不把 SEO HTML 当成业务成功。
    if (res.degraded) {
      throw NekoApiException(
        'NekoMusic 拒绝本次请求（客户端标识未获放行）',
        statusCode: res.status,
        kind: NekoErrorKind.api,
      );
    }
    if (res.status < 200 || res.status >= 300) {
      throw NekoApiException(
        res.decoded?['message']?.toString() ??
            res.decoded?['error']?.toString() ??
            'HTTP ${res.status}',
        statusCode: res.status,
        kind: switch (res.status) {
          401 => NekoErrorKind.auth,
          404 => NekoErrorKind.notFound,
          _ => NekoErrorKind.api,
        },
      );
    }
    return res.decoded ?? <String, dynamic>{};
  }

  Future<_NekoRawResponse> _sendOnce(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? nonce,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .openUrl(method, _uri(path, query))
          .timeout(_timeout);
      _applyHeaders(
        req,
        body == null ? null : 'application/json; charset=utf-8',
      );
      if (nonce != null && nonce.isNotEmpty) {
        req.headers.set(kNekoNonceHeader, nonce);
      }
      if (body != null) {
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(_timeout);
      final replayStatus = res.headers.value(kNekoReplayStatusHeader);
      final bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(_timeout);
      final text = utf8.decode(bytes, allowMalformed: true);
      Map<String, dynamic>? decoded;
      if (text.trim().isNotEmpty) {
        try {
          final json = jsonDecode(text);
          if (json is Map<String, dynamic>) decoded = json;
        } catch (_) {
          // 非 JSON（如纯文本错误页）：按状态码处理
        }
      }
      final rejected =
          res.statusCode == 409 &&
          (replayStatus == 'missing' || replayStatus == 'invalid');
      final degraded = nekoIsDegradedResponse(
        status: res.statusCode,
        contentType: res.headers.contentType?.mimeType,
        body: text,
      );
      return _NekoRawResponse(res.statusCode, decoded, rejected, degraded);
    } on TimeoutException {
      throw NekoApiException('请求超时', kind: NekoErrorKind.network);
    } on SocketException catch (e) {
      throw NekoApiException(
        '网络不可达：${e.message}',
        kind: NekoErrorKind.network,
      );
    } catch (e) {
      if (e is NekoApiException) rethrow;
      throw NekoApiException('$e', kind: NekoErrorKind.network);
    } finally {
      client.close(force: true);
    }
  }

  /// 读取资源**前 [maxBytes] 字节**（Range 请求），用于嗅探音频容器魔数。
  ///
  /// 失败 / 空响应返回空列表（调用方回退其它判定方式）。Neko 音频为
  /// **直传原文件**，扩展名只能靠内容判断（对齐官方客户端
  /// `extensionFromBuffer` 的做法）。
  Future<List<int>> getLeadingBytes(String path, {int maxBytes = 16}) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(_uri(path)).timeout(_timeout);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${maxBytes - 1}');
      nekoRequestHeaders.forEach(req.headers.set);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200 && res.statusCode != 206) {
        return const [];
      }
      final bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(_timeout);
      return bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes;
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// 订阅 SSE（Neko 二维码登录状态用）。
  ///
  /// 逐行解析 `event:` / `data:`；连接结束或抛错时流关闭。调用方取消订阅
  /// 时 `finally` 会强制关闭底层连接。
  Stream<NekoSseEvent> sse(String path) async* {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(_uri(path)).timeout(_timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      nekoRequestHeaders.forEach(req.headers.set);
      final t = token;
      if (t != null && t.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      final res = await req.close();
      if (res.statusCode != 200) {
        throw NekoApiException(
          'HTTP $res.statusCode',
          statusCode: res.statusCode,
          kind: res.statusCode == 401
              ? NekoErrorKind.auth
              : NekoErrorKind.api,
        );
      }
      // 被降级为 SEO HTML：明确报错，绝不把 SEO HTML 当成业务成功。
      if ((res.headers.contentType?.mimeType ?? '').contains('text/html')) {
        throw NekoApiException(
          'NekoMusic 拒绝本次请求（客户端标识未获放行）',
          statusCode: res.statusCode,
          kind: NekoErrorKind.api,
        );
      }
      var event = 'message';
      final data = StringBuffer();
      final lines = res
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (line.isEmpty) {
          if (data.isNotEmpty) {
            yield NekoSseEvent(event: event, data: data.toString());
            data.clear();
            event = 'message';
          }
          continue;
        }
        if (line.startsWith(':')) continue; // SSE 注释/心跳
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.write(line.substring(5).trimLeft());
        }
      }
      if (data.isNotEmpty) {
        yield NekoSseEvent(event: event, data: data.toString());
      }
    } on NekoApiException {
      rethrow;
    } on TimeoutException {
      throw NekoApiException('连接超时', kind: NekoErrorKind.network);
    } on SocketException catch (e) {
      throw NekoApiException(
        '网络不可达：${e.message}',
        kind: NekoErrorKind.network,
      );
    } finally {
      client.close(force: true);
    }
  }
}

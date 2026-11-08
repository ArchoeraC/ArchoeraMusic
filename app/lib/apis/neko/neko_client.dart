// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic REST 传输层（实验性音源）。
///
/// 新协议是**统一 REST + NekoAuth access token**：请求头只带
/// `Authorization: Bearer <token>`（服务端同时兼容裸 token）与常规 UA，
/// 不再有 PoW、防重放 nonce 或客户端实例签名。本文件只做
/// 「HTTP + JSON + SSE」且与宿主无关（无 Riverpod / 无状态），由
/// `services/neko/neko_api.dart` 组织业务并注入 token。
///
/// 注意：Neko 业务层大量使用 HTTP 200 + `{"success": false, "message": ...}`
/// 表达失败，故传输层**只在 HTTP 非 2xx 时抛错**，业务成败由上层判 `success`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/neko/neko_identity.dart';

/// 默认服务器地址（固定站点，不对外暴露为可设置项）。
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

/// 判断响应是否为服务端「防爬降级」的表现，而非真实业务响应。
///
/// 服务端对判定为爬虫的请求：`GET`/`HEAD` 返回 **SEO HTML**（HTTP 200，
/// `text/html`），其它方法返回 **403** `{"success":false,"message":"请求已拒绝"}`。
/// UA 只是表示选择、不参与鉴权；一旦拿到 HTML，明确报错，绝不能当成业务成功。
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

/// 单次请求的原始结果（状态码 + 解析出的 JSON + 是否被降级）。
class _NekoHttpResult {
  const _NekoHttpResult({
    required this.status,
    required this.decoded,
    required this.degraded,
  });

  final int status;
  final Map<String, dynamic>? decoded;
  final bool degraded;
}

/// Neko REST 客户端（不可变：baseUrl / token 变化时重新构造）。
class NekoClient {
  NekoClient({String? baseUrl, this.token})
    : baseUrl = normalizeNekoBaseUrl(baseUrl);

  /// 归一化后的服务器根地址（无尾斜杠）。
  final String baseUrl;

  /// 登录 token（未登录为 null）。
  final String? token;

  /// 用户令牌失效（HTTP 401）时回调，参数为服务端文案。
  ///
  /// 宿主（`NekoApi`）据此清除本地会话、回到未登录态；传输层本身不碰会话存储。
  void Function(String message)? onUnauthorized;

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
    final res = await _sendOnce(method, path, query: query, body: body);
    // 用户令牌失效：交给宿主清会话，避免拿着死令牌反复 401。
    if (res.status == 401) {
      onUnauthorized?.call(
        res.decoded?['message']?.toString() ??
            res.decoded?['error']?.toString() ??
            'HTTP 401',
      );
    }
    // 被防爬降级（SEO HTML / 拒绝体）：明确报错，绝不把 SEO HTML 当成业务成功。
    if (res.degraded) {
      throw NekoApiException(
        'NekoMusic 返回了非 API 响应（客户端标识未获放行）',
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

  Future<_NekoHttpResult> _sendOnce(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = _uri(path, query);
    final bodyBytes = body == null
        ? const <int>[]
        : utf8.encode(jsonEncode(body));
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(_timeout);
      _applyHeaders(
        req,
        body == null ? null : 'application/json; charset=utf-8',
      );
      if (bodyBytes.isNotEmpty) {
        req.add(bodyBytes);
      }
      final res = await req.close().timeout(_timeout);
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
      return _NekoHttpResult(
        status: res.statusCode,
        decoded: decoded,
        degraded: nekoIsDegradedResponse(
          status: res.statusCode,
          contentType: res.headers.contentType?.mimeType,
          body: text,
        ),
      );
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
          'NekoMusic 返回了非 API 响应（客户端标识未获放行）',
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

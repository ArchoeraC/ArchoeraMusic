// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic REST 传输层（实验性音源）。
///
/// 与 NT/KG/QM 的签名加密协议不同：Neko 是**统一 REST + 不透明 token**
/// （64 位十六进制，`Authorization: <token>` 或 `Bearer <token>` 均可）。
/// 本文件只做「HTTP + JSON + SSE」且与宿主无关（无 Riverpod / 无状态），
/// 由 `services/neko/neko_api.dart` 组织业务并注入 token。
///
/// 注意：Neko 业务层大量使用 HTTP 200 + `{"success": false, "message": ...}`
/// 表达失败，故传输层**只在 HTTP 非 2xx 时抛错**，业务成败由上层判 `success`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 默认服务器地址（可在设置中修改）。
const String kDefaultNekoBaseUrl = 'https://music.cnmsb.xin';

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
    final base = Uri.parse(baseUrl);
    // path 以 `/` 开头 → resolve 直接替换路径。
    final u = base.resolve(path.startsWith('/') ? path : '/$path');
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
    if (contentType != null) {
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    final t = token;
    if (t != null && t.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, t);
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
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .openUrl(method, _uri(path, query))
          .timeout(_timeout);
      _applyHeaders(
        req,
        body == null ? null : 'application/json; charset=utf-8',
      );
      if (body != null) {
        req.add(utf8.encode(jsonEncode(body)));
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
          // 非 JSON（如纯文本错误页）：下方按状态码处理
        }
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw NekoApiException(
          decoded?['message']?.toString() ??
              decoded?['error']?.toString() ??
              'HTTP $res.statusCode',
          statusCode: res.statusCode,
          kind: switch (res.statusCode) {
            401 => NekoErrorKind.auth,
            404 => NekoErrorKind.notFound,
            _ => NekoErrorKind.api,
          },
        );
      }
      return decoded ?? <String, dynamic>{};
    } on NekoApiException {
      rethrow;
    } on TimeoutException {
      throw NekoApiException('请求超时', kind: NekoErrorKind.network);
    } on SocketException catch (e) {
      throw NekoApiException(
        '网络不可达：${e.message}',
        kind: NekoErrorKind.network,
      );
    } catch (e) {
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
      final t = token;
      if (t != null && t.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, t);
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

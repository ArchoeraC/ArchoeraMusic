// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili HTTP 传输与会话。
///
/// 安全边界（对齐项目网络策略）：
/// - 只访问固定官方 host；
/// - 不跟随重定向（3xx 直接判失败）；
/// - 单响应上限 4 MiB，连接/读取超时 15 秒；
/// - Cookie 只保留 [kBilibiliCookieNames] 白名单，经宿主 vault 持久化；
/// - 播放 CDN 不使用账号 Cookie（由播放器只带 UA/Referer）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../runtime.dart';
import 'config.dart';
import 'wbi.dart';

/// B 站错误分类（供 UI/搜索退避决策）。
enum BilibiliErrorKind {
  authRequired,
  verificationRequired,
  rateLimited,
  unavailable,
  network,
  invalidResponse,
  invalidRequest,
}

class BilibiliApiException implements Exception {
  const BilibiliApiException(
    this.message, {
    this.kind = BilibiliErrorKind.unavailable,
    this.code,
  });

  final String message;
  final BilibiliErrorKind kind;
  final int? code;

  @override
  String toString() => message;
}

/// 请求层：原始 JSON + 会话 Cookie。
class BilibiliRequest {
  BilibiliRequest({HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.idleTimeout = const Duration(seconds: 15);
  }

  final HttpClient _client;

  /// 本次进程内新拿到的 Cookie（登录轮询等）；与 vault 中已存值合并。
  final Map<String, String> _pendingCookies = {};

  String? _imgKey;
  String? _subKey;
  DateTime? _keysAt;

  static const _responseLimit = 4 * 1024 * 1024;
  static const _requestTimeout = Duration(seconds: 15);
  static const _wbiKeyTtl = Duration(minutes: 10);

  bool get hasSession {
    final cookies = _cookieMap();
    return (cookies['SESSDATA']?.isNotEmpty ?? false);
  }

  String? get cookieHeader {
    final cookies = _cookieMap();
    if (cookies.isEmpty) return null;
    return cookies.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  /// 拉取 B 站官方接口 JSON（不做 `code` 业务校验）。
  ///
  /// [signed] 为 true 时走 WBI（自动取/缓存 key）。
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String> params = const {},
    bool signed = false,
    bool passport = false,
  }) async {
    final base = passport ? kBilibiliPassportBase : kBilibiliApiBase;
    final query = signed ? await _signedQuery(params) : _encodeQuery(params);
    final uri = Uri.parse('$base$path${query.isEmpty ? '' : '?$query'}');

    try {
      final request = await _client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, kBilibiliUserAgent);
      request.headers.set(HttpHeaders.refererHeader, kBilibiliReferer);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final cookie = cookieHeader;
      if (cookie != null) request.headers.set(HttpHeaders.cookieHeader, cookie);

      final response = await request.close().timeout(_requestTimeout);
      _mergeSetCookies(response);
      final status = response.statusCode;
      if (status == HttpStatus.unauthorized) {
        throw const BilibiliApiException(
          'Bilibili sign-in is required.',
          kind: BilibiliErrorKind.authRequired,
          code: 401,
        );
      }
      if (status == HttpStatus.forbidden || status == 412) {
        throw BilibiliApiException(
          'Bilibili requires verification on its official website.',
          kind: BilibiliErrorKind.verificationRequired,
          code: status,
        );
      }
      if (status == HttpStatus.tooManyRequests) {
        throw const BilibiliApiException(
          'Bilibili request limit reached.',
          kind: BilibiliErrorKind.rateLimited,
          code: 429,
        );
      }
      if (status >= 300 && status < 400) {
        throw BilibiliApiException(
          'Bilibili returned an unexpected redirect (HTTP $status).',
          kind: BilibiliErrorKind.invalidResponse,
          code: status,
        );
      }
      if (status >= 500) {
        throw BilibiliApiException(
          'Bilibili service is temporarily unavailable (HTTP $status).',
          kind: BilibiliErrorKind.network,
          code: status,
        );
      }
      if (status != HttpStatus.ok) {
        throw BilibiliApiException(
          'Bilibili request failed (HTTP $status).',
          kind: BilibiliErrorKind.network,
          code: status,
        );
      }

      final bytes = await _readLimited(response);
      final text = utf8.decode(bytes, allowMalformed: true);
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const BilibiliApiException(
          'Bilibili returned an invalid response.',
          kind: BilibiliErrorKind.invalidResponse,
        );
      }
      return Map<String, dynamic>.from(decoded);
    } on BilibiliApiException {
      rethrow;
    } on TimeoutException {
      throw const BilibiliApiException(
        'Bilibili request timed out.',
        kind: BilibiliErrorKind.network,
      );
    } on SocketException {
      throw const BilibiliApiException(
        'Bilibili connection failed. Check your network.',
        kind: BilibiliErrorKind.network,
      );
    } on FormatException {
      throw const BilibiliApiException(
        'Bilibili returned an invalid response.',
        kind: BilibiliErrorKind.invalidResponse,
      );
    }
  }

  Future<List<int>> _readLimited(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (builder.length + chunk.length > _responseLimit) {
        throw const BilibiliApiException(
          'Bilibili response is too large.',
          kind: BilibiliErrorKind.invalidResponse,
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<String> _signedQuery(Map<String, String> params) async {
    final keys = await _wbiKeys();
    final query = bilibiliWbiQuery(
      params: params,
      imageKey: keys.$1,
      subKey: keys.$2,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    if (query == null) {
      throw const BilibiliApiException(
        'Bilibili signing keys are invalid.',
        kind: BilibiliErrorKind.invalidResponse,
      );
    }
    return query;
  }

  Future<(String, String)> _wbiKeys() async {
    final now = DateTime.now();
    final cachedImg = _imgKey;
    final cachedSub = _subKey;
    final at = _keysAt;
    if (cachedImg != null &&
        cachedSub != null &&
        at != null &&
        now.difference(at) < _wbiKeyTtl) {
      return (cachedImg, cachedSub);
    }

    // nav 匿名访问会返回 code=-101，但仍会给出 wbi_img；这里刻意不解包 code。
    final root = await getJson('/x/web-interface/nav');
    final data = root['data'];
    final wbi = data is Map ? data['wbi_img'] : null;
    final imageKey = _keyFromUrl(wbi is Map ? wbi['img_url'] : null);
    final subKey = _keyFromUrl(wbi is Map ? wbi['sub_url'] : null);
    if (imageKey == null || subKey == null) {
      throw const BilibiliApiException(
        'Bilibili did not provide signing keys.',
        kind: BilibiliErrorKind.invalidResponse,
      );
    }
    _imgKey = imageKey;
    _subKey = subKey;
    _keysAt = now;
    return (imageKey, subKey);
  }

  String? _keyFromUrl(Object? raw) {
    final uri = Uri.tryParse(raw?.toString() ?? '');
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final name = uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final key = dot > 0 ? name.substring(0, dot) : name;
    return RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(key) ? key : null;
  }

  String _encodeQuery(Map<String, String> params) {
    if (params.isEmpty) return '';
    final keys = params.keys.toList()..sort();
    return keys
        .map(
          (key) =>
              '${Uri.encodeComponent(key)}=${Uri.encodeComponent(params[key] ?? '')}',
        )
        .join('&');
  }

  Map<String, String> _cookieMap() {
    final saved = getRuntime().sessionStore.get(kBilibiliSessionPlatform);
    return <String, String>{...saved, ..._pendingCookies};
  }

  void _mergeSetCookies(HttpClientResponse response) {
    final rawCookies =
        response.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    var changed = false;
    for (final raw in rawCookies) {
      final first = raw.split(';').first;
      final equals = first.indexOf('=');
      if (equals <= 0) continue;
      final name = first.substring(0, equals).trim();
      final value = first.substring(equals + 1).trim();
      if (name.isEmpty ||
          value.isEmpty ||
          !kBilibiliCookieNames.contains(name)) {
        continue;
      }
      _pendingCookies[name] = value;
      changed = true;
    }
    if (changed) saveSession();
  }

  /// 把内存 Cookie 合并写回宿主 vault。
  void saveSession() {
    final cookies = _cookieMap();
    final store = getRuntime().sessionStore;
    if (cookies.isEmpty) {
      store.clear(kBilibiliSessionPlatform);
    } else {
      store.save(kBilibiliSessionPlatform, cookies);
    }
  }

  /// 退出登录：清空内存与 vault 中的 B 站会话。
  void clearSession() {
    _pendingCookies.clear();
    getRuntime().sessionStore.clear(kBilibiliSessionPlatform);
  }

  void dispose() {
    _client.close(force: true);
  }
}

/// 解析 B 站业务响应包：`{code, message, data}`。
///
/// 与 KMusic 的语义一致：`-101` 登录、`-352/-412/-403` 风控/验证、
/// `-509` 限流、其它非零不可用。
Map<String, dynamic> bilibiliData(Map<String, dynamic> root) {
  final code = _asInt(root['code']);
  final data = root['data'];
  if (code == -101) {
    throw const BilibiliApiException(
      'Bilibili sign-in is required.',
      kind: BilibiliErrorKind.authRequired,
      code: -101,
    );
  }
  if (code == -352 ||
      code == -412 ||
      code == -403 ||
      (data is Map && data['v_voucher'] != null)) {
    throw BilibiliApiException(
      'Bilibili requires verification on its official website.',
      kind: BilibiliErrorKind.verificationRequired,
      code: code,
    );
  }
  if (code == -509 || code == -799) {
    throw BilibiliApiException(
      'Bilibili request limit reached.',
      kind: BilibiliErrorKind.rateLimited,
      code: code,
    );
  }
  if (code != 0) {
    final message = root['message']?.toString().trim() ?? '';
    throw BilibiliApiException(
      message.isEmpty ? 'Bilibili content is unavailable.' : message,
      kind: BilibiliErrorKind.unavailable,
      code: code,
    );
  }
  if (data is Map) return Map<String, dynamic>.from(data);
  if (data == null) return const <String, dynamic>{};
  throw const BilibiliApiException(
    'Bilibili response has no data object.',
    kind: BilibiliErrorKind.invalidResponse,
  );
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda）请求层：可注入传输 + **官方域名硬校验**。
///
/// - 所有出站经 [sodaGetJson]：先校验 host ∈ [sodaOfficialHosts]，再交给
///   [sodaHttpTransport]（默认真连；测试注入 fake 断言域名）。
/// - 非官方域名直接抛 [SodaRequestException]，**永不发起**（守住报告 §8.1）。
library;

import 'dart:convert';
import 'dart:io';

import '../../runtime.dart';
import 'config.dart';

/// 汽水请求异常（非官方域名 / HTTP / 非 JSON）。
class SodaRequestException implements Exception {
  const SodaRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 可注入的传输层：给定 Uri 与头，返回 JSON Map。
typedef SodaHttpTransport = Future<Map<String, dynamic>> Function(
  Uri uri, {
  Map<String, String>? headers,
});

/// 当前传输实现（默认直连；测试注入 fake）。
SodaHttpTransport sodaHttpTransport = _defaultSodaTransport;

/// GET 并解析 JSON，出站前强制官方域名校验。
Future<Map<String, dynamic>> sodaGetJson(
  Uri uri, {
  Map<String, String>? headers,
}) {
  if (!sodaOfficialHosts.contains(uri.host)) {
    throw SodaRequestException('汽水出站域名非官方，已拒绝：${uri.host}');
  }
  return sodaHttpTransport(uri, headers: headers);
}

/// 低层请求结果：JSON body + 响应 `Set-Cookie`（Passport 登录需要）。
class SodaRawResult {
  const SodaRawResult(this.json, this.cookies);

  final Map<String, dynamic> json;
  final Map<String, String> cookies;
}

/// 低层传输（GET/POST，需捕获 Set-Cookie）；测试注入 fake。
typedef SodaRawTransport = Future<SodaRawResult> Function(
  String method,
  Uri uri, {
  String? body,
  Map<String, String>? headers,
  String? cookieHeader,
});

/// 当前低层传输实现（默认直连；测试注入 fake）。
SodaRawTransport sodaRawTransport = _defaultRawTransport;

/// GET/POST 并解析 JSON + 捕获 Cookie；出站前强制官方域名校验。
Future<SodaRawResult> sodaRawRequest(
  String method,
  Uri uri, {
  String? body,
  Map<String, String>? headers,
  String? cookieHeader,
}) {
  if (!sodaOfficialHosts.contains(uri.host)) {
    throw SodaRequestException('汽水出站域名非官方，已拒绝：${uri.host}');
  }
  return sodaRawTransport(
    method,
    uri,
    body: body,
    headers: headers,
    cookieHeader: cookieHeader,
  );
}

// ── 会话 Cookie（Passport 登录态，落 vault 平台键 'soda'）──────────────────

Map<String, String>? _sodaCookies;

/// 读取内存或宿主存储中的汽水 cookies。
Map<String, String> sodaGetCookies() {
  if (_sodaCookies != null) return _sodaCookies!;
  _sodaCookies = Map<String, String>.of(getRuntime().sessionStore.get('soda'));
  return _sodaCookies!;
}

/// 合并并落盘 cookies（登录过程中每一步 Set-Cookie 都并入）。
void sodaMergeCookies(Map<String, String> cookies) {
  if (cookies.isEmpty) return;
  _sodaCookies = <String, String>{...sodaGetCookies(), ...cookies};
  getRuntime().sessionStore.save('soda', _sodaCookies!);
}

/// 清空汽水登录态（登出）。
void sodaClearCookies() {
  _sodaCookies = <String, String>{};
  getRuntime().sessionStore.clear('soda');
}

/// 是否已登录（存在会话 cookie）。
bool sodaHasSession() {
  final cookies = sodaGetCookies();
  for (final key in const [
    'sessionid',
    'sessionid_ss',
    'sid_tt',
    'sid_guard',
  ]) {
    if ((cookies[key] ?? '').isNotEmpty) return true;
  }
  return false;
}

/// 组装 `Cookie` 头（按键排序，稳定）。
String? sodaCookieHeader() {
  final cookies = sodaGetCookies();
  final keys = cookies.keys.where((k) => cookies[k]!.isNotEmpty).toList()..sort();
  if (keys.isEmpty) return null;
  return keys.map((k) => '$k=${cookies[k]}').join('; ');
}

Future<Map<String, dynamic>> _defaultSodaTransport(
  Uri uri, {
  Map<String, String>? headers,
}) async {
  final merged = <String, String>{
    'Accept': 'application/json, text/plain, */*',
    ...?headers,
  };
  final cookie = sodaCookieHeader();
  if (cookie != null) merged['Cookie'] = cookie;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(uri);
    merged.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close().timeout(const Duration(seconds: 12));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SodaRequestException('汽水 HTTP ${res.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      throw const SodaRequestException('汽水响应不是合法 JSON');
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const SodaRequestException('汽水响应结构异常');
  } on SodaRequestException {
    rethrow;
  } catch (err) {
    throw SodaRequestException('汽水网络请求失败: $err');
  } finally {
    client.close();
  }
}

/// 默认低层传输：直连官方，GET/POST 表单，捕获 `Set-Cookie`。
Future<SodaRawResult> _defaultRawTransport(
  String method,
  Uri uri, {
  String? body,
  Map<String, String>? headers,
  String? cookieHeader,
}) async {
  final merged = <String, String>{
    'Accept': 'application/json, text/plain, */*',
    ...?headers,
  };
  if (cookieHeader != null && cookieHeader.trim().isNotEmpty) {
    merged['Cookie'] = cookieHeader.trim();
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.openUrl(method, uri);
    merged.forEach((k, v) => req.headers.set(k, v));
    if (body != null) req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final cookies = <String, String>{};
    for (final raw in res.headers[HttpHeaders.setCookieHeader] ?? const []) {
      final seg = raw.split(';').first.trim();
      final idx = seg.indexOf('=');
      if (idx > 0) cookies[seg.substring(0, idx).trim()] = seg.substring(idx + 1);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SodaRequestException('汽水 HTTP ${res.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      throw const SodaRequestException('汽水响应不是合法 JSON');
    }
    final json = decoded is Map<String, dynamic>
        ? decoded
        : (decoded is Map ? Map<String, dynamic>.from(decoded) : null);
    if (json == null) throw const SodaRequestException('汽水响应结构异常');
    return SodaRawResult(json, cookies);
  } on SodaRequestException {
    rethrow;
  } catch (err) {
    throw SodaRequestException('汽水网络请求失败: $err');
  } finally {
    client.close();
  }
}

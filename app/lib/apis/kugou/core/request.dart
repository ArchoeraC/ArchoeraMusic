/// KG 请求层——对齐 apis/kugou/core/request.ts。
///
/// 发一次 KG GET 请求返回 JSON body；失败直接抛错由上层 fallback 处理。
/// 成功码约定不统一：songsearch/mobilecdn 用 error_code=0，lyrics 用 error_code=200。
library;

import 'dart:convert';
import 'dart:io';

/// 发一次 KG GET 请求
Future<Map<String, dynamic>> kgRequest(
  String url, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(url));
    headers.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw StateError('KG HTTP ${res.statusCode}');
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final body = jsonDecode(utf8.decode(bytes, allowMalformed: true)) as Map<String, dynamic>;
    // 0 = mobilecdn/songsearch 风格成功码，200 = lyrics.kugou.com 的 HTTP 风格成功码
    final code = body['error_code'] ?? body['errcode'] ?? body['err_code'] ?? 0;
    if (code != 0 && code != 200) throw StateError('KG API error_code=$code');
    return body;
  } finally {
    client.close();
  }
}

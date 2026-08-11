/// 渲染层 HTTP 工具（对齐 src/services/streaming/http.ts）。
///
/// 统一超时、错误抽取、auth 错误识别。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'streaming_errors.dart';

/// 默认请求超时。
const streamingRequestTimeout = Duration(seconds: 30);

final HttpClient _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15);

/// 带超时的请求；超时抛 [StreamingTimeoutError]。
///
/// [body] 为 Map/List 时按 JSON 序列化；返回的响应由调用方读取后自行关闭。
Future<HttpClientResponse> fetchWithTimeout(
  String url, {
  String method = 'GET',
  Map<String, String>? headers,
  Object? body,
  Duration timeout = streamingRequestTimeout,
}) async {
  final req = await _client.openUrl(method, Uri.parse(url)).timeout(timeout);
  headers?.forEach(req.headers.set);
  if (body != null) {
    req.headers.contentType = ContentType.json;
    final bytes = body is List<int> ? body : utf8.encode(jsonEncode(body));
    req.contentLength = bytes.length;
    req.add(bytes);
  }
  try {
    return await req.close().timeout(timeout);
  } on TimeoutException {
    req.abort();
    throw StreamingTimeoutError('请求超时 (${timeout.inMilliseconds}ms)');
  }
}

/// 校验响应：401/403 → [StreamingAuthError]，其它非 2xx → [StreamingHttpError]。
void ensureOk(HttpClientResponse res) {
  final status = res.statusCode;
  if (status >= 200 && status < 300) return;
  if (status == 401 || status == 403) {
    throw StreamingAuthError('HTTP $status');
  }
  throw StreamingHttpError(status);
}

/// 标准化 baseUrl，去掉尾斜杠。
String normalizeBase(String url) => url.replaceAll(RegExp(r'/+$'), '');

/// 读完整响应体为字符串（供 JSON 接口用）。
Future<String> readBody(HttpClientResponse res) async =>
    res.transform(utf8.decoder).join();

/// URL encode 键值对 → query string。
String encodeQuery(Map<String, String> params) => params.entries
    .map((e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
    .join('&');

/// 流媒体客户端错误类型（对齐 src/services/streaming/errors.ts）。
///
/// 用具体类替代字符串模式匹配，便于调用方用 `is` 精确判断：
/// 鉴权失败 / 协议错误 / HTTP 错误 / 超时。
library;

import 'dart:io';

/// 错误归类码。
enum StreamingErrorCode { auth, network, protocol, unknown }

/// 流媒体客户端错误基类。
class StreamingError implements Exception {
  StreamingError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 鉴权失败（HTTP 401/403 / accessToken 缺失或过期 / Subsonic 40-44 错误码）。
class StreamingAuthError extends StreamingError {
  StreamingAuthError(super.message);
}

/// 协议错误（响应缺字段、status != ok 等）。
class StreamingProtocolError extends StreamingError {
  StreamingProtocolError(super.message);
}

/// HTTP 错误（非 2xx，且非 401）。
class StreamingHttpError extends StreamingError {
  StreamingHttpError(this.status, [String? message]) : super(message ?? 'HTTP $status');
  final int status;
}

/// 请求超时（fetchWithTimeout 触发的 TimeoutException）。
class StreamingTimeoutError extends StreamingError {
  StreamingTimeoutError(super.message);
}

/// 把任意 throw 出来的值归类成 [StreamingErrorCode]。
StreamingErrorCode classifyError(Object err) {
  if (err is StreamingAuthError) return StreamingErrorCode.auth;
  if (err is StreamingTimeoutError) return StreamingErrorCode.network;
  if (err is StreamingHttpError) {
    return err.status >= 500 ? StreamingErrorCode.network : StreamingErrorCode.protocol;
  }
  if (err is StreamingProtocolError) return StreamingErrorCode.protocol;
  // dart:io 在 DNS / 网络失败时抛 SocketException
  if (err is SocketException || err is HandshakeException) return StreamingErrorCode.network;
  return StreamingErrorCode.unknown;
}

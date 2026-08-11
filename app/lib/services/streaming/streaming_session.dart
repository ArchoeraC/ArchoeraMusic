/// PlaySessionId 生成（对齐 src/services/streaming/session.ts）。
///
/// Jellyfin/Emby stream URL 需要带 PlaySessionId 参数，用来在服务器端区分
/// 相邻两次解码上下文。trackId 不变则复用同一个 UUID。
library;

import 'dart:math';

final Random _rng = Random.secure();

/// 生成 RFC4122 v4 UUID。
String newUuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String? _lastTrackId;
String? _lastSessionId;

/// 取或生成 PlaySessionId；trackId 不变则复用。
String sessionIdForTrack(String trackId) {
  if (_lastTrackId == trackId && _lastSessionId != null) return _lastSessionId!;
  final sessionId = newUuid();
  _lastTrackId = trackId;
  _lastSessionId = sessionId;
  return sessionId;
}

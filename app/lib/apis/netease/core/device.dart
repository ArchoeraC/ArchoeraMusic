/// 进程级设备信息——对齐 apis/netease/core/device.ts。
///
/// - deviceId：52 位大写十六进制字符，进程启动时生成一次
/// - anonymous token：匿名态下注入 header 的 MUSIC_A（register_anonimous 返回后刷新）
library;

import 'dart:math';

String _generate() {
  final rng = Random.secure();
  return List.generate(26, (_) => rng.nextInt(16).toRadixString(16)).join().toUpperCase();
}

String _deviceId = _generate();
String _anonymousToken = '';

String nmGetDeviceId() => _deviceId;

void nmSetDeviceId(String id) => _deviceId = id;

String nmRegenerateDeviceId() {
  _deviceId = _generate();
  return _deviceId;
}

String nmGetAnonymousToken() => _anonymousToken;

void nmSetAnonymousToken(String token) => _anonymousToken = token;

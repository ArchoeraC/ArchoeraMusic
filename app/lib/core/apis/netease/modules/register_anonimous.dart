/// 注册匿名态（获取 MUSIC_A，对齐 register_anonimous.ts）
///
/// - 生成 52 位 hex deviceId
/// - 用 `${deviceId} ${md5(deviceId ^ ID_XOR_KEY_1)}` 做 Base64 作为 username
/// - 调用 xeapi 注册，将返回的 MUSIC_A 缓存到设备态
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/device.dart';
import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

const _idXorKey = '3go8&\$8*3*3h0k(2)2';

String _encodeId(String deviceId) {
  final xored = List<int>.generate(deviceId.length,
      (i) => deviceId.codeUnitAt(i) ^ _idXorKey.codeUnitAt(i % _idXorKey.length));
  return base64.encode(crypto.md5.convert(Uint8List.fromList(xored)).bytes);
}

NeteaseModule nmRegisterAnonimous = (query, request) async {
  final deviceId = nmRegenerateDeviceId();
  final username = base64.encode(utf8.encode('$deviceId ${_encodeId(deviceId)}'));
  final data = <String, dynamic>{'username': username};

  final result = await request('/api/register/anonimous', data, nmCreateOption(query, 'xeapi'));
  final body = result.body;

  if (body['code'] == 200) {
    if (body['token'] is String) nmSetAnonymousToken(body['token'] as String);
    return NeteaseResponse(
      status: 200,
      body: {...body, 'cookie': result.cookie.join(';')},
      cookie: result.cookie,
    );
  }
  return result;
};

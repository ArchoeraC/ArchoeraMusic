/// QRC 歌词解密（Dart 移植）——对齐 apis/qqmusic/core/qrc.ts。
///
/// QRC 解密流程：hex 解码 → Triple DES 解密 → Zlib 解压
/// （依次尝试 inflate / raw inflate / gzip；非压缩数据直接返回原文）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tripledes.dart';

/// QRC 解密密钥 - 24 字节（来源: LDDC 项目）
final Uint8List _qrcKey = Uint8List.fromList(utf8.encode('!@#)(*\$%123ZXC!@!@#)(NHL'));

/// hex 字符串 → 字节数组
Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 解密 QRC 歌词（云端版本）
String qmDecryptQrc(String encryptedQrc) {
  if (encryptedQrc.trim().isEmpty) {
    throw StateError('没有可解密的数据');
  }

  final encryptedData = _hexToBytes(encryptedQrc.trim());
  final decrypted = qmQrcDecrypt(encryptedData, _qrcKey);

  // Zlib 解压：依次尝试 inflate / raw inflate / gzip
  try {
    return utf8.decode(zlib.decode(decrypted));
  } catch (_) {}
  try {
    // Dart zlib 无 raw 选项，手动补 zlib 头再解压
    final raw = Uint8List(decrypted.length + 2)
      ..[0] = 0x78
      ..[1] = 0x9c
      ..setAll(2, decrypted);
    return utf8.decode(zlib.decode(raw));
  } catch (_) {}
  try {
    return utf8.decode(gzip.decode(decrypted));
  } catch (_) {}

  // 也可能本身就不是压缩数据
  final str = utf8.decode(decrypted, allowMalformed: true);
  if (str.contains('[') || str.contains('<')) return str;

  throw StateError('无法解压数据');
}

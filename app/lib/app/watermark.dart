// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 防伪标识（watermark）—— 请勿删除本文件与其中的入口函数。
///
/// 目的：把产品身份以**可验证的密码学签名**编译进 Dart AOT 快照（release 的
/// `libapp.so` / `app.so`）与内核快照（debug 的 `kernel_blob.bin`）。
///
/// 方案（比纯字符串更强，且**不影响启动**）：
///   - 用项目私钥（离线保管，绝不入库）对一段**规范负载** [archoeraWatermarkPayload]
///     做 ECDSA P-256 / SHA-256 签名；
///   - 把「公钥 + 负载 + 签名」作为常量编译进二进制；
///   - 任何人可凭**公开的公钥**独立验证该二进制确由官方密钥签发：下游拿走源码、
///     改个名字、重新打包，都无法在**不持有私钥**的情况下改动负载后重新签名；
///     一旦负载被篡改，[verifyArchoeraWatermark] 返回 false。
///
/// 优雅降级（关键约束）：验证失败 / 常量被剥离 / 私钥丢失，**都绝不阻断启动、
/// 绝不弹任何提示**——本模块只在被显式调用时做纯计算并返回布尔值。应用启动
/// 不依赖它的结果。
///
/// 保留机制：入口函数标注 `@pragma('vm:entry-point')`，AOT 树摇不会移除；
/// 函数体引用目标常量，保证字符串进入二进制字符串表。
///
/// 私钥位置（不入库、请离线备份）：`~/.config/archoera/watermark_ec_priv.pem`。
/// 重新签发见 `tool/sign_watermark.sh`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/export.dart';

/// 防伪标语（反编译可见的独立字符串）。
const String archoeraWatermark = 'ARCHOERA DESIGNED';

/// 被签名的规范负载（身份 + 许可证；不含版本，签名跨版本稳定）。
const String archoeraWatermarkPayload =
    'ARCHOERA DESIGNED|ArchoeraMusic|BetaStudio2|AGPL-3.0-or-later';

/// 签发公钥（ECDSA P-256，SEC1 未压缩点 `04||X||Y`，十六进制）。
/// 公开信息，可随仓库/README 发布，供第三方独立验证。
const String archoeraWatermarkPubKeyHex =
    '04390dd5c29b41427d4ebfa1bcf54231b027d12da30c02d5a75c613f1dc12bd3'
    '2d4c5421a3c11ac1cd23424567c472e72509c5958c61426db8071b27ec5350e42d';

/// 负载的 ECDSA(SHA-256) 签名（ASN.1 DER 十六进制）。
const String archoeraWatermarkSigDerHex =
    '30440220376a53d6fbcac4530400c6b60574fd777a30a171434032000b2f28cba7065ecd'
    '02201d2fe98cf786470e719474c991c631a6211af3b2927b1dcfaa36bc0cd0da690d';

/// 保留入口：确保独立标语字符串进入快照（AOT 树摇不移除 entry-point）。
@pragma('vm:entry-point')
String archoeraWatermarkEntry() => archoeraWatermark;

/// 启动锚点（`main()` 调用一次；仅为确保快照包含，无副作用）。
@pragma('vm:entry-point')
String archoeraWatermarkAnchor() => archoeraWatermarkEntry();

/// 官方构建徽标数据源：二进制内水印签名校验结果（纯计算、只读一次）。
/// 关于页据此显示「官方构建」图标；失败返回 false（不显示、不提示）。
final archoeraOfficialBuildProvider = Provider<bool>(
  (ref) => verifyArchoeraWatermark(),
);

/// 校验编译进本二进制的负载签名是否由官方私钥签发。
///
/// 纯计算、无副作用、不抛异常；任何失败（常量缺失/被改、解析失败、签名不匹配）
/// 一律返回 false —— **调用方不应据此阻断启动或弹提示**。第三方可自行调用或
/// 用公开公钥离线验证，以判断二进制是否官方签发。
@pragma('vm:entry-point')
bool verifyArchoeraWatermark() => _verify(
      archoeraWatermarkPayload,
      archoeraWatermarkPubKeyHex,
      archoeraWatermarkSigDerHex,
    );

/// 测试入口：对任意「负载/公钥/签名」做校验（供篡改回归）。
@visibleForTesting
bool verifyWatermarkData({
  required String payload,
  required String pubKeyHex,
  required String sigDerHex,
}) => _verify(payload, pubKeyHex, sigDerHex);

bool _verify(String payload, String pubKeyHex, String sigDerHex) {
  try {
    final msg = Uint8List.fromList(ascii.encode(payload));
    final sig = _parseEcdsaDer(_hexToBytes(sigDerHex));
    final curve = ECCurve_secp256r1();
    final q = curve.curve.decodePoint(_hexToBytes(pubKeyHex));
    if (q == null) return false;
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, curve)));
    return signer.verifySignature(msg, sig);
  } catch (_) {
    return false;
  }
}

/// 解析 ECDSA 签名 DER（`SEQUENCE { INTEGER r, INTEGER s }`，P-256 为短长度形式）。
ECSignature _parseEcdsaDer(Uint8List der) {
  var i = 0;
  int readLen() {
    var len = der[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7F;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | der[i++];
      }
    }
    return len;
  }

  if (der[i++] != 0x30) throw const FormatException('bad SEQUENCE');
  readLen(); // 整体长度（无需使用）
  if (der[i++] != 0x02) throw const FormatException('bad r');
  final rlen = readLen();
  final r = _bytesToBigInt(der.sublist(i, i + rlen));
  i += rlen;
  if (der[i++] != 0x02) throw const FormatException('bad s');
  final slen = readLen();
  final s = _bytesToBigInt(der.sublist(i, i + slen));
  return ECSignature(r, s);
}

BigInt _bytesToBigInt(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

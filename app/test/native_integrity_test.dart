// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 原生库完整性校验（SEC-08）测试：无需真实动态库，使用临时目录 + 自生成清单，
/// 覆盖通过 / 篡改 / 未登记 / 无清单（dev 跳过）四种情形，以及 key1 ECDSA
/// 分离签名（有效 / 篡改 / 无签名回退）三种情形。
///
/// 清单定位锚定可执行文件，故经 [NativeIntegrity.debugTestMode] +
/// [NativeIntegrity.debugBundleRoot] 接缝指向临时 bundle 根；验签公钥经
/// [NativeIntegrity.debugPublicKeyHex] 注入测试内自生成 P-256 密钥。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:archoera_music/services/native_integrity.dart';

/// RFC 6979 P-256 测试标量（固定 d 保证测试确定性；仅测试用自生成密钥，
/// 与官方 key1 无关）。
final BigInt _testD = BigInt.parse(
    'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721',
    radix: 16);

/// 未压缩点 `04||X||Y` 十六进制（64 位十六进制 / 坐标）。
String _pubHexOf(ECPoint q) {
  String hex(BigInt v) => v.toRadixString(16).padLeft(64, '0');
  return '04${hex(q.x!.toBigInteger()!)}${hex(q.y!.toBigInteger()!)}';
}

/// 用测试私钥对清单原文做 ECDSA(P-256/SHA-256) 签名，返回 DER 字节。
Uint8List _signText(String text, BigInt d) {
  final curve = ECCurve_secp256r1();
  // FortunaRandom 不自带熵源：显式固定种子（测试确定性；签名随机 k 无碍验签）。
  final rng = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List<int>.generate(32, (i) => i))));
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, curve)), rng));
  final sig = signer.generateSignature(
      Uint8List.fromList(ascii.encode(text))) as ECSignature;
  return _derEncode(sig.r, sig.s);
}

/// 最简 DER：`SEQUENCE { INTEGER r, INTEGER s }`（P-256 为短长度形式）。
Uint8List _derEncode(BigInt r, BigInt s) {
  List<int> intBytes(BigInt v) {
    var bytes = <int>[];
    var x = v;
    while (x > BigInt.zero) {
      bytes.insert(0, (x & BigInt.from(0xff)).toInt());
      x = x >> 8;
    }
    if (bytes.isEmpty) bytes = [0];
    if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return bytes;
  }

  final rb = intBytes(r);
  final sb = intBytes(s);
  final body = <int>[0x02, rb.length, ...rb, 0x02, sb.length, ...sb];
  return Uint8List.fromList([0x30, body.length, ...body]);
}

void main() {
  late Directory root;
  late Directory nativeDir;

  File manifest() => File('${nativeDir.path}/${NativeIntegrity.manifestName}');

  setUp(() {
    root = Directory.systemTemp.createTempSync('archoera-native-integrity-');
    nativeDir = Directory('${root.path}/native')..createSync(recursive: true);
    NativeIntegrity.debugTestMode = true;
    NativeIntegrity.debugBundleRoot = root.path;
    NativeIntegrity.resetForTest();
  });

  tearDown(() {
    NativeIntegrity.debugTestMode = false;
    NativeIntegrity.debugBundleRoot = null;
    NativeIntegrity.debugPublicKeyHex = null;
    NativeIntegrity.resetForTest();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('正确摘要通过；篡改后抛 StateError', () {
    final lib = File('${nativeDir.path}/libx.so')
      ..writeAsBytesSync(List<int>.generate(32, (i) => i));
    final digest = sha256.convert(lib.readAsBytesSync()).toString();
    manifest().writeAsStringSync('# 测试清单\n\n$digest  libx.so\n');

    expect(NativeIntegrity.manifestPresent, isTrue);
    expect(() => NativeIntegrity.verifyOrThrow(lib.path), returnsNormally);

    // 篡改内容 → 摘要不符（fail-closed）。
    lib.writeAsBytesSync(List<int>.filled(32, 9));
    expect(
      () => NativeIntegrity.verifyOrThrow(lib.path),
      throwsA(isA<StateError>()),
    );
  });

  test('清单存在但文件未登记 → 抛 StateError（fail-closed）', () {
    manifest().writeAsStringSync('${'a' * 64}  other.so\n');
    final lib = File('${nativeDir.path}/libx.so')..writeAsBytesSync([1, 2, 3]);
    expect(
      () => NativeIntegrity.verifyOrThrow(lib.path),
      throwsA(isA<StateError>()),
    );
  });

  test('文件缺失（无法读取）→ 抛 StateError（fail-closed）', () {
    manifest().writeAsStringSync('${'a' * 64}  libx.so\n');
    expect(
      () => NativeIntegrity.verifyOrThrow('${nativeDir.path}/libx.so'),
      throwsA(isA<StateError>()),
    );
  });

  test('无清单时跳过校验（dev）', () {
    final lib = File('${nativeDir.path}/libx.so')..writeAsBytesSync([1, 2, 3]);
    expect(NativeIntegrity.manifestPresent, isFalse);
    expect(() => NativeIntegrity.verifyOrThrow(lib.path), returnsNormally);
  });

  test('有效签名通过（自生成 P-256 公钥验签）', () {
    NativeIntegrity.debugPublicKeyHex =
        _pubHexOf((ECCurve_secp256r1().G * _testD)!);

    final lib = File('${nativeDir.path}/libx.so')
      ..writeAsBytesSync(List<int>.generate(32, (i) => i));
    final digest = sha256.convert(lib.readAsBytesSync()).toString();
    final text = '# test manifest\n\n$digest  libx.so\n';
    manifest().writeAsStringSync(text);
    File('${nativeDir.path}/${NativeIntegrity.manifestSignatureName}')
        .writeAsBytesSync(_signText(text, _testD));

    expect(NativeIntegrity.manifestPresent, isTrue);
    expect(() => NativeIntegrity.verifyOrThrow(lib.path), returnsNormally);
  });

  test('清单被篡改（签名失效）→ 先验签抛 StateError', () {
    NativeIntegrity.debugPublicKeyHex =
        _pubHexOf((ECCurve_secp256r1().G * _testD)!);

    final lib = File('${nativeDir.path}/libx.so')
      ..writeAsBytesSync(List<int>.generate(32, (i) => i));
    final digest = sha256.convert(lib.readAsBytesSync()).toString();
    final text = '# test manifest\n\n$digest  libx.so\n';
    manifest().writeAsStringSync(text);
    File('${nativeDir.path}/${NativeIntegrity.manifestSignatureName}')
        .writeAsBytesSync(_signText(text, _testD));

    // 攻击者换库 + 重算摘要（仅比摘要即可绕过）→ 签名必须拦住，先于摘要比对。
    manifest().writeAsStringSync('# test manifest\n\n${'b' * 64}  libx.so\n');
    expect(
      () => NativeIntegrity.verifyOrThrow(lib.path),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('签名'))),
    );
  });

  test('无签名清单回退 hash-only（合法通过 / 篡改抛摘要错）', () {
    final lib = File('${nativeDir.path}/libx.so')
      ..writeAsBytesSync(List<int>.generate(32, (i) => i));
    final digest = sha256.convert(lib.readAsBytesSync()).toString();
    manifest().writeAsStringSync('$digest  libx.so\n');

    // 无 .sig1 → 不验签，摘要匹配即通过
    expect(() => NativeIntegrity.verifyOrThrow(lib.path), returnsNormally);

    lib.writeAsBytesSync(List<int>.filled(32, 7));
    expect(
      () => NativeIntegrity.verifyOrThrow(lib.path),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('manifest 不匹配'))),
    );
  });
}

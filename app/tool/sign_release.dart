// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 发布产物**双签名/验签**（**跨平台**，纯 Dart，Windows/macOS/Linux 均可跑）。
///
/// 双控策略：用**两把独立私钥**各签一次 → `file.sig1` / `file.sig2`；
/// 两份签名都用公开公钥验过才算官方发布（单把私钥泄露不足以伪造）。
/// 与 `tool/sign_release.sh`（openssl 版）产出的 DER 签名互验一致。
///
/// 用法（在 app/ 目录）：
///   `ARCHOERA_WM_PRIVKEY_D=[key1标量hex] ARCHOERA_WM_PRIVKEY2_D=[key2标量hex] \
///     dart run tool/sign_release.dart sign [dir|file...]`
///   `dart run tool/sign_release.dart verify [dir|file...]`
///   `dart run tool/sign_release.dart pubkey`
///
/// 约定：key1 由 CI（Environment 审批）签 `.sig1`；key2 由维护者本地签 `.sig2`
/// （`ARCHOERA_WM_KEYS=2`），key2 不进 CI。`ARCHOERA_WM_KEYS` 选择本次签哪把
/// （默认 1,2）；均缺失时 `sign` 跳过并 0 退出。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 官方签发公钥 key1（ECDSA P-256，SEC1 未压缩点 hex；与 lib/app/watermark.dart 一致）。
const String _pub1Hex =
    '04390dd5c29b41427d4ebfa1bcf54231b027d12da30c02d5a75c613f1dc12bd3'
    '2d4c5421a3c11ac1cd23424567c472e72509c5958c61426db8071b27ec5350e42d';

/// 官方签发公钥 key2（双控第二把；仅发布签名，不参与二进制内水印）。
const String _pub2Hex =
    '046f4c898d899b45ad16031acbb99b35db5d5f17f913e765d7bf365d3cda500dc'
    'b0c66137f64abfacec01a3e7072554bd19af8c6fc6d35598bca614ca2f0530c8e';

/// 参与签名的产物后缀。
const List<String> _artifactSuffixes = [
  '.tar.gz',
  '.tar.xz',
  '.deb',
  '.rpm',
  '.AppImage',
  '.pkg.tar.zst',
  '.zip',
  '.exe',
];

void main(List<String> args) {
  if (args.isEmpty) {
    _usage();
    exit(2);
  }
  final cmd = args.first;
  final targets = args.sublist(1);
  switch (cmd) {
    case 'sign':
      exit(_sign(targets));
    case 'verify':
      exit(_verify(targets));
    case 'pubkey':
      stdout.writeln('key1=$_pub1Hex');
      stdout.writeln('key2=$_pub2Hex');
    default:
      _usage();
      exit(2);
  }
}

void _usage() {
  stderr.writeln(
    'usage: dart run tool/sign_release.dart <sign|verify|pubkey> [dir|file ...]',
  );
}

List<File> _collect(List<String> targets) {
  final out = <File>[];
  for (final t in targets) {
    final e = FileSystemEntity.typeSync(t);
    if (e == FileSystemEntityType.directory) {
      for (final f in Directory(t).listSync()) {
        if (f is File && _isArtifact(f.path)) out.add(f);
      }
      final sums = File('$t/SHA256SUMS');
      if (sums.existsSync()) out.add(sums);
    } else if (e == FileSystemEntityType.file) {
      out.add(File(t));
    }
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

bool _isArtifact(String path) {
  if (path.endsWith('SHA256SUMS')) return false;
  if (path.endsWith('.sig1') || path.endsWith('.sig2')) return false;
  return _artifactSuffixes.any(path.endsWith);
}

int _sign(List<String> targets) {
  final keys = Platform.environment['ARCHOERA_WM_KEYS']?.trim() ?? '1,2';
  final d1 = keys.contains('1')
      ? (Platform.environment['ARCHOERA_WM_PRIVKEY_D']?.trim() ?? '')
      : '';
  final d2 = keys.contains('2')
      ? (Platform.environment['ARCHOERA_WM_PRIVKEY2_D']?.trim() ?? '')
      : '';
  if (d1.isEmpty && d2.isEmpty) {
    stderr.writeln(
      '[sign] 未提供私钥（ARCHOERA_WM_KEYS=$keys；ARCHOERA_WM_PRIVKEY_D/_PRIVKEY2_D），跳过签名（退出 0）',
    );
    return 0;
  }
  final files = _collect(targets);
  if (files.isEmpty) {
    stderr.writeln('[sign] 未找到可签名产物（$targets）');
    return 1;
  }
  final signers = <String, ECDSASigner>{};
  if (d1.isNotEmpty) signers['sig1'] = _signerFor(d1);
  if (d2.isNotEmpty) signers['sig2'] = _signerFor(d2);

  final sums = StringBuffer();
  for (final f in files) {
    final bytes = f.readAsBytesSync();
    sums.writeln('${sha256.convert(bytes)}  ${_basename(f.path)}');
    signers.forEach((ext, signer) {
      final sig = signer.generateSignature(bytes) as ECSignature;
      File('${f.path}.$ext').writeAsBytesSync(_encodeDer(sig));
      stdout.writeln('→ ${f.path}.$ext');
    });
  }
  final dir = File(files.first.path).parent.path;
  File('$dir/SHA256SUMS').writeAsStringSync(sums.toString());
  final sumsBytes = File('$dir/SHA256SUMS').readAsBytesSync();
  signers.forEach((ext, signer) {
    final sig = signer.generateSignature(sumsBytes) as ECSignature;
    File('$dir/SHA256SUMS.$ext').writeAsBytesSync(_encodeDer(sig));
  });
  stdout.writeln('→ $dir/SHA256SUMS(+.sig1/.sig2)');
  return 0;
}

int _verify(List<String> targets) {
  final pub1 = _envOr('ARCHOERA_WM_PUBKEY_HEX', _pub1Hex);
  final pub2 = _envOr('ARCHOERA_WM_PUBKEY2_HEX', _pub2Hex);
  final v1 = _verifierFor(pub1);
  final v2 = _verifierFor(pub2);

  final files = _collect(targets);
  var fail = 0;
  for (final f in files) {
    final ok1 = _verifyOne(v1, f, 'sig1');
    final ok2 = _verifyOne(v2, f, 'sig2');
    final ok = ok1 && ok2;
    stdout.writeln('${ok ? 'OK  ' : 'BAD '} key1=$ok1 key2=$ok2  ${f.path}');
    if (!ok) fail = 1;
  }
  return fail;
}

String _envOr(String key, String fallback) {
  final v = Platform.environment[key]?.trim() ?? '';
  return v.isEmpty ? fallback : v;
}

ECDSASigner _signerFor(String dHex) {
  final curve = ECCurve_secp256r1();
  final priv = ECPrivateKey(BigInt.parse(dHex, radix: 16), curve);
  // RFC 6979 确定性 ECDSA（HMAC-SHA256 作 k），免 SecureRandom 注册依赖。
  return ECDSASigner(SHA256Digest(), HMac.withDigest(SHA256Digest()))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(priv));
}

ECDSASigner _verifierFor(String pubHex) {
  final curve = ECCurve_secp256r1();
  final q = curve.curve.decodePoint(_hexToBytes(pubHex));
  if (q == null) throw const FormatException('bad public key');
  return ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, curve)));
}

bool _verifyOne(ECDSASigner verifier, File f, String ext) {
  final sigFile = File('${f.path}.$ext');
  if (!sigFile.existsSync()) return false;
  try {
    return verifier.verifySignature(
      f.readAsBytesSync(),
      _parseDer(sigFile.readAsBytesSync()),
    );
  } catch (_) {
    return false;
  }
}

// ── ECDSA 签名 DER 编解码（P-256，短长度形式）────────────────────────

Uint8List _encodeDer(ECSignature sig) {
  final r = _intBytes(sig.r);
  final s = _intBytes(sig.s);
  final body = <int>[0x02, r.length, ...r, 0x02, s.length, ...s];
  return Uint8List.fromList([0x30, body.length, ...body]);
}

List<int> _intBytes(BigInt v) {
  var bytes = v.toRadixString(16);
  if (bytes.length.isOdd) bytes = '0$bytes';
  var b = <int>[
    for (var i = 0; i < bytes.length; i += 2)
      int.parse(bytes.substring(i, i + 2), radix: 16),
  ];
  if (b.isEmpty) b = [0];
  if (b[0] & 0x80 != 0) b = [0, ...b];
  return b;
}

ECSignature _parseDer(Uint8List der) {
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
  readLen();
  if (der[i++] != 0x02) throw const FormatException('bad r');
  final rlen = readLen();
  final r = _bigInt(der.sublist(i, i + rlen));
  i += rlen;
  if (der[i++] != 0x02) throw const FormatException('bad s');
  final slen = readLen();
  final s = _bigInt(der.sublist(i, i + slen));
  return ECSignature(r, s);
}

BigInt _bigInt(List<int> b) {
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

String _basename(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i < 0 ? path : path.substring(i + 1);
}

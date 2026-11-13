// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG 设备身份（字段与取值约定来源：KuGouMusicApi `util/util.js`，MIT）。
///
/// 风控要点：同一安装必须长期复用同一套 GUID / MID / DEV / MAC / WebGL
/// 指纹，`register_dev` 返回的 dfid 也应持久化复用。每次启动、甚至每次
/// 请求随机换设备，会被酷狗判定为「设备农场」，是账号被风控的高危信号。
library;

import 'dart:math';

import 'kugou_crypto.dart';

/// 设备名（DEV）字符池，与 KuGouMusicApi `randomString` 一致。
const _kgDevPool = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// KG 安装级设备身份。
class KugouDevice {
  const KugouDevice({
    required this.guid,
    required this.mid,
    required this.dev,
    required this.mac,
    required this.webgl,
    this.dfid = '',
  });

  /// 设备 GUID（UUID v4，带连字符；请求里对应 KUGOU_API_GUID）。
  final String guid;

  /// 设备 MID：`md5(guid)` 的十六进制按大整数转十进制（KU 客户端算法）。
  final String mid;

  /// 设备名（10 位大写；请求里对应 KUGOU_API_DEV）。
  final String dev;

  /// 设备 MAC（固定值；不暴露真实网卡地址）。
  final String mac;

  /// WebGL 指纹哈希（随机 uint64 十进制；SSA 行为指纹会带上）。
  final String webgl;

  /// `register_dev` 返回的设备指纹；为空表示尚未注册。
  final String dfid;

  KugouDevice withDfid(String value) => KugouDevice(
    guid: guid,
    mid: mid,
    dev: dev,
    mac: mac,
    webgl: webgl,
    dfid: value,
  );

  Map<String, String> toJson() => {
    'guid': guid,
    'mid': mid,
    'dev': dev,
    'mac': mac,
    'webgl': webgl,
    if (dfid.isNotEmpty) 'dfid': dfid,
  };

  factory KugouDevice.fromJson(Map<String, String> json) {
    final guid = (json['guid'] ?? '').trim();
    final mid = (json['mid'] ?? '').trim();
    final dev = (json['dev'] ?? '').trim();
    final mac = (json['mac'] ?? '').trim();
    final webgl = (json['webgl'] ?? '').trim();
    return KugouDevice(
      guid: guid,
      mid: mid.isEmpty ? kgCalcMid(guid) : mid,
      dev: dev,
      mac: mac.isEmpty ? _defaultMac : mac,
      webgl: webgl,
      dfid: (json['dfid'] ?? '').trim(),
    );
  }

  /// 生成一套新的设备身份；仅在首次运行或用户显式重置设备时调用。
  factory KugouDevice.generate([Random? random]) {
    final rng = random ?? Random.secure();
    final guid = _uuidV4(rng);
    return KugouDevice(
      guid: guid,
      mid: kgCalcMid(guid),
      dev: _randomDev(rng),
      mac: _defaultMac,
      webgl: _randomUint64(rng),
    );
  }

  @override
  String toString() =>
      'KugouDevice(mid=${mid.length > 8 ? '${mid.substring(0, 8)}…' : mid}, '
      'dev=$dev, dfid=${dfid.isEmpty ? '-' : 'set'})';
}

/// 固定 MAC：不暴露真实网卡地址，同时保持安装级身份稳定。
const _defaultMac = '02:00:00:00:00:00';

String _randomDev(Random rng) => String.fromCharCodes(
  List.generate(
    10,
    (_) => _kgDevPool.codeUnitAt(rng.nextInt(_kgDevPool.length)),
  ),
);

String _uuidV4(Random rng) {
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _randomUint64(Random rng) {
  final hi = (rng.nextInt(1 << 30) << 2) | rng.nextInt(4);
  final lo = (rng.nextInt(1 << 30) << 2) | rng.nextInt(4);
  return ((BigInt.from(hi) << 32) | BigInt.from(lo)).toString();
}

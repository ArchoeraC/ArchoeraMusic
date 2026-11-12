// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQ 音乐**安装级设备身份**。
///
/// 风控要点：QQ 移动端协议（`musicu.fcg` 的 Android comm）会用
/// `udid / OpenUDID / QIMEI36 / aid / phonetype` 组成设备指纹。旧实现把这些
/// 字段全写成 `'0'`，并且每次取流（`song_url`）都随机生成一个新的 32 位 GUID：
///
/// - 全零指纹 = 最典型的脚本/爬虫特征；
/// - 每次请求换 GUID = 「设备农场」特征（服务端看到同一账号在无数台设备上
///   取流），这是账号级限流（`inner=2001`）与风控踢登录的主要来源。
///
/// 因此本文件按 Kugou 同样的思路生成**一次、长期复用**的设备身份：
/// `guid / udid / OpenUDID / androidId / imei` 与设备档案（机型/系统/版本号）
/// 一起持久化到宿主会话存储（平台键 `qqmusic_device`），跨重启不变；只有
/// 首次运行或用户显式「重置设备」时才重新生成。
///
/// 本文件只做本地身份，不联网；服务端签发的 QIMEI 在 `core/qimei.dart`。
library;

import 'dart:math';

import '../../runtime.dart';

/// 宿主会话存储里保存 QQ 设备身份的键。
const String qqDevicePlatform = 'qqmusic_device';

/// 一台「自洽」的 Android 设备档案（机型 / 系统 / 客户端版本必须互相匹配）。
class QqDeviceProfile {
  const QqDeviceProfile({
    required this.key,
    required this.brand,
    required this.manufacturer,
    required this.model,
    required this.board,
    required this.device,
    required this.product,
    required this.host,
    required this.osVer,
    required this.sdk,
    required this.cv,
  });

  /// 档案标识（仅用于诊断/序列化）。
  final String key;
  final String brand;
  final String manufacturer;
  final String model;
  final String board;
  final String device;
  final String product;
  final String host;

  /// Android 版本号（例如 `15`）。
  final String osVer;

  /// Android API level（例如 `35`）。
  final int sdk;

  /// QQ 音乐 Android 客户端版本号（同时用于 comm.cv/v 与 UA）。
  final int cv;
}

/// 已知档案：机型、主板、厂商、系统版本、客户端版本互相自洽。
///
/// 客户端版本统一 14.9.0.8（`14090008`），与 QIMEI 上报的 appVersion 一致，
/// 避免出现「UA 说 14.9、comm 说 14.9、QIMEI 说 20.9」这种明显拼凑的组合。
const List<QqDeviceProfile> _profiles = <QqDeviceProfile>[
  QqDeviceProfile(
    key: 'xiaomi',
    brand: 'Xiaomi',
    manufacturer: 'Xiaomi',
    model: '24122RKC7C',
    board: 'sun',
    device: 'dada',
    product: 'dada',
    host: 'se.infra',
    osVer: '15',
    sdk: 35,
    cv: 14090008,
  ),
  QqDeviceProfile(
    key: 'vivo',
    brand: 'vivo',
    manufacturer: 'vivo',
    model: 'V2408A',
    board: 'sun',
    device: 'PD2408',
    product: 'PD2408',
    host: 'comdg01150014',
    osVer: '15',
    sdk: 35,
    cv: 14090008,
  ),
  QqDeviceProfile(
    key: 'oppo',
    brand: 'OPPO',
    manufacturer: 'OPPO',
    model: 'PKB110',
    board: 'mt6991',
    device: 'OP5A3DL1',
    product: 'PKB110',
    host: 'localhost',
    osVer: '15',
    sdk: 35,
    cv: 14090008,
  ),
];

const String _hexPool = '0123456789abcdef';

String _hex(Random rng, int n) =>
    List<String>.generate(n, (_) => _hexPool[rng.nextInt(16)]).join();

/// 生成满足 Luhn 校验的 IMEI（服务端会做格式校验，随机 15 位数字很容易被判无效）。
String _luhnImei(Random rng) {
  final digits = List<int>.generate(14, (_) => rng.nextInt(10));
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    var d = digits[i];
    if (i.isOdd) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  final check = (10 - (sum % 10)) % 10;
  return '${digits.join()}$check';
}

/// QQ 安装级设备身份。
class QqDevice {
  const QqDevice({
    required this.profileKey,
    required this.guid,
    required this.udid,
    required this.openUdid,
    required this.androidId,
    required this.imei,
    required this.qimei16,
    required this.qimei36,
    required this.qimeiSavedAt,
  });

  /// 设备档案 key（见 `_profiles`）。
  final String profileKey;

  /// 客户端 GUID（32 位小写 hex）——**必须跨请求、跨重启稳定**。
  final String guid;

  /// `comm.udid`。
  final String udid;

  /// `comm.OpenUDID`。
  final String openUdid;

  /// Android ID（16 位 hex，QIMEI 注册时上报，也是 `comm.aid`）。
  final String androidId;

  /// 设备 IMEI（Luhn 合法；QIMEI 注册时上报）。
  final String imei;

  /// 服务端签发的 QIMEI16（未注册时为空）。
  final String qimei16;

  /// 服务端签发的 QIMEI36（未注册时为空）。
  final String qimei36;

  /// QIMEI 签发/缓存时间（秒；0 = 未注册）。
  final int qimeiSavedAt;

  /// 当前设备档案。
  QqDeviceProfile get profile => _profiles.firstWhere(
    (p) => p.key == profileKey,
    orElse: () => _profiles.first,
  );

  /// 客户端版本号（comm.cv / comm.v / UA）。
  int get cv => profile.cv;

  /// Android 版本号（comm.os_ver）。
  String get osVer => profile.osVer;

  /// 机型（comm.phonetype）。
  String get model => profile.model;

  /// 统一的 QQ 音乐 Android UA。
  String get userAgent => 'QQMusic $cv(android $osVer)';

  /// QIMEI 是否仍然可用（服务端建议 24h 更新一次）。
  bool get qimeiFresh {
    if (qimei36.isEmpty || qimei16.isEmpty || qimeiSavedAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now - qimeiSavedAt < 24 * 60 * 60;
  }

  QqDevice copyWith({String? qimei16, String? qimei36, int? qimeiSavedAt}) =>
      QqDevice(
        profileKey: profileKey,
        guid: guid,
        udid: udid,
        openUdid: openUdid,
        androidId: androidId,
        imei: imei,
        qimei16: qimei16 ?? this.qimei16,
        qimei36: qimei36 ?? this.qimei36,
        qimeiSavedAt: qimeiSavedAt ?? this.qimeiSavedAt,
      );

  Map<String, String> toJson() => <String, String>{
    'profile': profileKey,
    'guid': guid,
    'udid': udid,
    'openUdid': openUdid,
    'androidId': androidId,
    'imei': imei,
    if (qimei16.isNotEmpty) 'qimei16': qimei16,
    if (qimei36.isNotEmpty) 'qimei36': qimei36,
    if (qimeiSavedAt > 0) 'qimeiSavedAt': '$qimeiSavedAt',
  };

  /// 从持久化字段恢复；缺字段时按已有 GUID 补齐（保证不产生新的设备身份）。
  factory QqDevice.fromJson(Map<String, String> json) {
    final guid = (json['guid'] ?? '').trim();
    final profileKey = (json['profile'] ?? '').trim();
    return QqDevice(
      profileKey: profileKey.isEmpty ? _profiles.first.key : profileKey,
      guid: guid,
      udid: (json['udid'] ?? guid).trim(),
      openUdid: (json['openUdid'] ?? guid).trim(),
      androidId: (json['androidId'] ?? '').trim(),
      imei: (json['imei'] ?? '').trim(),
      qimei16: (json['qimei16'] ?? '').trim(),
      qimei36: (json['qimei36'] ?? '').trim(),
      qimeiSavedAt: int.tryParse(json['qimeiSavedAt'] ?? '') ?? 0,
    );
  }

  /// 生成一套新设备身份（只在首次运行 / 显式重置时调用）。
  factory QqDevice.generate([Random? random]) {
    final rng = random ?? Random.secure();
    final profile = _profiles[rng.nextInt(_profiles.length)];
    final guid = _hex(rng, 32);
    return QqDevice(
      profileKey: profile.key,
      guid: guid,
      udid: guid,
      openUdid: _hex(rng, 32),
      androidId: _hex(rng, 16),
      imei: _luhnImei(rng),
      qimei16: '',
      qimei36: '',
      qimeiSavedAt: 0,
    );
  }

  /// 持久化字段是否完整（缺 androidId/imei 说明是旧版本写入，需要重建）。
  bool get isComplete =>
      guid.length == 32 && udid.isNotEmpty && openUdid.isNotEmpty &&
      androidId.length == 16 && imei.length == 15;

  @override
  String toString() =>
      'QqDevice($profileKey, guid=${guid.substring(0, 8)}…, '
      'qimei=${qimei36.isEmpty ? '-' : 'set'})';
}

/// 进程内缓存（会话存储锁定期间不固化，见 `core/request.dart` 的
/// `qmReloadQQMusicDevice`）。
QqDevice? _cached;

/// 当前设备身份（首次调用时从会话存储恢复或生成）。
///
/// 只有 `qmReloadQQMusicDevice()`（解锁成功 / 显式重置）才会丢弃缓存。
QqDevice qmGetDevice() {
  final cached = _cached;
  if (cached != null) return cached;
  final store = getRuntime().sessionStore;
  final saved = store.get(qqDevicePlatform);
  if (saved.isNotEmpty) {
    final restored = QqDevice.fromJson(saved);
    if (restored.isComplete) {
      _cached = restored;
      return restored;
    }
  }
  // 凭据库锁定期间**不得**生成并落盘：否则解锁后会读到锁定期写入的假设备，
  // 与真实的登录设备错位（与 cookies 缓存污染同源，2026-10-14 实录）。
  if (store.isLocked) {
    return _cached = QqDevice.generate();
  }
  final created = QqDevice.generate();
  store.save(qqDevicePlatform, created.toJson());
  _cached = created;
  return created;
}

/// 更新内存/持久化设备（QIMEI 注册成功后调用）。
void qmSaveDevice(QqDevice device) {
  _cached = device;
  final store = getRuntime().sessionStore;
  if (store.isLocked) return; // 锁定期间不写盘：解锁后还会重新注册
  store.save(qqDevicePlatform, device.toJson());
}

/// 丢弃设备缓存（凭据库解锁 / 显式重置设备后调用）。
void qmReloadQQMusicDevice() => _cached = null;

/// 显式重置设备身份（设置项「换设备」；正常情况下不该发生）。
QqDevice qmResetQQMusicDevice({Random? random}) {
  final created = QqDevice.generate(random);
  qmSaveDevice(created);
  return created;
}

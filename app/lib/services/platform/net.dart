// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 网络（WiFi）与蓝牙的领域模型 + 抽象服务接口。
///
/// UI 只依赖本文件的类型；具体实现见 `ffi_net.dart`（走 `apl_*` 原生桥接）。
/// 约定：后端不可用（未实现平台 / 无 NetworkManager / 无 BlueZ / 无适配器）时，
/// 实现返回空列表与 `present=false`，**不抛异常**，由 UI 渲染对应的空状态。
///
/// 枚举策略参考 Plasma：只展示「有意义且可用」的设备——WiFi 侧过滤掉隐藏/虚拟
/// 网络，蓝牙侧只列有可读名的 `org.bluez.Device1`（不把 adapter/内部对象倒出来）。
library;

/// WiFi 安全类型（与桥接层的 `APL_WIFI_SEC_*` 一一对应）。
enum WifiSecurity {
  open,
  wep,
  psk,
  enterprise,
  unknown;

  /// 连接前是否需要用户输入密码。未知类型也按需要处理（避免静默失败）。
  bool get needsPassword => this != WifiSecurity.open;
}

/// 扫描到的一个 AP。
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.security,
    this.connected = false,
    this.saved = false,
    this.frequencyMhz = 0,
  });

  final String ssid;

  /// 信号强度 0-100。
  final int signal;
  final WifiSecurity security;
  final bool connected;

  /// 已有保存的连接配置（可直接免密重连）。
  final bool saved;

  /// 频段（MHz）：24xx = 2.4G，5xxx = 5G；0 = 未知。
  ///
  /// 之所以要暴露它：5GHz AP 需要内核有管制数据库（wireless-regdb）才会出现在
  /// 扫描结果里，否则用户会以为「不支持 5GHz」。UI 标出频段便于确认。
  final int frequencyMhz;

  /// 是否 5GHz（4900MHz 以上）。
  bool get is5Ghz => frequencyMhz >= 4900;
}

/// WiFi 概况快照。
class WifiState {
  const WifiState({
    this.present = false,
    this.enabled = false,
    this.connected = false,
    this.signal = -1,
    this.ssid = '',
    this.ip = '',
    this.security = WifiSecurity.unknown,
  });

  /// 系统存在无线设备（rfkill/NetworkManager 可见）。
  final bool present;

  /// 无线总开关已打开。
  final bool enabled;
  final bool connected;

  /// 当前连接信号 0-100；未连接为 -1。
  final int signal;
  final String ssid;
  final String ip;
  final WifiSecurity security;
}

/// 一个蓝牙设备。
class BtDevice {
  const BtDevice({
    required this.address,
    this.name = '',
    this.paired = false,
    this.connected = false,
    this.rssi = 0,
  });

  /// "AA:BB:CC:DD:EE:FF"。
  final String address;

  /// 可读名（可能为空，此时用 [displayName] 回退地址）。
  final String name;
  final bool paired;
  final bool connected;

  /// 扫描期间信号 dBm；未知为 0。
  final int rssi;

  String get displayName => name.isNotEmpty ? name : address;
}

/// 当前系统的连接能力（决定设置里是否显示「网络与蓝牙」分类）。
class NetAvailability {
  const NetAvailability({this.wifi = false, this.bluetooth = false});

  final bool wifi;
  final bool bluetooth;

  bool get any => wifi || bluetooth;
}

/// 网络与蓝牙的服务接口。
abstract interface class NetService {
  /// 探测一次能力（进程内缓存；用于设置分类可见性）。
  NetAvailability availability();

  // ── WiFi ────────────────────────────────────────────────────────
  Future<WifiState> wifiState();

  /// 触发扫描并等待结果（可能耗时数百毫秒）。
  Future<List<WifiNetwork>> wifiScan();

  /// 连接；[password] 为空表示开放网络或已有保存配置。
  Future<bool> wifiConnect(String ssid, {String? password});

  Future<void> wifiDisconnect();
  Future<void> wifiSetEnabled(bool on);

  /// 删除已保存的连接配置。
  Future<void> wifiForget(String ssid);

  // ── 蓝牙 ────────────────────────────────────────────────────────
  /// 开始/停止发现（配对前通常需要先开始）。
  Future<void> btScanStart();
  Future<void> btScanStop();

  /// 已知设备（含刚发现的）；实现侧应过滤掉无名的内部对象。
  Future<List<BtDevice>> btDevices();

  Future<bool> btPair(String address);
  Future<bool> btConnect(String address);
  Future<void> btDisconnect(String address);
  Future<void> btForget(String address);
  Future<void> btSetEnabled(bool on);
}

/// 占位实现：后端尚未接入时让 UI 正常渲染空状态（不抛错）。
class UnavailableNetService implements NetService {
  const UnavailableNetService();

  @override
  NetAvailability availability() => const NetAvailability();

  @override
  Future<WifiState> wifiState() async => const WifiState();

  @override
  Future<List<WifiNetwork>> wifiScan() async => const <WifiNetwork>[];

  @override
  Future<bool> wifiConnect(String ssid, {String? password}) async => false;

  @override
  Future<void> wifiDisconnect() async {}

  @override
  Future<void> wifiSetEnabled(bool on) async {}

  @override
  Future<void> wifiForget(String ssid) async {}

  @override
  Future<void> btScanStart() async {}

  @override
  Future<void> btScanStop() async {}

  @override
  Future<List<BtDevice>> btDevices() async => const <BtDevice>[];

  @override
  Future<bool> btPair(String address) async => false;

  @override
  Future<bool> btConnect(String address) async => false;

  @override
  Future<void> btDisconnect(String address) async {}

  @override
  Future<void> btForget(String address) async {}

  @override
  Future<void> btSetEnabled(bool on) async {}
}

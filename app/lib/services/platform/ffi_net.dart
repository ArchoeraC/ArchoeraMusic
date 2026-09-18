// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NetService 的 FFI 实现（走 apl_wifi_* / apl_bt_*）。
///
/// 桥接侧全程无子进程（NetworkManager / BlueZ 都经 D-Bus）。这里只做类型转换与转发，
/// 并把「符号缺失/后端不可用」统一降级为空结果，UI 据此渲染空状态。
library;

import 'net.dart';
import 'platform_bindings.dart';

class FfiNet implements NetService {
  FfiNet(this._b);

  final PlatformBindings _b;

  @override
  NetAvailability availability() => NetAvailability(
    wifi: _b.wifiSymbolsAvailable,
    bluetooth: _b.bluetoothControlSymbolsAvailable,
  );

  @override
  Future<WifiState> wifiState() async => _b.netWifiState() ?? const WifiState();

  @override
  Future<List<WifiNetwork>> wifiScan() async {
    // 桥接侧的 RequestScan 是异步的：触发后立刻读只会拿到旧列表（5GHz AP 往往要等
    // 整轮扫描结束才出现）。这里触发一次、稍等、再读一次 —— 不阻塞桥接线程。
    _b.netWifiScan();
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    return _b.netWifiScan();
  }

  @override
  Future<bool> wifiConnect(String ssid, {String? password}) async =>
      _b.netWifiConnect(ssid, password: password);

  @override
  Future<void> wifiDisconnect() async {
    _b.netWifiDisconnect();
  }

  @override
  Future<void> wifiSetEnabled(bool on) async {
    _b.netWifiSetEnabled(on);
  }

  @override
  Future<void> wifiForget(String ssid) async {
    _b.netWifiForget(ssid);
  }

  @override
  Future<void> btScanStart() async {
    _b.netBtScanStart();
  }

  @override
  Future<void> btScanStop() async {
    _b.netBtScanStop();
  }

  @override
  Future<List<BtDevice>> btDevices() async => _b.netBtDevices();

  @override
  Future<bool> btPair(String address) async => _b.netBtPair(address);

  @override
  Future<bool> btConnect(String address) async => _b.netBtConnect(address);

  @override
  Future<void> btDisconnect(String address) async {
    _b.netBtDisconnect(address);
  }

  @override
  Future<void> btForget(String address) async {
    _b.netBtForget(address);
  }

  @override
  Future<void> btSetEnabled(bool on) async {
    _b.netBtSetEnabled(on);
  }
}

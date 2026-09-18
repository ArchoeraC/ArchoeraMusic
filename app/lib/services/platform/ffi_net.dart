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
    // 桥接侧的 RequestScan 是异步的（触发后就返回）。这里先触发一次，再轮询到
    // 结果发生变化（出现新的 SSID）或超时 —— 固定 sleep 在慢扫描时会拿到旧列表，
    // 5GHz AP 尤其容易漏。
    final before = _b.netWifiScan();
    final beforeSsids = before.map((n) => n.ssid).toSet();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final now = _b.netWifiScan();
      if (now.length != before.length ||
          now.any((n) => !beforeSsids.contains(n.ssid))) {
        return now;
      }
    }
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
  int btPairStart(String address) => _b.netBtPairStart(address);

  @override
  int btPairReply(bool accept, String? text) => _b.netBtPairReply(accept, text);

  @override
  Stream<BtPairPrompt> get btPairPrompts => _b.btPairPromptEvents.map(
    (e) => BtPairPrompt(
      kind: switch (e.kind) {
        1 => BtPairPromptKind.confirm,
        2 => BtPairPromptKind.enterPin,
        3 => BtPairPromptKind.enterPasskey,
        4 => BtPairPromptKind.display,
        5 => BtPairPromptKind.authorize,
        _ => BtPairPromptKind.unknown,
      },
      passkey: e.passkey,
      entered: e.entered,
      text: e.text,
    ),
  );

  @override
  Stream<BtPairResult> get btPairResults =>
      _b.btPairResultEvents.map((e) => BtPairResult(ok: e.ok, err: e.err));

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

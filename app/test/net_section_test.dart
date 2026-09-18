// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 设置 → 网络与蓝牙回归：
//  - WiFi：列出可用网络、连接（含密码流程）、断开、忘记；IP 会显示在状态行；
//  - 蓝牙：配对 / 连接 / 断开 / 忘记；
//  - 「不可用设备默认隐藏 + 可展开」：无信号 AP 与无名蓝牙对象默认不出现。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/platform/net.dart';
import 'package:archoera_music/services/platform/platform_capabilities.dart';
import 'package:archoera_music/services/platform/system_status.dart';
import 'package:archoera_music/settings/settings_categories.dart';
import 'package:archoera_music/settings/settings_sections.dart';

class _FakeNet implements NetService {
  _FakeNet({required this.wifi, required this.networks, required this.devices});

  WifiState wifi;
  List<WifiNetwork> networks;
  List<BtDevice> devices;

  final List<String> calls = [];

  @override
  NetAvailability availability() =>
      const NetAvailability(wifi: true, bluetooth: true);

  @override
  Future<WifiState> wifiState() async => wifi;

  @override
  Future<List<WifiNetwork>> wifiScan() async => networks;

  @override
  Future<bool> wifiConnect(String ssid, {String? password}) async {
    calls.add('wifiConnect:$ssid:${password ?? ''}');
    return true;
  }

  @override
  Future<void> wifiDisconnect() async => calls.add('wifiDisconnect');

  @override
  Future<void> wifiSetEnabled(bool on) async => calls.add('wifiEnabled:$on');

  @override
  Future<void> wifiForget(String ssid) async => calls.add('wifiForget:$ssid');

  @override
  Future<void> btScanStart() async => calls.add('btScanStart');

  @override
  Future<void> btScanStop() async => calls.add('btScanStop');

  @override
  Future<List<BtDevice>> btDevices() async => devices;

  @override
  Future<bool> btPair(String address) async {
    calls.add('btPair:$address');
    return true;
  }

  @override
  Future<bool> btConnect(String address) async {
    calls.add('btConnect:$address');
    return true;
  }

  @override
  Future<void> btDisconnect(String address) async =>
      calls.add('btDisconnect:$address');

  @override
  Future<void> btForget(String address) async => calls.add('btForget:$address');

  @override
  Future<void> btSetEnabled(bool on) async => calls.add('btEnabled:$on');
}

class _FakeStatus implements SystemStatus {
  _FakeStatus(this._bt);

  final BluetoothState? _bt;

  @override
  bool get statsAvailable => false;

  @override
  bool get bluetoothAvailable => _bt != null;

  @override
  SysStats? stats() => null;

  @override
  BluetoothState? bluetooth() => _bt;
}

const _btOn = BluetoothState(
  present: true,
  powered: true,
  discoverable: false,
  pairable: false,
  devicesConnected: 1,
  adapterName: 'hci0',
);

/// WiFi 场景：已连接且保存的 BetaStudio2、未保存的开放网络 Guest、无信号隐藏 AP。
_FakeNet _wifiNet() => _FakeNet(
  wifi: const WifiState(
    present: true,
    enabled: true,
    connected: true,
    signal: 82,
    ssid: 'BetaStudio2',
    ip: '192.168.50.5',
    security: WifiSecurity.psk,
  ),
  networks: const [
    WifiNetwork(
      ssid: 'BetaStudio2',
      signal: 82,
      security: WifiSecurity.psk,
      connected: true,
      saved: true,
    ),
    WifiNetwork(ssid: 'Guest', signal: 40, security: WifiSecurity.open),
    WifiNetwork(ssid: 'Ghost', signal: 0, security: WifiSecurity.psk),
  ],
  devices: const [],
);

/// 未保存的加密网络：连接前必须先输入密码。
_FakeNet _pskNet() => _FakeNet(
  wifi: const WifiState(present: true, enabled: true),
  networks: const [
    WifiNetwork(ssid: 'Office', signal: 60, security: WifiSecurity.psk),
  ],
  devices: const [],
);

/// 蓝牙场景：已连接+已配对的耳机、无名且未配对的内部对象；WiFi 侧无任何条目，
/// 这样「断开 / 忘记」在整页里唯一。
_FakeNet _btNet() => _FakeNet(
  wifi: const WifiState(present: true, enabled: true),
  networks: const [],
  devices: const [
    BtDevice(
      address: 'AA:BB:CC:DD:EE:01',
      name: 'Archoera Buds',
      paired: true,
      connected: true,
    ),
    BtDevice(address: 'AA:BB:CC:DD:EE:02'),
  ],
);

Widget _host(_FakeNet net, {BluetoothState? bt = _btOn}) => ProviderScope(
  overrides: [
    netServiceProvider.overrideWithValue(net),
    systemStatusProvider.overrideWithValue(_FakeStatus(bt)),
  ],
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: const Scaffold(body: SingleChildScrollView(child: NetworkSection())),
  ),
);

void main() {
  testWidgets('WiFi：状态行显示 SSID 与 IP，可用网络列出、隐藏项默认收起', (tester) async {
    final net = _wifiNet();
    await tester.pumpWidget(_host(net));
    await tester.pumpAndSettle();

    final toggle = find.text('显示不可用的设备');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();

    // 连接状态行包含 SSID 与 IPv4 地址（IP 不再为空）。
    expect(find.textContaining('BetaStudio2'), findsWidgets);
    expect(find.textContaining('192.168.50.5'), findsOneWidget);

    // 可用网络列出；无信号的隐藏 AP 默认不出现。
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('Ghost'), findsNothing);
    expect(toggle, findsOneWidget);

    // 展开后出现。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Ghost'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WiFi：连接开放网络直接下发，忘记已保存网络', (tester) async {
    final net = _wifiNet();
    await tester.pumpWidget(_host(net, bt: null));
    await tester.pumpAndSettle();

    // 未保存的开放网络「Guest」→ 直接连接（无需密码）。
    final connect = find.text('连接');
    await tester.ensureVisible(connect);
    await tester.pumpAndSettle();
    await tester.tap(connect);
    await tester.pumpAndSettle();
    expect(net.calls, contains('wifiConnect:Guest:'));

    // 「忘记」已保存网络。
    final forget = find.text('忘记');
    await tester.ensureVisible(forget);
    await tester.pumpAndSettle();
    await tester.tap(forget);
    await tester.pumpAndSettle();
    expect(net.calls, contains('wifiForget:BetaStudio2'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('WiFi：未保存的加密网络先弹密码框，密码随连接一并下发', (tester) async {
    final net = _pskNet();
    await tester.pumpWidget(_host(net, bt: null));
    await tester.pumpAndSettle();

    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();

    // 弹出密码输入框。
    expect(find.text('WiFi 密码'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(net.calls, contains('wifiConnect:Office:hunter2'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('蓝牙：断开 / 忘记按设备下发，无名设备默认收起', (tester) async {
    final net = _btNet();
    await tester.pumpWidget(_host(net));
    await tester.pumpAndSettle();

    // 已连接设备 → 断开；已配对 → 忘记。
    final disconnect = find.text('断开');
    await tester.ensureVisible(disconnect);
    await tester.pumpAndSettle();
    await tester.tap(disconnect);
    await tester.pumpAndSettle();
    expect(net.calls, contains('btDisconnect:AA:BB:CC:DD:EE:01'));

    final forget = find.text('忘记');
    await tester.ensureVisible(forget);
    await tester.pumpAndSettle();
    await tester.tap(forget);
    await tester.pumpAndSettle();
    expect(net.calls, contains('btForget:AA:BB:CC:DD:EE:01'));

    // 无名且未配对的设备默认收起。
    expect(find.text('AA:BB:CC:DD:EE:02'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类可见性：仅在有无线/蓝牙适配器时出现', (tester) async {
    expect(SettingsCategory.network.visible(false, netAvailable: false), false);
    expect(SettingsCategory.network.visible(false, netAvailable: true), true);
  });
}

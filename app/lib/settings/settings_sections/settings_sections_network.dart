// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 网络与蓝牙 ────────────────────────────────────────────────────────

/// 网络设置：WiFi 开关 / 扫描 / 连接（含密码）/ 断开 / 忘记，蓝牙开关 / 扫描 /
/// 配对 / 连接 / 断开 / 忘记。
///
/// 数据来源：WiFi 与蓝牙**控制**都走 [NetService]（原生 `apl_wifi_*` /
/// `apl_bt_*`，NetworkManager / BlueZ 经 D-Bus，全程无子进程）；蓝牙**适配器**
/// 状态走 [SystemStatus.bluetooth]（`apl_bt_state`）。
///
/// 「不可用设备默认隐藏 + 可展开」：当前用不上的条目（无信号的隐藏 AP、既未配对
/// 也未连接的无名蓝牙对象）以及**缺失的适配器**统一收在底部「显示不可用的设备」
/// 展开区里，默认不打扰正常使用。
class NetworkSection extends ConsumerStatefulWidget {
  const NetworkSection({super.key});

  @override
  ConsumerState<NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends ConsumerState<NetworkSection> {
  WifiState _wifi = const WifiState();
  List<WifiNetwork> _networks = const <WifiNetwork>[];
  BluetoothState? _bt;
  List<BtDevice> _devices = const <BtDevice>[];

  bool _wifiBusy = false;
  bool _btBusy = false;
  bool _btScanning = false;
  bool _showUnavailable = false;

  NetService get _net => ref.read(netServiceProvider);
  SystemStatus get _status => ref.read(systemStatusProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_refreshWifi());
    unawaited(_refreshBt());
    // 配对提示（需要配对码/PIN 的设备由 BlueZ agent 回调上来）：弹窗确认或输入，
    // 再用 btPairReply 回答。没有这段的话，需要配对码的设备必然配对失败。
    _promptSub = _net.btPairPrompts.listen(
      (p) => unawaited(_handlePairPrompt(p)),
    );
    _resultSub = _net.btPairResults.listen((r) {
      if (!r.ok && mounted) {
        toast(context.l10n.netFailedPair, type: ToastType.error);
      }
      unawaited(_refreshBt());
    });
  }

  @override
  void dispose() {
    _promptSub?.cancel();
    _resultSub?.cancel();
    super.dispose();
  }

  StreamSubscription<BtPairPrompt>? _promptSub;
  StreamSubscription<BtPairResult>? _resultSub;

  /// 处理一次配对提示。
  Future<void> _handlePairPrompt(BtPairPrompt prompt) async {
    if (!mounted) return;
    final l10n = context.l10n;
    final code = prompt.text.isNotEmpty ? prompt.text : '${prompt.passkey}';
    switch (prompt.kind) {
      case BtPairPromptKind.enterPin:
      case BtPairPromptKind.enterPasskey:
        final entered = await SettingPromptDialog.show(
          context,
          title: l10n.netBtPairTitle,
          description: l10n.netBtPairEnterHint,
          keyboardType: TextInputType.number,
        );
        _net.btPairReply(entered != null && entered.isNotEmpty, entered);
      case BtPairPromptKind.display:
        await SDialog.show<void>(
          context,
          title: l10n.netBtPairTitle,
          child: Text(
            '${l10n.netBtPairShowHint}\n\n$code',
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                _net.btPairReply(true, null);
                Navigator.pop(context);
              },
              child: Text(l10n.commonConfirm),
            ),
          ],
        );
      case BtPairPromptKind.confirm:
      case BtPairPromptKind.authorize:
      case BtPairPromptKind.unknown:
        final body = prompt.kind == BtPairPromptKind.confirm
            ? '${l10n.netBtPairConfirmHint}\n\n$code'
            : l10n.netBtPairAuthorizeHint;
        final ok = await SDialog.show<bool>(
          context,
          title: l10n.netBtPairTitle,
          child: Text(body, style: const TextStyle(fontSize: 13, height: 1.6)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.commonConfirm),
            ),
          ],
        );
        _net.btPairReply(ok == true, null);
    }
  }

  Future<void> _refreshWifi() async {
    if (!mounted) return;
    setState(() => _wifiBusy = true);
    final wifi = await _net.wifiState();
    List<WifiNetwork> networks = const <WifiNetwork>[];
    if (wifi.enabled) {
      networks = await _net.wifiScan();
    }
    if (!mounted) return;
    setState(() {
      _wifi = wifi;
      _networks = networks;
      _wifiBusy = false;
    });
  }

  Future<void> _refreshBt() async {
    if (!mounted) return;
    setState(() => _btBusy = true);
    final bt = _status.bluetooth();
    List<BtDevice> devices = const <BtDevice>[];
    if (bt != null && bt.powered) {
      devices = await _net.btDevices();
    }
    if (!mounted) return;
    setState(() {
      _bt = bt;
      _devices = devices;
      _btBusy = false;
    });
  }

  /// 连接：需要密码且未保存过时弹输入框。
  Future<void> _connectWifi(WifiNetwork network) async {
    final l10n = context.l10n;
    String? password;
    if (network.security.needsPassword && !network.saved) {
      password = await _askPassword(network.ssid);
      if (password == null) return;
    }
    final ok = await _net.wifiConnect(network.ssid, password: password);
    if (!ok) toast(l10n.netFailedConnect, type: ToastType.error);
    await _refreshWifi();
  }

  Future<String?> _askPassword(String ssid) async {
    final value = await SettingPromptDialog.show(
      context,
      title: context.l10n.netWifiPasswordTitle,
      description: ssid,
      hint: context.l10n.netWifiPasswordHint,
      obscure: true,
    );
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// WiFi 安全类型文案。
  String _securityLabel(WifiSecurity security) => switch (security) {
    WifiSecurity.open => context.l10n.netSecOpen,
    WifiSecurity.wep => context.l10n.netSecWep,
    WifiSecurity.psk => context.l10n.netSecPsk,
    WifiSecurity.enterprise => context.l10n.netSecEnterprise,
    WifiSecurity.unknown => context.l10n.netSecUnknown,
  };

  /// 当前「用得上」的 AP：在范围内的、已连接或已保存的。
  bool _usableNetwork(WifiNetwork n) => n.connected || n.saved || n.signal > 0;

  /// 当前「用得上」的蓝牙设备：有名字、或已配对/已连接。
  bool _usableDevice(BtDevice d) =>
      d.connected || d.paired || d.name.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bt = _bt;
    final hasWifi = _wifi.present;
    final hasBt = bt?.present ?? false;

    final sections = <Widget>[];
    void add(Widget section) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 18));
      sections.add(section);
    }

    if (hasWifi) add(_wifiSection(l10n));
    if (hasBt) add(_btSection(l10n, bt!));

    // 缺失的适配器 + 列表中隐藏的条目统一收进展开区。
    final hidden = <Widget>[
      if (!hasWifi)
        SettingTile(
          icon: EtaIcons.wifi,
          title: l10n.netWifiTitle,
          subtitle: l10n.netUnavailable,
          enabled: false,
          trailing: const SizedBox.shrink(),
        ),
      if (!hasBt)
        SettingTile(
          icon: EtaIcons.bluetooth,
          title: l10n.netBtTitle,
          subtitle: l10n.netUnavailable,
          enabled: false,
          trailing: const SizedBox.shrink(),
        ),
      for (final n in _networks.where((n) => !_usableNetwork(n)))
        _wifiTile(l10n, n),
      for (final d in _devices.where((d) => !_usableDevice(d)))
        _btTile(l10n, d),
    ];

    if (hidden.isNotEmpty) {
      add(
        SettingSection(
          title: l10n.settingsCatNetwork,
          children: [
            InkWell(
              onTap: () => setState(() => _showUnavailable = !_showUnavailable),
              child: SettingTile(
                icon: EtaIcons.unlinkOutline,
                title: _showUnavailable
                    ? l10n.netHideUnavailable
                    : l10n.netShowUnavailable,
                subtitle: '${hidden.length}',
                trailing: Icon(
                  _showUnavailable ? EtaIcons.downSmall : EtaIcons.arrowRight,
                  size: 18,
                ),
              ),
            ),
            if (_showUnavailable) ...hidden,
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }

  Widget _wifiSection(AppLocalizations l10n) {
    final visible = _networks.where(_usableNetwork).toList();
    final ip = _wifi.ip.isEmpty ? '' : ' (${_wifi.ip})';
    final signal = _wifi.signal >= 0 ? ' · ${_wifi.signal}%' : '';
    final connectedLabel = _wifi.connected
        ? '${l10n.netWifiConnected} · ${_wifi.ssid}$ip$signal'
        : l10n.netWifiNotConnected;

    return SettingSection(
      title: l10n.netWifiTitle,
      children: [
        SettingSwitchTile(
          icon: EtaIcons.wifi,
          title: l10n.netWifiTitle,
          subtitle: _wifi.enabled ? connectedLabel : l10n.netWifiDisabled,
          value: _wifi.enabled,
          onChanged: (v) async {
            await _net.wifiSetEnabled(v);
            await _refreshWifi();
          },
        ),
        if (_wifi.enabled) ...[
          SettingTile(
            icon: EtaIcons.search3Outline,
            title: l10n.netWifiAvailable,
            subtitle: _wifiBusy ? l10n.netWifiScanning : '${visible.length}',
            trailing: IconButton(
              icon: const Icon(EtaIcons.refresh, size: 18),
              tooltip: l10n.commonRefresh,
              onPressed: _wifiBusy ? null : () => _refreshWifi(),
            ),
          ),
          for (final network in visible) _wifiTile(l10n, network),
          if (visible.isEmpty && !_wifiBusy)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: SettingNote(text: l10n.netWifiEmpty),
            ),
        ],
      ],
    );
  }

  Widget _wifiTile(AppLocalizations l10n, WifiNetwork network) {
    final trailing = <Widget>[
      if (network.connected || network.saved)
        TextButton(
          onPressed: () async {
            await _net.wifiDisconnect();
            await _refreshWifi();
          },
          child: Text(l10n.netWifiDisconnect),
        )
      else
        TextButton(
          onPressed: () => _connectWifi(network),
          child: Text(l10n.netWifiConnect),
        ),
      if (network.saved)
        TextButton(
          onPressed: () async {
            await _net.wifiForget(network.ssid);
            await _refreshWifi();
          },
          child: Text(l10n.netWifiForget),
        ),
    ];

    // connected 兜底：桥接按 ActiveAccessPoint 的 SSID 判定；若该 AP 未出现在本次
    // 扫描结果里（缓存/时机差异），至少与当前连接同名的那条也标成已连接。
    final isConnected =
        network.connected || (_wifi.connected && network.ssid == _wifi.ssid);
    final subtitle = <String>[
      if (network.frequencyMhz > 0)
        network.is5Ghz ? l10n.netWifiBand5 : l10n.netWifiBand24,
      if (network.signal > 0) '${network.signal}%',
      _securityLabel(network.security),
      if (isConnected) l10n.netWifiConnected,
      if (network.saved) l10n.netWifiSaved,
    ].join(' · ');

    return SettingTile(
      icon: network.security == WifiSecurity.open
          ? EtaIcons.unlockOutline
          : EtaIcons.lockOutline,
      title: network.ssid.isEmpty ? l10n.systemDisplayUnknown : network.ssid,
      subtitle: subtitle,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: trailing),
    );
  }

  Widget _btSection(AppLocalizations l10n, BluetoothState bt) {
    final visible = _devices.where(_usableDevice).toList();
    final subtitle = _btScanning
        ? l10n.netBtScanning
        : _btBusy
        ? l10n.netBtScanning
        : '${l10n.netBtConnected}: ${bt.devicesConnected} · ${visible.length}';

    return SettingSection(
      title: l10n.netBtTitle,
      children: [
        SettingSwitchTile(
          icon: EtaIcons.bluetooth,
          title: l10n.netBtTitle,
          subtitle: bt.adapterName ?? l10n.netWifiEnabled,
          value: bt.powered,
          onChanged: (v) async {
            await _net.btSetEnabled(v);
            await _refreshBt();
          },
        ),
        if (bt.powered) ...[
          SettingTile(
            icon: EtaIcons.bluetooth,
            title: l10n.netBtDevices,
            subtitle: subtitle,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () async {
                    if (_btScanning) {
                      await _net.btScanStop();
                      setState(() => _btScanning = false);
                    } else {
                      setState(() => _btScanning = true);
                      await _net.btScanStart();
                    }
                    await _refreshBt();
                  },
                  child: Text(
                    _btScanning ? l10n.netBtScanStop : l10n.netBtScanStart,
                  ),
                ),
                IconButton(
                  icon: const Icon(EtaIcons.refresh, size: 18),
                  tooltip: l10n.commonRefresh,
                  onPressed: _btBusy ? null : () => _refreshBt(),
                ),
              ],
            ),
          ),
          for (final device in visible) _btTile(l10n, device),
          if (visible.isEmpty && !_btBusy)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: SettingNote(text: l10n.netBtEmpty),
            ),
        ],
      ],
    );
  }

  Widget _btTile(AppLocalizations l10n, BtDevice device) {
    final trailing = <Widget>[];
    if (device.connected) {
      trailing.add(
        TextButton(
          onPressed: () async {
            await _net.btDisconnect(device.address);
            await _refreshBt();
          },
          child: Text(l10n.netBtDisconnect),
        ),
      );
    } else if (device.paired) {
      trailing.add(
        TextButton(
          onPressed: () async {
            await _net.btConnect(device.address);
            await _refreshBt();
          },
          child: Text(l10n.netBtConnect),
        ),
      );
    } else {
      trailing.add(
        TextButton(
          onPressed: () {
            // 异步配对：立即返回，提示/结果走事件流（可处理需要配对码的设备）。
            final rc = _net.btPairStart(device.address);
            if (rc < 0) {
              toast(l10n.netFailedPair, type: ToastType.error);
            }
          },
          child: Text(l10n.netBtPair),
        ),
      );
    }
    if (device.paired) {
      trailing.add(
        TextButton(
          onPressed: () async {
            await _net.btForget(device.address);
            await _refreshBt();
          },
          child: Text(l10n.netBtForget),
        ),
      );
    }

    final subtitle = <String>[
      device.address,
      if (device.paired) l10n.netBtPaired,
      if (device.connected) l10n.netBtConnected,
      if (device.rssi != 0) '${device.rssi} dBm',
    ].join(' · ');

    return SettingTile(
      icon: EtaIcons.bluetooth,
      title: device.displayName,
      subtitle: subtitle,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: trailing),
    );
  }
}

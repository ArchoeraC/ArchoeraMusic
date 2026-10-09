// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── MCP 接入（本地控制服务）──────────────────────────────────────────────

/// 能力组 → 图标 / 标题 / 说明。
IconData _mcpCapabilityIcon(McpCapability capability) => switch (capability) {
  McpCapability.read => EtaIcons.informationOutline,
  McpCapability.playback => EtaIcons.playCircleOutline,
  McpCapability.queue => EtaIcons.listCheck2,
  McpCapability.search => EtaIcons.search3Outline,
  McpCapability.library => EtaIcons.folderOutline,
  McpCapability.preferences => EtaIcons.toolOutline,
  McpCapability.appearance => EtaIcons.paletteOutline,
  McpCapability.collection => EtaIcons.heartbeatOutline,
  McpCapability.history => EtaIcons.history,
  McpCapability.lyrics => EtaIcons.fileMusicOutline,
  McpCapability.download => EtaIcons.downloadOutline,
};

String _mcpCapabilityTitle(AppLocalizations l10n, McpCapability capability) =>
    switch (capability) {
      McpCapability.read => l10n.settingsMcpCapRead,
      McpCapability.playback => l10n.settingsMcpCapPlayback,
      McpCapability.queue => l10n.settingsMcpCapQueue,
      McpCapability.search => l10n.settingsMcpCapSearch,
      McpCapability.library => l10n.settingsMcpCapLibrary,
      McpCapability.preferences => l10n.settingsMcpCapPreferences,
      McpCapability.appearance => l10n.settingsMcpCapAppearance,
      McpCapability.collection => l10n.settingsMcpCapCollection,
      McpCapability.history => l10n.settingsMcpCapHistory,
      McpCapability.lyrics => l10n.settingsMcpCapLyrics,
      McpCapability.download => l10n.settingsMcpCapDownload,
    };

String _mcpCapabilityDesc(AppLocalizations l10n, McpCapability capability) =>
    switch (capability) {
      McpCapability.read => l10n.settingsMcpCapReadDesc,
      McpCapability.playback => l10n.settingsMcpCapPlaybackDesc,
      McpCapability.queue => l10n.settingsMcpCapQueueDesc,
      McpCapability.search => l10n.settingsMcpCapSearchDesc,
      McpCapability.library => l10n.settingsMcpCapLibraryDesc,
      McpCapability.preferences => l10n.settingsMcpCapPreferencesDesc,
      McpCapability.appearance => l10n.settingsMcpCapAppearanceDesc,
      McpCapability.collection => l10n.settingsMcpCapCollectionDesc,
      McpCapability.history => l10n.settingsMcpCapHistoryDesc,
      McpCapability.lyrics => l10n.settingsMcpCapLyricsDesc,
      McpCapability.download => l10n.settingsMcpCapDownloadDesc,
    };

/// 本机局域网 IPv4（排除回环）；无可用网卡返回 null。
Future<String?> _localLanIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.address.isNotEmpty) return addr.address;
      }
    }
  } catch (_) {
    // 读取失败静默（显示占位）。
  }
  return null;
}

/// MCP 接入分类：总开关 / 端口 / 密钥 / 能力组 / 端点状态。
///
/// 服务默认关闭；开启后仅监听本机回环地址，密钥为 128-bit 十六进制。
class McpSection extends ConsumerStatefulWidget {
  const McpSection({super.key});

  @override
  ConsumerState<McpSection> createState() => _McpSectionState();
}

class _McpSectionState extends ConsumerState<McpSection> {
  late final TextEditingController _portCtrl;
  late final FocusNode _portFocus;

  /// 局域网 IPv4 解析缓存（设置页驻留期间只解析一次）。
  Future<String?>? _lanIpFuture;

  @override
  void initState() {
    super.initState();
    _portCtrl = TextEditingController(
      text: '${ref.read(appPrefsProvider).mcpPort}',
    );
    _portFocus = FocusNode()..addListener(_onPortFocus);
  }

  @override
  void dispose() {
    _portFocus
      ..removeListener(_onPortFocus)
      ..dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  void _onPortFocus() {
    if (!_portFocus.hasFocus) _commitPort();
  }

  /// 端口落盘：非法回退当前值，越界收敛到 1024~65535。
  void _commitPort() {
    final notifier = ref.read(appPrefsProvider.notifier);
    final parsed = int.tryParse(_portCtrl.text.trim());
    if (parsed == null) {
      _portCtrl.text = '${ref.read(appPrefsProvider).mcpPort}';
      return;
    }
    final clamped = clampMcpPort(parsed);
    notifier.setMcpPort(clamped);
    if (clamped != parsed) _portCtrl.text = '$clamped';
  }

  void _copyKey() {
    final key = ref.read(appPrefsProvider).mcpAccessKey;
    if (key.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: key)));
    toast(context.l10n.settingsMcpKeyCopied, type: ToastType.success);
  }

  void _regenerateKey() {
    ref.read(appPrefsProvider.notifier).setMcpAccessKey(generateMcpAccessKey());
    toast(context.l10n.settingsMcpKeyRegenerated, type: ToastType.info);
  }

  /// 命令行示例（用当前可执行文件名，便于直接复制到终端）。
  String _shellExample() {
    final exe = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
    return '$exe archoerashell --help';
  }

  void _copyShellExample() {
    unawaited(Clipboard.setData(ClipboardData(text: _shellExample())));
    toast(context.l10n.settingsMcpShellCopied, type: ToastType.success);
  }

  /// 切换局域网访问：开启前弹安全确认（默认关，需用户显式确认）。
  Future<void> _toggleLan(bool value) async {
    final l10n = context.l10n;
    final notifier = ref.read(appPrefsProvider.notifier);
    if (!value) {
      notifier.setMcpAllowLan(false);
      return;
    }
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsMcpAllowLanWarningTitle,
      description: l10n.settingsMcpAllowLanWarningBody,
      width: 440,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsMcpAllowLanWarningAgree,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok == true) notifier.setMcpAllowLan(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    final service = ref.watch(mcpServiceProvider);
    final enabled = prefs.mcpEnabled;
    final key = prefs.mcpAccessKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsMcpTitle,
          note: l10n.settingsMcpNote,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.chipOutline,
              title: l10n.settingsMcpEnable,
              subtitle: enabled
                  ? l10n.settingsMcpEnableOn
                  : l10n.settingsMcpEnableOff,
              value: enabled,
              onChanged: (v) => notifier.setMcpEnabled(v),
            ),
            SettingTile(
              icon: EtaIcons.serverOutline,
              title: l10n.settingsMcpPort,
              subtitle: l10n.settingsMcpPortDesc,
              enabled: enabled,
              trailing: SizedBox(
                width: 104,
                child: TextField(
                  controller: _portCtrl,
                  focusNode: _portFocus,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '1024-65535',
                  ),
                  onSubmitted: (_) => _commitPort(),
                ),
              ),
            ),
            SettingTile(
              icon: EtaIcons.keyOutline,
              title: l10n.settingsMcpKey,
              subtitle: key.isEmpty ? '—' : key,
              enabled: enabled,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SButton(
                    label: l10n.settingsMcpKeyCopy,
                    variant: SButtonVariant.secondary,
                    onPressed: enabled && key.isNotEmpty ? _copyKey : null,
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: l10n.settingsMcpKeyRegenerate,
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    onPressed: enabled ? _regenerateKey : null,
                    icon: const Icon(EtaIcons.refreshOutline),
                  ),
                ],
              ),
            ),
            SettingSwitchTile(
              icon: EtaIcons.lockOutline,
              title: l10n.settingsMcpAllowKeyless,
              subtitle: l10n.settingsMcpAllowKeylessDesc,
              value: prefs.mcpAllowKeyless,
              enabled: enabled,
              onChanged: (v) => notifier.setMcpAllowKeyless(v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.serverOutline,
              title: l10n.settingsMcpAllowLan,
              subtitle: l10n.settingsMcpAllowLanDesc,
              value: prefs.mcpAllowLan,
              enabled: enabled,
              onChanged: _toggleLan,
            ),
            SettingSwitchTile(
              icon: EtaIcons.monitorOutline,
              title: l10n.settingsMcpShell,
              subtitle: l10n.settingsMcpShellDesc,
              value: prefs.mcpShellEnabled,
              onChanged: (v) => notifier.setMcpShellEnabled(v),
            ),
            SettingTile(
              icon: EtaIcons.pluginOutline,
              title: l10n.settingsMcpShellUsage,
              subtitle: _shellExample(),
              enabled: prefs.mcpShellEnabled,
              trailing: SButton(
                label: l10n.settingsMcpShellCopy,
                variant: SButtonVariant.secondary,
                onPressed: prefs.mcpShellEnabled ? _copyShellExample : null,
              ),
            ),
          ],
        ),
        if (enabled && prefs.mcpAllowLan) ...[
          const SizedBox(height: 8),
          SettingNote(text: l10n.settingsMcpAllowLanWarning),
        ],
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsMcpCapsTitle,
          note: l10n.settingsMcpCapsNote,
          children: [
            for (final capability in McpCapability.values)
              // 下载能力组需「开发者模式 + 下载模块」开启（与 GUI 入口同门槛，
              // 见 mcpConfigOf）；未开启时整行隐藏，避免开关看似有效实则被丢弃。
              if (capability != McpCapability.download ||
                  prefs.downloadModuleEnabled)
                SettingSwitchTile(
                  icon: _mcpCapabilityIcon(capability),
                  title: _mcpCapabilityTitle(l10n, capability),
                  subtitle: _mcpCapabilityDesc(l10n, capability),
                  value: prefs.mcpCapabilityEnabled(capability.id),
                  enabled: enabled,
                  onChanged: (v) => notifier.setMcpCapability(capability.id, v),
                ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsMcpEndpointsTitle,
          note: l10n.settingsMcpNote,
          children: [
            ListenableBuilder(
              listenable: service,
              builder: (context, _) {
                final running = service.running;
                final port = service.boundPort ?? prefs.mcpPort;
                final status = running
                    ? l10n.settingsMcpStatusRunning(port: port)
                    : (service.lastError != null
                          ? l10n.settingsMcpStatusError
                          : l10n.settingsMcpStatusStopped);
                final host = '127.0.0.1:$port';
                return Column(
                  children: [
                    SettingTile(
                      icon: running
                          ? EtaIcons.checkCircleOutline
                          : EtaIcons.closeCircleOutline,
                      title: status,
                      subtitle: l10n.settingsMcpStatusDesc,
                      trailing: SizedBox.shrink(),
                    ),
                    if (prefs.mcpAllowLan)
                      FutureBuilder<String?>(
                        future: _lanIpFuture ??= _localLanIpv4(),
                        builder: (context, snapshot) {
                          final ip = snapshot.data;
                          return SettingTile(
                            icon: EtaIcons.link,
                            title: l10n.settingsMcpLanAddress,
                            subtitle: ip == null
                                ? '0.0.0.0:$port'
                                : '$ip:$port',
                            trailing: SizedBox.shrink(),
                          );
                        },
                      ),
                    SettingTile(
                      icon: EtaIcons.link,
                      title: l10n.settingsMcpEndpointMcp,
                      subtitle: 'http://$host/mcp',
                      trailing: SizedBox.shrink(),
                    ),
                    SettingTile(
                      icon: EtaIcons.serverOutline,
                      title: l10n.settingsMcpEndpointRest,
                      subtitle: 'http://$host/api',
                      trailing: SizedBox.shrink(),
                    ),
                    SettingTile(
                      icon: EtaIcons.pluginOutline,
                      title: l10n.settingsMcpEndpointWs,
                      subtitle: 'ws://$host/ws',
                      trailing: SizedBox.shrink(),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

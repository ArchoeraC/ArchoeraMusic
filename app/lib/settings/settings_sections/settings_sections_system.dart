// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 系统（ArchoeraOS 会话控制）────────────────────────────────────────

/// 系统分类：电池 / 亮度 / 屏幕 / 电源（ArchoeraOS 会话控制面）。
///
/// 仅在 [platformCapabilitiesProvider] 报告 `osSessionAvailable` 时进入
/// 正常内容（分类导航同样以此 gate）；会话能力位图
/// [osCapabilitiesProvider] 再决定各子分区是否渲染。未运行于
/// `archoera-shell` 时显示「未运行于 ArchoeraOS」的说明行。
class SystemSection extends ConsumerStatefulWidget {
  const SystemSection({super.key});

  @override
  ConsumerState<SystemSection> createState() => _SystemSectionState();
}

class _SystemSectionState extends ConsumerState<SystemSection> {
  /// 亮度滑块本地草稿（拖动期间优先显示；松手后置 null 交回 provider）。
  double? _brightnessDraft;

  /// 系统资源 / 蓝牙：设置页可见期间轮询（2s），不可见即停。
  Timer? _statusTimer;
  SysStats? _stats;
  BluetoothState? _bt;

  @override
  void initState() {
    super.initState();
    final status = ref.read(platformCapabilitiesProvider).status;
    if (status.statsAvailable || status.bluetoothAvailable) {
      _refreshStatus();
      _statusTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _refreshStatus(),
      );
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _refreshStatus() {
    final status = ref.read(platformCapabilitiesProvider).status;
    final stats = status.statsAvailable ? status.stats() : null;
    final bt = status.bluetoothAvailable ? status.bluetooth() : null;
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _bt = bt;
    });
  }

  /// 弹出危险操作确认框；用户确认返回 true（取消/关闭返回 false）。
  Future<bool> _confirm(String action) async {
    final l10n = context.l10n;
    final confirmed = await SDialog.show<bool>(
      context,
      title: l10n.systemConfirmTitle(action),
      child: Text(
        l10n.systemConfirmBody(action),
        style: const TextStyle(fontSize: 13, height: 1.6),
      ),
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
    return confirmed ?? false;
  }

  /// 确认后执行系统请求（桥接返回码无需在 UI 处理：不可用时能力位已 gate）。
  Future<void> _invoke(String action, int Function() request) async {
    if (!await _confirm(action)) return;
    request();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!ref.watch(osSessionAvailableProvider)) {
      return SettingSection(
        title: l10n.settingsCatSystem,
        children: [
          SettingTile(
            icon: EtaIcons.powerOutline,
            title: l10n.systemUnavailableTitle,
            subtitle: l10n.systemUnavailableBody,
            trailing: const SizedBox.shrink(),
          ),
        ],
      );
    }

    final controller = ref.watch(osSessionControllerProvider);
    final osCaps = ref.watch(osCapabilitiesProvider);
    final battery = ref.watch(osBatteryProvider);
    final brightness = ref.watch(osBrightnessProvider);
    final screenOn = ref.watch(osScreenEnabledProvider);
    final session = ref.watch(osSessionStateProvider);

    final brightnessValue = _brightnessDraft ?? (brightness ?? 0).toDouble();

    final sections = <Widget>[];
    void add(Widget section) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 18));
      sections.add(section);
    }

    // 电池（仅在存在电池时显示）。
    if (battery != null && battery.present) {
      add(
        SettingSection(
          title: l10n.systemBatteryTitle,
          children: [
            SettingTile(
              icon: EtaIcons.flashOutline,
              title: l10n.systemBatteryTitle,
              subtitle:
                  '${l10n.systemBatteryPercent(battery.percent)} · '
                  '${battery.charging ? l10n.systemBatteryCharging : l10n.systemBatteryDischarging}',
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }

    // 亮度。
    if (osCaps & OsCapability.brightness != 0) {
      add(
        SettingSection(
          title: l10n.systemBrightnessTitle,
          children: [
            SettingSliderTile(
              icon: EtaIcons.brightnessOutline,
              title: l10n.systemBrightnessTitle,
              subtitle: '${brightnessValue.round()}%',
              value: brightnessValue,
              min: 0,
              max: 100,
              divisions: 100,
              onChanged: (v) => setState(() => _brightnessDraft = v),
              onChangeEnd: (v) {
                controller.setBrightness(v.round());
                setState(() => _brightnessDraft = null);
              },
            ),
          ],
        ),
      );
    }

    // 屏幕（DPMS 开关）。
    if (osCaps & OsCapability.screen != 0) {
      add(
        SettingSection(
          title: l10n.systemScreenTitle,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.monitorOutline,
              title: l10n.systemScreenTitle,
              subtitle: (screenOn ?? true)
                  ? l10n.systemScreenOn
                  : l10n.systemScreenOff,
              value: screenOn ?? true,
              onChanged: (v) => controller.setScreenEnabled(v),
            ),
          ],
        ),
      );
    }

    // 电源（关机/重启，挂起/休眠各自按能力位出现）。
    if (osCaps & OsCapability.power != 0 ||
        osCaps & OsCapability.suspend != 0) {
      final buttons = <Widget>[];
      if (osCaps & OsCapability.power != 0) {
        buttons.add(
          FilledButton.tonalIcon(
            onPressed: () =>
                _invoke(l10n.systemPowerShutdown, controller.powerOff),
            icon: const Icon(EtaIcons.powerOutline),
            label: Text(l10n.systemPowerShutdown),
          ),
        );
        buttons.add(
          FilledButton.tonalIcon(
            onPressed: () => _invoke(l10n.systemPowerReboot, controller.reboot),
            icon: const Icon(EtaIcons.refreshOutline),
            label: Text(l10n.systemPowerReboot),
          ),
        );
      }
      if (osCaps & OsCapability.suspend != 0) {
        buttons.add(
          FilledButton.tonalIcon(
            onPressed: () =>
                _invoke(l10n.systemPowerSuspend, controller.suspend),
            icon: const Icon(EtaIcons.moonOutline),
            label: Text(l10n.systemPowerSuspend),
          ),
        );
        buttons.add(
          FilledButton.tonalIcon(
            onPressed: () =>
                _invoke(l10n.systemPowerHibernate, controller.hibernate),
            icon: const Icon(EtaIcons.moonStarsOutline),
            label: Text(l10n.systemPowerHibernate),
          ),
        );
      }
      add(
        SettingSection(
          title: l10n.systemPowerTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Wrap(spacing: 10, runSpacing: 10, children: buttons),
            ),
          ],
        ),
      );
    }

    // 显示（输出分辨率 / 缩放 / 旋转；仅 udev 后端置位 output 能力）。
    final output = ref.watch(osOutputProvider);
    if (osCaps & OsCapability.output != 0) {
      final scalePercent = (output?.scaleMilli ?? 1000) ~/ 10;
      final rotation = output?.rotationDegrees ?? 0;
      final mode = (output?.width ?? 0, output?.height ?? 0);
      final modeLabel = output == null
          ? l10n.systemDisplayUnknown
          : '${output.width}×${output.height} · '
                '${(output.refreshMillihz / 1000).toStringAsFixed(1)} Hz';
      add(
        SettingSection(
          title: l10n.systemDisplayTitle,
          children: [
            SettingTile(
              icon: EtaIcons.monitorOutline,
              title: l10n.systemStatusOutput,
              subtitle: modeLabel,
              trailing: const SizedBox.shrink(),
            ),
            _SystemChoiceRow<int>(
              label: l10n.systemDisplayScale,
              options: const [100, 125, 150, 175, 200],
              selected: scalePercent,
              labelOf: (v) => '$v%',
              onSelected: (v) => controller.setOutputScale(v * 10),
            ),
            _SystemChoiceRow<(int, int)>(
              label: l10n.systemDisplayMode,
              options: const [
                (0, 0),
                (1280, 720),
                (1280, 800),
                (1920, 1080),
              ],
              selected: mode,
              labelOf: (v) =>
                  v.$1 == 0 ? l10n.systemDisplayAuto : '${v.$1}×${v.$2}',
              onSelected: (v) => controller.setOutputMode(v.$1, v.$2),
            ),
            _SystemChoiceRow<int>(
              label: l10n.systemDisplayRotation,
              options: const [0, 90, 180, 270],
              selected: rotation,
              labelOf: (v) => '$v°',
              onSelected: (v) => controller.setOutputTransform(_transformCode(v)),
            ),
          ],
        ),
      );
    }

    // 系统状态（只读汇总）。
    final statusRows = <Widget>[
      SettingTile(
        icon: EtaIcons.informationOutline,
        title: l10n.systemStatusSession,
        subtitle: switch (session) {
          OsSessionState.ready => l10n.systemStatusReady,
          OsSessionState.suspending => l10n.systemSessionSuspending,
          OsSessionState.shuttingDown => l10n.systemSessionShuttingDown,
        },
        trailing: const SizedBox.shrink(),
      ),
      if (output != null)
        SettingTile(
          icon: EtaIcons.monitorOutline,
          title: l10n.systemStatusOutput,
          subtitle:
              '${output.width}×${output.height} · '
              '${(output.refreshMillihz / 1000).toStringAsFixed(1)} Hz · '
              '${output.scale}× · ${output.rotationDegrees}°',
          trailing: const SizedBox.shrink(),
        ),
      if (brightness != null)
        SettingTile(
          icon: EtaIcons.brightnessOutline,
          title: l10n.systemBrightnessTitle,
          subtitle: '$brightness%',
          trailing: const SizedBox.shrink(),
        ),
      if (battery != null && battery.present)
        SettingTile(
          icon: EtaIcons.flashOutline,
          title: l10n.systemBatteryTitle,
          subtitle:
              '${l10n.systemBatteryPercent(battery.percent)} · '
              '${battery.charging ? l10n.systemBatteryCharging : l10n.systemBatteryDischarging}',
          trailing: const SizedBox.shrink(),
        ),
      if (screenOn != null)
        SettingTile(
          icon: EtaIcons.monitorOutline,
          title: l10n.systemScreenTitle,
          subtitle: screenOn ? l10n.systemScreenOn : l10n.systemScreenOff,
          trailing: const SizedBox.shrink(),
        ),
    ];
    add(SettingSection(title: l10n.systemStatusTitle, children: statusRows));

    // 系统资源（2s 轮询快照）。
    final stats = _stats;
    if (stats != null) {
      add(
        SettingSection(
          title: l10n.systemResourcesTitle,
          children: [
            SettingTile(
              icon: EtaIcons.chipOutline,
              title: l10n.systemResCpu,
              subtitle: stats.cpuPercent < 0
                  ? '${stats.cpuCount} × CPU'
                  : '${stats.cpuPercent}% · ${stats.cpuCount} × CPU',
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.memoryStickOutline,
              title: l10n.systemResMemory,
              subtitle:
                  '${_formatKb(stats.memUsedKb)} / ${_formatKb(stats.memTotalKb)}'
                  ' (${stats.memPercent}%)',
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.storageOutline,
              title: l10n.systemResDisk,
              subtitle:
                  '${_formatKb(stats.diskUsedKb)} / ${_formatKb(stats.diskTotalKb)}'
                  ' (${stats.diskPercent}%)',
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: EtaIcons.serverOutline,
              title: l10n.systemResUptime,
              subtitle: stats.uptimeLabel,
              trailing: const SizedBox.shrink(),
            ),
            if (stats.tempCelsius != null)
              SettingTile(
                icon: EtaIcons.fireOutline,
                title: l10n.systemResTemp,
                subtitle: '${stats.tempCelsius!.toStringAsFixed(1)} °C',
                trailing: const SizedBox.shrink(),
              ),
          ],
        ),
      );
    }

    // 蓝牙（只读状态；无 BlueZ/无适配器时给出说明）。
    if (ref.watch(platformCapabilitiesProvider).bluetoothAvailable) {
      final bt = _bt;
      add(
        SettingSection(
          title: l10n.systemBluetoothTitle,
          children: [
            SettingTile(
              icon: EtaIcons.bluetooth,
              title: bt?.adapterName ?? l10n.systemBluetoothTitle,
              subtitle: bt == null
                  ? l10n.systemBtUnavailable
                  : (!bt.present
                        ? l10n.systemBtAbsent
                        : (bt.powered ? l10n.systemBtPowered : l10n.systemBtOff)),
              trailing: const SizedBox.shrink(),
            ),
            if (bt != null && bt.present)
              SettingTile(
                icon: EtaIcons.deviceOutline,
                title: l10n.systemBtDevices,
                subtitle: '${bt.devicesConnected}',
                trailing: const SizedBox.shrink(),
              ),
          ],
        ),
      );
    }

    // 会话态提示（挂起/关机前）。
    if (session != OsSessionState.ready) {
      add(
        SettingNote(
          text: session == OsSessionState.suspending
              ? l10n.systemSessionSuspending
              : l10n.systemSessionShuttingDown,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }
}

/// 旋转角度 → 协议输出变换码（仅正向旋转；镜像变换暂无 UI 入口）。
int _transformCode(int degrees) => switch (degrees) {
  90 => 1,
  180 => 2,
  270 => 3,
  _ => 0,
};

/// 一行「标签 + 选项胶囊」（用于显示设置的缩放/分辨率/旋转）。
class _SystemChoiceRow<T> extends StatelessWidget {
  const _SystemChoiceRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String label;
  final List<T> options;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text(labelOf(option)),
                  selected: option == selected,
                  onSelected: (_) => onSelected(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// KiB → 人类可读（GiB / MiB）。
String _formatKb(int kb) {
  if (kb >= 1024 * 1024) return '${(kb / (1024 * 1024)).toStringAsFixed(1)} GiB';
  if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(0)} MiB';
  return '$kb KiB';
}

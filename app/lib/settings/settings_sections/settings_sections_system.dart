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

    // 显示（per-output 分辨率 / 缩放 / 旋转；仅 udev 后端置位 output 能力）。
    if (osCaps & OsCapability.output != 0) {
      add(const DisplaySettingsSection());
    }

    // 只读的系统状态 / 资源集中在「系统监视器」弹窗中。
    add(
      SettingSection(
        title: l10n.systemStatusTitle,
        children: [
          InkWell(
            onTap: () => showSystemMonitorDialog(context),
            child: SettingTile(
              icon: EtaIcons.monitorOutline,
              title: l10n.systemMonitorTitle,
              subtitle: l10n.systemMonitorHint,
              trailing: const Icon(EtaIcons.arrowRight, size: 18),
            ),
          ),
        ],
      ),
    );

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

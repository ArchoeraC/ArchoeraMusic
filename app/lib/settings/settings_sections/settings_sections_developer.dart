// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 开发者 ────────────────────────────────────────────────────────────

/// 开发者分类：开发者模式开关 + 隐藏的下载接口说明。
///
/// 仅在开发者模式开启后可从设置导航进入（关闭后本分类一并隐藏，由
/// [onDeveloperDisabled] 通知主弹窗退回「关于」分类）。
class DeveloperSection extends ConsumerStatefulWidget {
  const DeveloperSection({super.key, this.onDeveloperDisabled});

  /// 关闭开发者模式时回调（主弹窗借此把分类切回「关于」）。
  final VoidCallback? onDeveloperDisabled;

  @override
  ConsumerState<DeveloperSection> createState() => _DeveloperSectionState();
}

class _DeveloperSectionState extends ConsumerState<DeveloperSection> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final devMode = ref.watch(appPrefsProvider).developerMode;
    final devFps = ref.watch(appPrefsProvider).devFpsMonitor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsDeveloperTitle,
          children: [
            SettingTile(
              icon: Icons.engineering_outlined,
              title: l10n.settingsDeveloperMode,
              subtitle: devMode
                  ? l10n.settingsDeveloperModeOn
                  : l10n.settingsDeveloperModeOff,
              trailing: Switch(
                value: devMode,
                onChanged: (v) {
                  ref.read(appPrefsProvider.notifier).setDeveloperMode(v);
                  toast(
                    v
                        ? l10n.settingsDeveloperEnabled
                        : l10n.settingsDeveloperDisabled,
                    type: v ? ToastType.success : ToastType.info,
                  );
                  if (!v) widget.onDeveloperDisabled?.call();
                },
              ),
            ),
            // 开发者组件独立开关（默认全关；关闭开发者模式时一并复位，
            // 见 AppPrefsNotifier.setDeveloperMode 的全量关闭原则）
            SettingTile(
              icon: Icons.monitor_heart_outlined,
              title: l10n.settingsDevFpsMonitor,
              subtitle: l10n.settingsDevFpsMonitorDesc,
              trailing: Switch(
                value: devFps,
                onChanged: (v) =>
                    ref.read(appPrefsProvider.notifier).setDevFpsMonitor(v),
              ),
            ),
            SettingTile(
              icon: Icons.download_outlined,
              title: l10n.settingsDeveloperDownloadModule,
              subtitle: l10n.settingsDeveloperDownloadModuleDesc,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    );
  }
}

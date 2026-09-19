// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 开发者 ────────────────────────────────────────────────────────────

/// 下载模块风险提示色（黄色标注：与普通设置项区分，提示风险）。
const _downloadWarningColor = Color(0xFFFFB300);

/// 开发者分类：开发者模式开关 + FPS 监控 + 下载模块独立开关。
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
  /// 切换「下载模块」：开启前弹风险确认（黄色标注，明确告知风险）。
  Future<void> _toggleDownloadModule(bool value) async {
    final l10n = context.l10n;
    final notifier = ref.read(appPrefsProvider.notifier);
    if (!value) {
      notifier.setDevDownloadModule(false);
      toast(l10n.settingsDevDownloadModuleOff, type: ToastType.info);
      return;
    }
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsDevDownloadWarningTitle,
      description: l10n.settingsDevDownloadWarningBody,
      width: 440,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsDevDownloadWarningAgree,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok == true) {
      notifier.setDevDownloadModule(true);
      if (mounted) {
        toast(l10n.settingsDevDownloadModuleOn, type: ToastType.warning);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final devMode = ref.watch(appPrefsProvider).developerMode;
    final devFps = ref.watch(appPrefsProvider).devFpsMonitor;
    final downloadModule = ref.watch(appPrefsProvider).devDownloadModule;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsDeveloperTitle,
          note: l10n.settingsDeveloperNote,
          children: [
            SettingTile(
              icon: EtaIcons.toolOutline,
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
              icon: EtaIcons.heartbeatOutline,
              title: l10n.settingsDevFpsMonitor,
              subtitle: l10n.settingsDevFpsMonitorDesc,
              trailing: Switch(
                value: devFps,
                onChanged: (v) =>
                    ref.read(appPrefsProvider.notifier).setDevFpsMonitor(v),
              ),
            ),
            // 下载模块：独立可开关；仅「开关按钮」黄色标注（行样式保持常规），
            // 开启前弹出风险确认。
            SettingTile(
              icon: EtaIcons.downloadOutline,
              title: l10n.settingsDeveloperDownloadModule,
              subtitle: l10n.settingsDeveloperDownloadModuleDesc,
              trailing: Switch(
                value: downloadModule,
                activeThumbColor: _downloadWarningColor,
                onChanged: devMode ? _toggleDownloadModule : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}


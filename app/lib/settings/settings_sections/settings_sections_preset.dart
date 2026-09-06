// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 预设（强迫症） ────────────────────────────────────────────────────

/// 预设分类：性能模式 / 播放过滤 / 歌词还原 / 列表标签与副标题。
class PresetSection extends ConsumerStatefulWidget {
  const PresetSection({super.key});

  @override
  ConsumerState<PresetSection> createState() => _PresetSectionState();
}

class _PresetSectionState extends ConsumerState<PresetSection> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsEnergySaving,
          note: l10n.settingsEnergySavingNote,
          children: [
            SettingSwitchTile(
              icon: prefs.energySavingMode
                  ? Icons.energy_savings_leaf
                  : Icons.energy_savings_leaf_outlined,
              title: l10n.settingsEnergySaving,
              subtitle: prefs.energySavingMode
                  ? l10n.settingsEnergySavingOn
                  : l10n.settingsEnergySavingOff,
              value: prefs.energySavingMode,
              onChanged: notifier.setEnergySaving,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsPerformanceMode,
          children: [
            SettingSwitchTile(
              icon: prefs.performanceMode ? Icons.bolt : Icons.bolt_outlined,
              title: l10n.settingsPerformanceMode,
              subtitle: prefs.performanceMode
                  ? l10n.settingsPerformanceModeOn
                  : l10n.settingsPerformanceModeOff,
              value: prefs.performanceMode,
              onChanged: notifier.setPerformanceMode,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionFilter,
          children: [
            SettingSwitchTile(
              icon: prefs.fuckDjMode
                  ? Icons.auto_fix_high
                  : Icons.auto_fix_high_outlined,
              title: l10n.settingsDjMode,
              subtitle: prefs.fuckDjMode
                  ? l10n.settingsDjModeOn
                  : l10n.settingsDjModeOff,
              value: prefs.fuckDjMode,
              onChanged: (v) => notifier.setPreset(fuckDjMode: v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionLyricsFilter,
          children: [
            SettingSwitchTile(
              icon: prefs.uncensorProfanity
                  ? Icons.auto_fix_normal
                  : Icons.auto_fix_normal_outlined,
              title: l10n.settingsUncensor,
              subtitle: prefs.uncensorProfanity
                  ? l10n.settingsUncensorOn
                  : l10n.settingsUncensorOff,
              value: prefs.uncensorProfanity,
              onChanged: (v) => notifier.setPreset(uncensorProfanity: v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionListDisplay,
          children: [
            SettingSwitchTile(
              icon: Icons.workspace_premium_outlined,
              title: l10n.settingsHideVip,
              subtitle: prefs.hideVipTag
                  ? l10n.settingsHideVipOn
                  : l10n.settingsHideVipOff,
              value: prefs.hideVipTag,
              onChanged: (v) => notifier.setPreset(hideVipTag: v),
            ),
            SettingSwitchTile(
              icon: Icons.high_quality_outlined,
              title: l10n.settingsHideQuality,
              subtitle: prefs.hideQualityTag
                  ? l10n.settingsHideQualityOn
                  : l10n.settingsHideQualityOff,
              value: prefs.hideQualityTag,
              onChanged: (v) => notifier.setPreset(hideQualityTag: v),
            ),
            SettingSwitchTile(
              icon: prefs.showSubtitle
                  ? Icons.subtitles
                  : Icons.subtitles_off_outlined,
              title: l10n.settingsShowSubtitle,
              subtitle: prefs.showSubtitle
                  ? l10n.settingsShowSubtitleOn
                  : l10n.settingsShowSubtitleOff,
              value: prefs.showSubtitle,
              onChanged: (v) => notifier.setPreset(showSubtitle: v),
            ),
          ],
        ),
      ],
    );
  }
}

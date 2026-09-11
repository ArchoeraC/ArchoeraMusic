// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 歌词 ──────────────────────────────────────────────────────────────

/// 歌词分类：播放器内歌词 / 播放条显示 / 歌词样式（字号、行高、配色）。
class LyricsSection extends ConsumerStatefulWidget {
  const LyricsSection({super.key});

  @override
  ConsumerState<LyricsSection> createState() => _LyricsSectionState();
}

class _LyricsSectionState extends ConsumerState<LyricsSection> {
  static const _lyricColorPresets = <int>[
    0xFF4DA3FF,
    0xFFE8EAF2,
    0xFFFF6B9D,
    0xFFFFB84D,
    0xFF4DDB9B,
    0xFF9AA1B5,
    0xFF5B8CFF,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionPlayerLyrics,
          children: [
            SettingSwitchTile(
              icon: prefs.showLyricsInPlayer
                  ? EtaIcons.fileMusicOutline
                  : EtaIcons.fileMusic,
              title: l10n.settingsPlayerLyrics,
              subtitle: prefs.showLyricsInPlayer
                  ? l10n.settingsPlayerLyricsOn
                  : l10n.settingsPlayerLyricsOff,
              value: prefs.showLyricsInPlayer,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setShowLyricsInPlayer(value),
            ),
            SettingSwitchTile(
              icon: prefs.barLyrics
                  ? EtaIcons.bookOutline
                  : EtaIcons.book,
              title: l10n.settingsBarLyrics,
              subtitle: prefs.barLyrics
                  ? l10n.settingsBarLyricsOn
                  : l10n.settingsBarLyricsOff,
              value: prefs.barLyrics,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setBarDisplay(barLyrics: value),
            ),
            SettingSwitchTile(
              icon: prefs.barEnhancedLyrics
                  ? EtaIcons.micOutline
                  : EtaIcons.mic,
              title: l10n.settingsBarEnhancedLyrics,
              subtitle: prefs.barEnhancedLyrics
                  ? l10n.settingsBarEnhancedLyricsOn
                  : l10n.settingsBarEnhancedLyricsOff,
              value: prefs.barEnhancedLyrics,
              onChanged: (value) {
                ref
                    .read(appPrefsProvider.notifier)
                    .setBarDisplay(barEnhancedLyrics: value);
                if (value) {
                  ref.read(appPrefsProvider.notifier).setShowTranslation(false);
                }
              },
            ),
            SettingSwitchTile(
              icon: prefs.showTranslation
                  ? EtaIcons.translate
                  : EtaIcons.translateOutline,
              title: l10n.settingsShowTranslation,
              subtitle: prefs.showTranslation
                  ? l10n.settingsShowTranslationOn
                  : l10n.settingsShowTranslationOff,
              value: prefs.showTranslation,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setShowTranslation(value),
              enabled: !prefs.barEnhancedLyrics,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionLyricEngine,
          note: l10n.settingsLyricEngineNote,
          children: [
            SettingTile(
              icon: EtaIcons.fileMusicOutline,
              title: l10n.settingsLyricEngine,
              subtitle: l10n.settingsLyricEngineDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('simple', l10n.settingsLyricEngineSimple),
                  SSegmentedOption('amll', l10n.settingsLyricEngineWall),
                ],
                selected: prefs.lyricEngine,
                onChanged: (v) =>
                    ref.read(appPrefsProvider.notifier).setLyricAmll(engine: v),
              ),
            ),
          ],
        ),
        if (prefs.lyricEngine == 'amll') ...[
          const SizedBox(height: 20),
          _buildAmllWallSection(l10n, scheme, prefs),
        ],
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionLyricStyle,
          note: l10n.settingsLyricsNote,
          children: [
            SettingSliderTile(
              icon: EtaIcons.fontSize,
              title: l10n.settingsLyricFontSize,
              subtitle: l10n.settingsLyricFontSizeDesc(
                prefs.lyricFontSize.round(),
              ),
              value: prefs.lyricFontSize,
              min: 14,
              max: 38,
              divisions: 24,
              label: '${prefs.lyricFontSize.round()}px',
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricStyle(fontSize: v),
            ),
            SettingSwitchTile(
              icon: EtaIcons.paletteOutline,
              title: l10n.settingsLyricFollowAccent,
              subtitle: l10n.settingsLyricFollowAccentDesc,
              value: prefs.lyricFollowAccent,
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricStyle(followAccent: v),
            ),
            SettingTile(
              icon: EtaIcons.paletteOutline,
              title: l10n.settingsLyricPlayedColor,
              subtitle: l10n.settingsLyricPlayedColorDesc,
              enabled: !prefs.lyricFollowAccent,
              trailing: _colorSwatches(
                scheme,
                current: prefs.lyricPlayedColor,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setLyricStyle(playedColor: v),
              ),
            ),
            SettingTile(
              icon: EtaIcons.paletteOutline,
              title: l10n.settingsLyricUnplayedColor,
              subtitle: l10n.settingsLyricUnplayedColorDesc,
              trailing: _colorSwatches(
                scheme,
                current: prefs.lyricUnplayedColor,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setLyricStyle(unplayedColor: v),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAmllWallSection(
    AppLocalizations l10n,
    ColorScheme scheme,
    AppPrefs prefs,
  ) {
    final notifier = ref.read(appPrefsProvider.notifier);
    return SettingSection(
      title: l10n.settingsSectionLyricWall,
      note: l10n.settingsAmllNote,
      children: [
        SettingSliderTile(
          icon: EtaIcons.aimingOutline,
          title: l10n.settingsAmllAlign,
          subtitle: '${(prefs.amllAlignFraction * 100).round()}%',
          value: prefs.amllAlignFraction,
          min: 0.15,
          max: 0.6,
          divisions: 45,
          onChanged: (v) => notifier.setLyricAmll(alignFraction: v),
        ),
        SettingSliderTile(
          icon: EtaIcons.drop,
          title: l10n.settingsAmllDim,
          subtitle: '${(prefs.amllInactiveAlpha * 100).round()}%',
          value: prefs.amllInactiveAlpha,
          min: 0.05,
          max: 1,
          divisions: 19,
          onChanged: (v) => notifier.setLyricAmll(inactiveAlpha: v),
        ),
        SettingSwitchTile(
          icon: EtaIcons.abcOutline,
          title: l10n.settingsAmllWordSweep,
          subtitle: '',
          value: prefs.amllWordSweep,
          onChanged: (v) => notifier.setLyricAmll(wordSweep: v),
        ),
        SettingSwitchTile(
          icon: EtaIcons.eyeCloseOutline,
          title: l10n.settingsAmllHidePassed,
          subtitle: '',
          value: prefs.amllHidePassed,
          onChanged: (v) => notifier.setLyricAmll(hidePassed: v),
        ),
        SettingSwitchTile(
          icon: EtaIcons.fullscreenExit2Outline,
          title: l10n.settingsAmllScale,
          subtitle: '',
          value: prefs.amllEnableScale,
          onChanged: (v) => notifier.setLyricAmll(enableScale: v),
        ),
        SettingTile(
          icon: EtaIcons.magic2Outline,
          title: l10n.settingsAmllSpring,
          subtitle: prefs.amllSpringPreset,
          trailing: DropdownButton<String>(
            value: prefs.amllSpringPreset,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              for (final p in const [
                'default',
                'smooth',
                'responsive',
                'jello',
                'heavy',
              ])
                DropdownMenuItem(value: p, child: Text(p)),
            ],
            onChanged: (v) {
              if (v != null) notifier.setLyricAmll(springPreset: v);
            },
          ),
        ),
      ],
    );
  }

  Widget _colorSwatches(
    ColorScheme scheme, {
    required int current,
    required ValueChanged<int> onChanged,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        for (final v in _lyricColorPresets)
          Tooltip(
            message: '#${(v & 0xFFFFFF).toRadixString(16).toUpperCase()}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onChanged(v),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(v),
                  border: Border.all(
                    color: current == v
                        ? scheme.onSurface
                        : scheme.outline.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: current == v
                    ? Icon(
                        EtaIcons.check,
                        size: 12,
                        color: Color(v).computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

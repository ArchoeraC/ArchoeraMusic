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
    0xFFD0D3DA,
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
            SettingSwitchTile(
              icon: EtaIcons.abcOutline,
              title: l10n.settingsShowRomanization,
              subtitle: prefs.showRomanization
                  ? l10n.settingsShowRomanizationOn
                  : l10n.settingsShowRomanizationOff,
              value: prefs.showRomanization,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setShowRomanization(value),
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
              max: 60,
              divisions: 46,
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
            SettingSwitchTile(
              icon: EtaIcons.fullscreen,
              title: l10n.settingsLyricAdaptiveFontSize,
              subtitle: prefs.lyricAdaptiveFontSize
                  ? l10n.settingsLyricAdaptiveFontSizeOn
                  : l10n.settingsLyricAdaptiveFontSizeOff,
              value: prefs.lyricAdaptiveFontSize,
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricAdaptiveFontSize(v),
            ),
            SettingTile(
              icon: EtaIcons.abcOutline,
              title: l10n.settingsLyricFontWeight,
              subtitle: l10n.settingsLyricFontWeightDesc,
              trailing: SSegmented<int>(
                options: [
                  SSegmentedOption(400, l10n.settingsLyricWeightRegular),
                  SSegmentedOption(500, l10n.settingsLyricWeightMedium),
                  SSegmentedOption(600, l10n.settingsLyricWeightSemiBold),
                  SSegmentedOption(700, l10n.settingsLyricWeightBold),
                ],
                selected: prefs.lyricFontWeight,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setLyricStyle(fontWeight: v),
              ),
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
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsLyricSourceOrder,
          note: l10n.settingsLyricOrderHint,
          children: [
            SettingTile(
              icon: EtaIcons.serverOutline,
              title: l10n.settingsLyricSourceOrder,
              subtitle: l10n.settingsLyricSourceOrderDesc,
              trailing: SButton(
                label: l10n.commonConfigure,
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () => _editSourceOrder(context, prefs),
              ),
            ),
            SettingTile(
              icon: EtaIcons.fileMusicOutline,
              title: l10n.settingsLyricFormatOrder,
              subtitle: l10n.settingsLyricFormatOrderDesc,
              trailing: SButton(
                label: l10n.commonConfigure,
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: () => _editFormatOrder(context, prefs),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionLyricExclude,
          children: [
            SettingSwitchTile(
              icon: prefs.lyricExcludeEnabled
                  ? EtaIcons.eyeCloseOutline
                  : EtaIcons.eyeOutline,
              title: l10n.settingsLyricExcludeEnabled,
              subtitle: prefs.lyricExcludeEnabled
                  ? l10n.settingsLyricExcludeEnabledOn
                  : l10n.settingsLyricExcludeEnabledOff,
              value: prefs.lyricExcludeEnabled,
              onChanged: (v) =>
                  ref.read(appPrefsProvider.notifier).setLyricExclude(enabled: v),
            ),
            SettingTile(
              icon: EtaIcons.magic2Outline,
              title: l10n.settingsLyricExcludeRules,
              subtitle: l10n.settingsLyricExcludeRulesDesc,
              enabled: prefs.lyricExcludeEnabled,
              trailing: SButton(
                label: l10n.commonConfigure,
                variant: SButtonVariant.secondary,
                size: SButtonSize.small,
                onPressed: prefs.lyricExcludeEnabled
                    ? () => _editExclude(context, prefs)
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 编辑歌词来源回退顺序。
  Future<void> _editSourceOrder(BuildContext context, AppPrefs prefs) async {
    final l10n = context.l10n;
    final result = await _showOrderDialog(
      context,
      title: l10n.settingsLyricSourceOrder,
      hint: l10n.settingsLyricOrderHint,
      ids: lyricPlatforms,
      initial: prefs.lyricSourceOrder,
      labelOf: (id) => _platformLabel(l10n, id),
    );
    if (result != null) {
      ref.read(appPrefsProvider.notifier).setLyricSourceOrder(result);
    }
  }

  /// 编辑歌词格式优先级。
  Future<void> _editFormatOrder(BuildContext context, AppPrefs prefs) async {
    final l10n = context.l10n;
    final result = await _showOrderDialog(
      context,
      title: l10n.settingsLyricFormatOrder,
      hint: l10n.settingsLyricOrderHint,
      ids: lyricFormats,
      initial: prefs.lyricFormatOrder,
      labelOf: (id) => id.toUpperCase(),
    );
    if (result != null) {
      ref.read(appPrefsProvider.notifier).setLyricFormatOrder(result);
    }
  }

  /// 编辑歌词排除规则（关键词 / 正则）。
  Future<void> _editExclude(BuildContext context, AppPrefs prefs) async {
    final result = await _showExcludeDialog(
      context,
      initialKeywords: prefs.lyricExcludeKeywords,
      initialRegexes: prefs.lyricExcludeRegexes,
    );
    if (result != null) {
      ref
          .read(appPrefsProvider.notifier)
          .setLyricExclude(keywords: result.$1, regexes: result.$2);
    }
  }

  /// 平台 id → 显示名。
  String _platformLabel(AppLocalizations l10n, String id) => switch (id) {
    'netease' => l10n.platformNetease,
    'qqmusic' => l10n.platformQQMusic,
    'kugou' => l10n.platformKugou,
    _ => id,
  };

  /// 失焦档位 → 显示名（`amll.blurQuality`）。
  String _blurQualityLabel(AppLocalizations l10n, String key) => switch (key) {
    'fast' => l10n.settingsAmllBlurFast,
    'quality' => l10n.settingsAmllBlurQuality,
    'off' => l10n.settingsAmllBlurOff,
    _ => l10n.settingsAmllBlurAuto,
  };

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
          icon: EtaIcons.blurOnOutline,
          title: l10n.settingsAmllBlur,
          subtitle: l10n.settingsAmllBlurNote,
          trailing: DropdownButton<String>(
            value: prefs.amllBlurQuality,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              for (final q in amllBlurQualities)
                DropdownMenuItem(
                  value: q,
                  child: Text(_blurQualityLabel(l10n, q)),
                ),
            ],
            onChanged: (v) {
              if (v != null) notifier.setLyricAmll(blurQuality: v);
            },
          ),
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

/// 弹出「顺序编辑」对话框（来源 / 格式共用）。返回拖拽后的顺序，取消返回 null。
Future<List<String>?> _showOrderDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> ids,
  required List<String> initial,
  required String Function(String) labelOf,
}) {
  return SDialog.show<List<String>>(
    context,
    title: title,
    description: hint,
    width: 440,
    child: _OrderEditor(ids: ids, initial: initial, labelOf: labelOf),
  );
}

/// 弹出「歌词排除规则」编辑对话框。返回（关键词, 正则），取消返回 null。
Future<(List<String>, List<String>)?> _showExcludeDialog(
  BuildContext context, {
  required List<String> initialKeywords,
  required List<String> initialRegexes,
}) {
  final l10n = context.l10n;
  return SDialog.show<(List<String>, List<String>)>(
    context,
    title: l10n.settingsLyricExcludeDialogTitle,
    description: l10n.settingsLyricExcludeDialogHint,
    width: 540,
    child: _ExcludeRulesEditor(
      initialKeywords: initialKeywords,
      initialRegexes: initialRegexes,
    ),
  );
}

/// 拖拽排序编辑器（固定高度 + 拖拽手柄；底部为重置/取消/保存）。
class _OrderEditor extends StatefulWidget {
  const _OrderEditor({
    required this.ids,
    required this.initial,
    required this.labelOf,
  });

  final List<String> ids;
  final List<String> initial;
  final String Function(String) labelOf;

  @override
  State<_OrderEditor> createState() => _OrderEditorState();
}

class _OrderEditorState extends State<_OrderEditor> {
  late List<String> _order = [...widget.initial];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: (widget.ids.length * 46).clamp(90, 320).toDouble(),
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: EdgeInsets.zero,
            itemCount: _order.length,
            onReorderItem: (oldIndex, newIndex) {
              setState(() {
                final item = _order.removeAt(oldIndex);
                _order.insert(newIndex, item);
              });
            },
            itemBuilder: (context, index) {
              final id = _order[index];
              return Padding(
                key: ValueKey(id),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: scheme.outline.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          widget.labelOf(id),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: Icon(
                          EtaIcons.menu,
                          size: 18,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            SButton(
              label: l10n.settingsLyricOrderReset,
              variant: SButtonVariant.secondary,
              onPressed: () => setState(() => _order = [...widget.ids]),
            ),
            const Spacer(),
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.commonSave,
              onPressed: () => Navigator.of(context).pop(_order),
            ),
          ],
        ),
      ],
    );
  }
}

/// 歌词排除规则编辑器（关键词 / 正则两个页签）。
class _ExcludeRulesEditor extends StatefulWidget {
  const _ExcludeRulesEditor({
    required this.initialKeywords,
    required this.initialRegexes,
  });

  final List<String> initialKeywords;
  final List<String> initialRegexes;

  @override
  State<_ExcludeRulesEditor> createState() => _ExcludeRulesEditorState();
}

class _ExcludeRulesEditorState extends State<_ExcludeRulesEditor> {
  late final List<String> _keywords = [...widget.initialKeywords];
  late final List<String> _regexes = [...widget.initialRegexes];
  final _ctrl = TextEditingController();
  String _tab = 'keywords';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _add() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    final l10n = context.l10n;
    if (_tab == 'regex') {
      try {
        RegExp(v);
      } catch (_) {
        toast(l10n.settingsLyricExcludeInvalidRegex, type: ToastType.error);
        return;
      }
      if (_regexes.contains(v)) {
        toast(l10n.settingsLyricExcludeDuplicate, type: ToastType.warning);
        return;
      }
      setState(() {
        _regexes.add(v);
        _ctrl.clear();
      });
    } else {
      if (_keywords.contains(v)) {
        toast(l10n.settingsLyricExcludeDuplicate, type: ToastType.warning);
        return;
      }
      setState(() {
        _keywords.add(v);
        _ctrl.clear();
      });
    }
  }

  void _clearActive() {
    setState(() {
      if (_tab == 'regex') {
        _regexes.clear();
      } else {
        _keywords.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final list = _tab == 'regex' ? _regexes : _keywords;
    final hint = _tab == 'regex'
        ? l10n.settingsLyricExcludeRegexHint
        : l10n.settingsLyricExcludeKeywordHint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SSegmented<String>(
          options: [
            SSegmentedOption(
              'keywords',
              l10n.settingsLyricExcludeTabKeywords,
            ),
            SSegmentedOption('regex', l10n.settingsLyricExcludeTabRegex),
          ],
          selected: _tab,
          onChanged: (v) => setState(() => _tab = v),
        ),
        const SizedBox(height: 12),
        Text(
          hint,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.settingsLyricExcludePlaceholder,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            SButton(label: l10n.settingsLyricExcludeAdd, onPressed: _add),
          ],
        ),
        const SizedBox(height: 14),
        if (list.isEmpty)
          Text(
            l10n.settingsLyricExcludeEmpty,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < list.length; i++)
                _chip(list[i], () => setState(() => list.removeAt(i))),
            ],
          ),
        const SizedBox(height: 18),
        Row(
          children: [
            SButton(
              label: l10n.settingsLyricExcludeClear,
              variant: SButtonVariant.secondary,
              onPressed: _clearActive,
            ),
            const Spacer(),
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            SButton(
              label: l10n.commonSave,
              onPressed: () => Navigator.of(context).pop((_keywords, _regexes)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(String text, VoidCallback onDelete) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(width: 4),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: onDelete,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                EtaIcons.close,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

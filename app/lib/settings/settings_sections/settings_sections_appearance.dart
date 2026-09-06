// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 外观 ──────────────────────────────────────────────────────────────

/// 外观分类：主题 / 主色 / 全局着色 / 外观风格（背景图）/ 布局 / 字体 /
/// 语言 / 封面圆角。
class AppearanceSection extends ConsumerStatefulWidget {
  const AppearanceSection({super.key});

  @override
  ConsumerState<AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends ConsumerState<AppearanceSection> {
  static const _accentPresets = <int?>[
    null,
    0xFF5B8CFF,
    0xFF9B8CFF,
    0xFFFF6B9D,
    0xFFFF6B61,
    0xFFFFA24D,
    0xFF4DDB9B,
    0xFF4DD8E0,
  ];

  static const _localeSystem = '__system__';

  /// 手动城市输入框（填写后不再进行 IP 定位）。
  final _cityCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cityCtrl.text = ref.read(appPrefsProvider).weatherCity ?? '';
  }

  @override
  void dispose() {
    _cityCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final themeMode = ref.watch(themeModeProvider);
    final prefs = ref.watch(appPrefsProvider);
    final accent = prefs.accent;
    final notifier = ref.read(appPrefsProvider.notifier);
    // 图片风格「有效」才有背景子项可调（无图时回退 solid，对齐原版 effectiveStyle）
    final imageStyle =
        prefs.appearanceStyle == 'image' && prefs.backgroundImage != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionTheme,
          note: l10n.settingsThemeNote,
          children: [
            SettingTile(
              icon: Icons.dark_mode_outlined,
              title: l10n.settingsThemeMode,
              subtitle: l10n.settingsThemeModeDesc,
              trailing: SSegmented<ThemeMode>(
                options: [
                  SSegmentedOption(ThemeMode.light, l10n.settingsThemeLight),
                  SSegmentedOption(ThemeMode.dark, l10n.settingsThemeDark),
                  SSegmentedOption(ThemeMode.system, l10n.settingsThemeSystem),
                ],
                selected: themeMode,
                onChanged: (mode) =>
                    ref.read(themeModeProvider.notifier).setMode(mode),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionAccent,
          children: [
            SettingTile(
              icon: Icons.color_lens_outlined,
              title: l10n.settingsThemeSource,
              subtitle: l10n.settingsThemeSourceDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('default', l10n.settingsThemeSourceDefault),
                  SSegmentedOption('custom', l10n.settingsThemeSourceCustom),
                  SSegmentedOption('cover', l10n.settingsThemeSourceCover),
                  SSegmentedOption('solid', l10n.settingsThemeSourceSolid),
                ],
                selected: prefs.themeSource,
                onChanged: (v) => notifier.setThemeSource(v),
              ),
            ),
          ],
        ),
        if (prefs.themeSource == 'custom') ...[
          const SizedBox(height: 8),
          SettingCard(
            children: [
              SettingTile(
                icon: Icons.palette_outlined,
                title: l10n.settingsAccentTitle,
                subtitle: l10n.settingsThemeSourceCustomHint,
                trailing: _accentSwatches(scheme, accent, l10n),
              ),
            ],
          ),
        ] else if (prefs.themeSource == 'cover') ...[
          const SizedBox(height: 8),
          SettingNote(text: l10n.settingsThemeSourceCoverHint),
        ],
        const SizedBox(height: 12),
        SettingCard(
          children: [
            SettingSwitchTile(
              icon: Icons.tonality_outlined,
              title: l10n.settingsGlobalTint,
              subtitle: l10n.settingsGlobalTintDesc,
              value: prefs.globalTint,
              onChanged: notifier.setGlobalTint,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SettingNote(text: l10n.settingsGlobalTintNote),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionStyle,
          children: [
            SettingTile(
              icon: Icons.image_outlined,
              title: l10n.settingsAppearanceStyle,
              subtitle: l10n.settingsAppearanceStyleDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('solid', l10n.settingsAppearanceStyleSolid),
                  SSegmentedOption('image', l10n.settingsAppearanceStyleImage),
                ],
                selected: prefs.appearanceStyle,
                onChanged: (v) => notifier.setAppearanceStyle(v),
              ),
            ),
          ],
        ),
        if (prefs.appearanceStyle == 'image') ...[
          const SizedBox(height: 8),
          _backgroundCard(scheme, prefs, l10n, notifier),
          if (imageStyle) ...[
            const SizedBox(height: 12),
            SettingCard(
              children: [
                SettingSliderTile(
                  icon: Icons.blur_on_outlined,
                  title: l10n.settingsBackgroundBlur,
                  subtitle: l10n.settingsBackgroundBlurDesc(
                    prefs.backgroundBlur,
                  ),
                  value: prefs.backgroundBlur.toDouble(),
                  min: 0,
                  max: 80,
                  divisions: 16,
                  label: '${prefs.backgroundBlur}px',
                  onChanged: (v) => notifier.setBackground(blur: v.round()),
                ),
                SettingSliderTile(
                  icon: Icons.dark_mode_outlined,
                  title: l10n.settingsBackgroundDim,
                  subtitle: l10n.settingsBackgroundDimDesc(prefs.backgroundDim),
                  value: prefs.backgroundDim,
                  min: 0.3,
                  max: 0.9,
                  divisions: 12,
                  label: '${(prefs.backgroundDim * 100).round()}%',
                  onChanged: (v) => notifier.setBackground(dim: v),
                ),
                SettingSliderTile(
                  icon: Icons.zoom_out_map_outlined,
                  title: l10n.settingsBackgroundScale,
                  subtitle: l10n.settingsBackgroundScaleDesc(
                    prefs.backgroundScale,
                  ),
                  value: prefs.backgroundScale,
                  min: 1,
                  max: 2,
                  divisions: 20,
                  label: '${prefs.backgroundScale.toStringAsFixed(1)}x',
                  onChanged: (v) => notifier.setBackground(scale: v),
                ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionLayout,
          children: [
            SettingSwitchTile(
              icon: Icons.rounded_corner,
              title: l10n.settingsFloatingBar,
              subtitle: prefs.floatingPlayerBar
                  ? l10n.settingsFloatingBarOn
                  : l10n.settingsFloatingBarOff,
              value: prefs.floatingPlayerBar,
              onChanged: notifier.setFloatingPlayerBar,
            ),
            SettingSwitchTile(
              icon: prefs.sidebarCollapsed
                  ? Icons.menu_open
                  : Icons.menu_rounded,
              title: l10n.settingsSidebarCollapsed,
              subtitle: l10n.settingsSidebarCollapsedDesc,
              value: prefs.sidebarCollapsed,
              onChanged: (value) => notifier.setSidebar(collapsed: value),
            ),
            SettingTile(
              icon: Icons.arrow_right_alt,
              title: l10n.settingsSidebarNavStyle,
              subtitle: l10n.settingsSidebarNavStyleDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption(
                    'default',
                    l10n.settingsSidebarNavStyleDefault,
                  ),
                  SSegmentedOption(
                    'animated',
                    l10n.settingsSidebarNavStyleAnimated,
                  ),
                ],
                selected: prefs.sidebarNavStyle,
                onChanged: (v) => notifier.setSidebar(navStyle: v),
              ),
            ),
            SettingTile(
              icon: Icons.animation_outlined,
              title: l10n.settingsRouteTransition,
              subtitle: l10n.settingsRouteTransitionDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('none', l10n.settingsRouteTransitionNone),
                  SSegmentedOption('fade', l10n.settingsRouteTransitionFade),
                  SSegmentedOption('slide', l10n.settingsRouteTransitionSlide),
                  SSegmentedOption('zoom', l10n.settingsRouteTransitionZoom),
                ],
                selected: prefs.routeTransition,
                onChanged: (v) => notifier.setRouteTransition(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionFont,
          children: [
            SettingTile(
              icon: Icons.font_download_outlined,
              title: l10n.settingsFontTitle,
              subtitle: switch (prefs.fontFamily) {
                'MiSans' => l10n.settingsFontMiSans,
                'Noto Sans SC' => l10n.settingsFontNoto,
                _ => l10n.settingsFontHarmony,
              },
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('MiSans', l10n.settingsFontMiSansLabel),
                  SSegmentedOption('Noto Sans SC', l10n.settingsFontNotoLabel),
                  SSegmentedOption(
                    'HarmonyOS Sans SC',
                    l10n.settingsFontHarmonyLabel,
                  ),
                ],
                selected: prefs.fontFamily,
                onChanged: (family) => notifier.setFontFamily(family),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionLanguage,
          children: [
            SettingTile(
              icon: Icons.language_outlined,
              title: l10n.settingsLanguageTitle,
              subtitle: l10n.settingsLanguageDesc,
              trailing: _languageDropdown(scheme, prefs.locale, l10n),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionCover,
          children: [
            SettingTile(
              icon: Icons.crop_square,
              title: l10n.settingsCoverRadius,
              subtitle: prefs.coverRadius == 0
                  ? l10n.settingsCoverRadiusSharp
                  : l10n.settingsCoverRadiusPx(prefs.coverRadius.round()),
              trailing: SSegmented<double>(
                options: [
                  SSegmentedOption(0, l10n.settingsCoverRadiusSharpLabel),
                  SSegmentedOption(8, l10n.settingsCoverRadiusRoundedLabel),
                  SSegmentedOption(12, l10n.settingsCoverRadiusLargeLabel),
                ],
                selected: prefs.coverRadius,
                onChanged: (v) => notifier.setCoverRadius(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionWeather,
          note: l10n.settingsWeatherNote,
          children: [
            SettingSwitchTile(
              icon: Icons.wb_sunny_outlined,
              title: l10n.settingsWeather,
              subtitle: l10n.settingsWeatherDesc,
              value: prefs.weatherEnabled,
              onChanged: (v) => _setWeatherEnabled(context, l10n, notifier, v),
            ),
            if (prefs.weatherEnabled) ...[
              SettingSwitchTile(
                icon: Icons.my_location_outlined,
                title: l10n.settingsWeatherAutoLocate,
                subtitle: l10n.settingsWeatherAutoLocateDesc,
                value: prefs.weatherAutoLocate,
                onChanged: (v) =>
                    _setWeatherAutoLocate(context, l10n, notifier, v),
              ),
              if (prefs.weatherAutoLocate)
                SettingTile(
                  icon: Icons.gps_fixed_outlined,
                  title: l10n.settingsWeatherLocateSource,
                  subtitle: l10n.settingsWeatherLocateSourceDesc,
                  trailing: SSegmented<String>(
                    options: [
                      SSegmentedOption(
                        'ip',
                        l10n.settingsWeatherLocateSourceIp,
                      ),
                      SSegmentedOption(
                        'system',
                        l10n.settingsWeatherLocateSourceSystem,
                      ),
                    ],
                    selected: prefs.weatherLocateSource,
                    onChanged: (v) =>
                        _setWeatherLocateSource(context, l10n, notifier, v),
                  ),
                ),
              _weatherCityField(scheme, l10n, notifier),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _setWeatherEnabled(
    BuildContext context,
    AppLocalizations l10n,
    AppPrefsNotifier notifier,
    bool v,
  ) async {
    if (v &&
        !(await _confirmPrivacy(
          context,
          l10n,
          title: l10n.settingsWeatherPrivacyTitle,
          body: l10n.settingsWeatherPrivacyBody,
        ))) {
      return;
    }
    notifier.setWeatherEnabled(v);
  }

  Future<void> _setWeatherAutoLocate(
    BuildContext context,
    AppLocalizations l10n,
    AppPrefsNotifier notifier,
    bool v,
  ) async {
    if (v &&
        !(await _confirmPrivacy(
          context,
          l10n,
          title: l10n.settingsWeatherAutoLocateTitle,
          body: l10n.settingsWeatherAutoLocateBody,
        ))) {
      return;
    }
    notifier.setWeatherAutoLocate(v);
  }

  Future<void> _setWeatherLocateSource(
    BuildContext context,
    AppLocalizations l10n,
    AppPrefsNotifier notifier,
    String v,
  ) async {
    if (v == 'system' &&
        ref.read(appPrefsProvider).weatherLocateSource != 'system' &&
        !(await _confirmPrivacy(
          context,
          l10n,
          title: l10n.settingsWeatherLocateSystemTitle,
          body: l10n.settingsWeatherLocateSystemBody,
        ))) {
      return;
    }
    notifier.setWeatherLocateSource(v);
  }

  Future<bool> _confirmPrivacy(
    BuildContext context,
    AppLocalizations l10n, {
    required String title,
    required String body,
  }) async {
    final ok = await SDialog.show<bool>(
      context,
      title: title,
      description: body,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsWeatherPrivacyEnable,
          variant: SButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return ok ?? false;
  }

  Widget _weatherCityField(
    ColorScheme scheme,
    AppLocalizations l10n,
    AppPrefsNotifier notifier,
  ) {
    return SettingCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.location_city_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsWeatherCity,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsWeatherCityHint,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: _cityCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: l10n.settingsWeatherCity,
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onSubmitted: (v) {
                    final t = v.trim();
                    notifier.setWeatherCity(t.isEmpty ? null : t);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _backgroundCard(
    ColorScheme scheme,
    AppPrefs prefs,
    AppLocalizations l10n,
    AppPrefsNotifier notifier,
  ) {
    final path = prefs.backgroundImage;
    return SettingCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.wallpaper_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsBackgroundImage,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      path ?? l10n.settingsBackgroundImageDesc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (path != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(path),
                    width: 96,
                    height: 56,
                    fit: BoxFit.cover,
                    cacheWidth: 96,
                    cacheHeight: 56,
                    errorBuilder: (_, _, _) => Container(
                      width: 96,
                      height: 56,
                      color: scheme.onSurface.withValues(alpha: 0.06),
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: 20,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                height: 28,
                child: SButton(
                  label: path == null
                      ? l10n.settingsBackgroundPick
                      : l10n.settingsBackgroundReplace,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.small,
                  onPressed: _pickBackgroundImage,
                ),
              ),
              if (path != null) ...[
                const SizedBox(width: 6),
                SizedBox(
                  height: 28,
                  child: SButton(
                    label: l10n.settingsBackgroundClear,
                    variant: SButtonVariant.ghost,
                    size: SButtonSize.small,
                    onPressed: () => notifier.setBackground(image: null),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickBackgroundImage() async {
    const typeGroup = XTypeGroup(
      label: 'images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    );
    String? path;
    try {
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      path = file?.path;
    } catch (_) {
      // 文件选择器不可用时静默忽略（自用项目，无返回值不阻塞）
    }
    if (path == null || !mounted) return;
    ref.read(appPrefsProvider.notifier).setBackground(image: path);
  }

  List<(String, String)> _localeOptions(AppLocalizations l10n) => [
    (_localeSystem, l10n.settingsLangSystem),
    ('zh-CN', '简体中文'),
    ('zh-TW', '繁體中文'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
    ('es', 'Español'),
    ('fr', 'Français'),
    ('de', 'Deutsch'),
  ];

  Widget _languageDropdown(
    ColorScheme scheme,
    String? current,
    AppLocalizations l10n,
  ) {
    final selected = current ?? _localeSystem;
    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: DropdownButton<String>(
          value: selected,
          isDense: true,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(10),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          icon: Icon(
            Icons.arrow_drop_down,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          selectedItemBuilder: (context) => [
            for (final (_, label) in _localeOptions(l10n))
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          onChanged: (code) {
            if (code == null) return;
            ref
                .read(appPrefsProvider.notifier)
                .setLocale(code == _localeSystem ? null : code);
          },
          items: [
            for (final (code, label) in _localeOptions(l10n))
              DropdownMenuItem(value: code, child: Text(label)),
          ],
        ),
      ),
    );
  }

  Widget _accentSwatches(
    ColorScheme scheme,
    int? accent,
    AppLocalizations l10n,
  ) {
    final currentColor = accent == null ? scheme.primary : Color(accent);
    final customSelected = accent != null && !_accentPresets.contains(accent);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final v in _accentPresets)
          Tooltip(
            message: v == null
                ? l10n.settingsAccentDefaultTooltip
                : '#${(v & 0xFFFFFF).toRadixString(16).toUpperCase()}',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                ref.read(appPrefsProvider.notifier).setAccent(v);
              },
              child: _swatchCircle(
                scheme,
                color: v == null ? scheme.primary : Color(v),
                selected: accent == v,
                checkColor: v == null
                    ? scheme.onPrimary
                    : Color(v).computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              ),
            ),
          ),
        const SizedBox(width: 4),
        Tooltip(
          message: l10n.settingsAccentCustomTooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _pickAccent(scheme, accent, l10n),
            child: _swatchCircle(
              scheme,
              color: currentColor,
              selected: customSelected,
              icon: Icons.colorize,
              iconColor: customSelected
                  ? scheme.primary
                  : currentColor.computeLuminance() > 0.5
                  ? Colors.black
                  : Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _swatchCircle(
    ColorScheme scheme, {
    required Color color,
    required bool selected,
    Color? checkColor,
    IconData? icon,
    Color? iconColor,
  }) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: selected ? scheme.onSurface : Colors.transparent,
          width: 2,
        ),
      ),
      child: icon != null
          ? Icon(icon, size: 14, color: iconColor)
          : (selected ? Icon(Icons.check, size: 14, color: checkColor) : null),
    );
  }

  Future<void> _pickAccent(
    ColorScheme scheme,
    int? accent,
    AppLocalizations l10n,
  ) async {
    final color = await showDialog<Color>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => AccentPickerDialog(
        initial: accent == null ? scheme.primary : Color(accent),
        l10n: l10n,
      ),
    );
    if (color == null || !mounted) return;
    ref.read(appPrefsProvider.notifier).setAccent(color.toARGB32());
  }
}

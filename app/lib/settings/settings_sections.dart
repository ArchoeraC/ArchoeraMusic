/// 设置弹窗各分类内容组件（从 settings_dialog.dart 拆出，独立类组件）。
///
/// 每个分类一个 `ConsumerStatefulWidget`，自行持有分类专属的控制器 /
/// 草稿值 / 私有辅助方法，仅在 build 内从 ref 读取偏好与 l10n。
library;

import 'dart:convert' show jsonEncode;
import 'dart:io' show File;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../app/theme_provider.dart';
import '../services/downloader/download_controller.dart';
import '../services/playback/playback_notifier.dart';
import '../services/scraper/scrape_controller.dart';
import '../stores/app_prefs.dart';
import '../stores/data_dir.dart';
import '../theme/app_theme.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/s_dialog.dart';
import '../widgets/player/s_controls.dart';
import 'settings_color_picker.dart';
import 'settings_widgets.dart';

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
        // ── 主题 ──
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

        // 主题色来源（default / custom / cover / solid）
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

        // 全局着色
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

        // ── 外观风格（纯色 / 图片背景）──
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

        // ── 布局 ──
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

        // ── 字体 ──
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

        // ── 语言 ──
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

        // ── 封面圆角 ──
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

        // ── 天气（顶栏微型组件；默认关闭，隐私优先）──
        SettingSection(
          title: l10n.settingsSectionWeather,
          note: l10n.settingsWeatherNote,
          children: [
            SettingSwitchTile(
              icon: Icons.wb_sunny_outlined,
              title: l10n.settingsWeather,
              subtitle: l10n.settingsWeatherDesc,
              value: prefs.weatherEnabled,
              onChanged: notifier.setWeatherEnabled,
            ),
            if (prefs.weatherEnabled) ...[
              SettingSwitchTile(
                icon: Icons.my_location_outlined,
                title: l10n.settingsWeatherAutoLocate,
                subtitle: l10n.settingsWeatherAutoLocateDesc,
                value: prefs.weatherAutoLocate,
                onChanged: notifier.setWeatherAutoLocate,
              ),
              _weatherCityField(scheme, l10n, notifier),
            ],
          ],
        ),
      ],
    );
  }

  /// 手动城市输入卡（填写后不再进行 IP 定位；回车保存）。
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

  /// 背景图选择卡（对齐原版 BackgroundImagePicker：横向预览 + 替换/清除）。
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
              // 横向预览（对齐原版 96×56）
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

  /// 语言下拉（紧凑 DropdownButton：展开/收起自带高度过渡 + 箭头旋转动效；
  /// 受控 value 语言切换后自动更新，无需额外包裹层）。
  Widget _languageDropdown(
    ColorScheme scheme,
    String? current,
    AppLocalizations l10n,
  ) {
    final selected = current ?? _localeSystem;
    return Theme(
      // 隐藏 DropdownButton 的悬停高亮 / 点击涟漪效果（纯文本按钮样式）
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
          // 选中项固定最大宽度防截断溢出（弹出菜单仍按 items 全宽显示）
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
      // 与其他弹窗一致的全局变暗遮罩（而非 Flutter 默认 black54 遮罩）
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

// ── 播放 ──────────────────────────────────────────────────────────────

/// 播放分类：直通 / 会话记忆 / 关闭行为 / 电源 / 频谱 / 切歌动效 / 快捷键。
class PlaybackSection extends ConsumerStatefulWidget {
  const PlaybackSection({super.key});

  @override
  ConsumerState<PlaybackSection> createState() => _PlaybackSectionState();
}

class _PlaybackSectionState extends ConsumerState<PlaybackSection> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionAudio,
          children: [
            SettingSwitchTile(
              icon: prefs.passthrough
                  ? Icons.high_quality_outlined
                  : Icons.transform_rounded,
              title: l10n.settingsPassthrough,
              subtitle: prefs.passthrough
                  ? l10n.settingsPassthroughOn
                  : l10n.settingsPassthroughOff,
              value: prefs.passthrough,
              onChanged: (value) {
                ref.read(appPrefsProvider.notifier).setPassthrough(value);
                ref.read(playbackProvider.notifier).reload();
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionMemory,
          children: [
            SettingSwitchTile(
              icon: prefs.sessionMemory
                  ? Icons.history
                  : Icons.history_toggle_off,
              title: l10n.settingsSessionMemory,
              subtitle: prefs.sessionMemory
                  ? l10n.settingsSessionMemoryOn
                  : l10n.settingsSessionMemoryOff,
              value: prefs.sessionMemory,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setMemoryEnabled(value),
            ),
            SettingSwitchTile(
              icon: prefs.autoPlayOnLaunch
                  ? Icons.play_circle_outline
                  : Icons.pause_circle_outline,
              title: l10n.settingsAutoPlay,
              subtitle: !prefs.sessionMemory
                  ? l10n.settingsAutoPlayNeedMemory
                  : prefs.autoPlayOnLaunch
                  ? l10n.settingsAutoPlayOn
                  : l10n.settingsAutoPlayOff,
              value: prefs.sessionMemory && prefs.autoPlayOnLaunch,
              onChanged: prefs.sessionMemory
                  ? (value) => ref
                        .read(appPrefsProvider.notifier)
                        .setAutoPlayOnLaunch(value)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionClose,
          children: [
            SettingTile(
              icon: Icons.power_settings_new_outlined,
              title: l10n.settingsCloseBehavior,
              subtitle: switch (prefs.closeBehavior) {
                'background' => l10n.settingsCloseBehaviorBackground,
                'quit' => l10n.settingsCloseBehaviorQuit,
                _ => l10n.settingsCloseBehaviorAsk,
              },
              trailing: DropdownButton<String>(
                value: prefs.closeBehavior,
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
                  color: scheme.onSurfaceVariant,
                ),
                onChanged: (v) {
                  if (v == null) return;
                  ref.read(appPrefsProvider.notifier).setCloseBehavior(v);
                },
                items: [
                  DropdownMenuItem(
                    value: 'ask',
                    child: Text(l10n.settingsCloseBehaviorAsk),
                  ),
                  DropdownMenuItem(
                    value: 'background',
                    child: Text(l10n.settingsCloseBehaviorBackground),
                  ),
                  DropdownMenuItem(
                    value: 'quit',
                    child: Text(l10n.settingsCloseBehaviorQuit),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionPower,
          children: [
            SettingSwitchTile(
              icon: prefs.powerSaver
                  ? Icons.energy_savings_leaf
                  : Icons.energy_savings_leaf_outlined,
              title: l10n.settingsPowerSaver,
              subtitle: prefs.powerSaver
                  ? l10n.settingsPowerSaverOn
                  : l10n.settingsPowerSaverOff,
              value: prefs.powerSaver,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setPowerSaver(value),
            ),
            SettingSwitchTile(
              icon: prefs.suppressSleep
                  ? Icons.bedtime_off_outlined
                  : Icons.bedtime_outlined,
              title: l10n.settingsSuppressSleep,
              subtitle: prefs.suppressSleep
                  ? l10n.settingsSuppressSleepOn
                  : l10n.settingsSuppressSleepOff,
              value: prefs.suppressSleep,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setSuppressSleep(value),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionSpectrum,
          children: [
            SettingSwitchTile(
              icon: prefs.enableSpectrum
                  ? Icons.graphic_eq
                  : Icons.graphic_eq_outlined,
              title: l10n.settingsSpectrum,
              subtitle: prefs.enableSpectrum
                  ? l10n.settingsSpectrumOn
                  : l10n.settingsSpectrumOff,
              value: prefs.enableSpectrum,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setSpectrumEnabled(value),
            ),
            // 封面跟随节拍缩放（播放界面封面随鼓点脉冲缩放；依赖频谱数据，
            // 性能模式自动停用）
            SettingSwitchTile(
              icon: prefs.coverBeatScale
                  ? Icons.music_note
                  : Icons.music_note_outlined,
              title: l10n.settingsCoverBeatScale,
              subtitle: prefs.coverBeatScale
                  ? l10n.settingsCoverBeatScaleOn
                  : l10n.settingsCoverBeatScaleOff,
              value: prefs.coverBeatScale,
              onChanged: (value) =>
                  ref.read(appPrefsProvider.notifier).setCoverBeatScale(value),
            ),
            SettingSliderTile(
              icon: Icons.view_column_outlined,
              title: l10n.settingsSpectrumBarWidth,
              subtitle: l10n.settingsSpectrumBarWidthDesc(
                prefs.spectrumBarWidth,
              ),
              value: prefs.spectrumBarWidth.toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              label: '${prefs.spectrumBarWidth}px',
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setSpectrumBarWidth(v.round()),
            ),
            // 频谱样式：三种独立渲染效果（经典条形 / 双向波形 / 单向波形），
            // 复用同一 FFT 数据缓冲，资源开销等同
            SettingTile(
              icon: Icons.blur_circular_outlined,
              title: l10n.settingsSpectrumStyle,
              subtitle: l10n.settingsSpectrumStyleDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption(
                    'bars',
                    l10n.settingsSpectrumStyleBars,
                  ),
                  SSegmentedOption(
                    'wave',
                    l10n.settingsSpectrumStyleWave,
                  ),
                  SSegmentedOption(
                    'waveUp',
                    l10n.settingsSpectrumStyleWaveUp,
                  ),
                ],
                selected: prefs.spectrumStyle,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setSpectrumStyle(v),
              ),
            ),
            // 播放条迷你频谱：与全局「频谱」开关解耦（SpectrumView.enabled
            // 优先）；有歌词且开启「播放条歌词」时迷你频谱不显示
            SettingSwitchTile(
              icon: prefs.barSpectrum
                  ? Icons.bar_chart
                  : Icons.bar_chart_outlined,
              title: l10n.settingsBarSpectrum,
              subtitle: prefs.barSpectrum
                  ? l10n.settingsBarSpectrumOn
                  : l10n.settingsBarSpectrumOff,
              value: prefs.barSpectrum,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setBarDisplay(barSpectrum: value),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsTransitionStyle,
          children: [
            SettingTile(
              icon: Icons.animation_outlined,
              title: l10n.settingsTransitionStyle,
              subtitle: l10n.settingsTransitionStyleDesc,
              trailing: SSegmented<String>(
                options: [
                  SSegmentedOption('scale', l10n.settingsTransitionStyleScale),
                  SSegmentedOption('slide', l10n.settingsTransitionStyleSlide),
                ],
                selected: prefs.transitionStyle,
                onChanged: (v) =>
                    ref.read(appPrefsProvider.notifier).setTransitionStyle(v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionShortcuts,
          children: [
            SettingTile(
              icon: Icons.space_bar,
              title: l10n.settingsShortcutSpace,
              subtitle: l10n.settingsShortcutSpaceDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: Icons.swap_horiz,
              title: l10n.settingsShortcutArrows,
              subtitle: l10n.settingsShortcutArrowsDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: Icons.search,
              title: l10n.settingsShortcutSearch,
              subtitle: l10n.commonSearch,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: Icons.library_music_outlined,
              title: l10n.settingsShortcutLibrary,
              subtitle: l10n.settingsShortcutLibraryDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: Icons.keyboard_return,
              title: l10n.settingsShortcutEsc,
              subtitle: l10n.settingsShortcutEscDesc,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    );
  }
}

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
                  ? Icons.lyrics_outlined
                  : Icons.lyrics,
              title: l10n.settingsPlayerLyrics,
              subtitle: prefs.showLyricsInPlayer
                  ? l10n.settingsPlayerLyricsOn
                  : l10n.settingsPlayerLyricsOff,
              value: prefs.showLyricsInPlayer,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setShowLyricsInPlayer(value),
            ),
            // 播放条迷你歌词：有歌词时在播放条时间下方替代迷你频谱显示
            SettingSwitchTile(
              icon: prefs.barLyrics
                  ? Icons.menu_book_outlined
                  : Icons.menu_book,
              title: l10n.settingsBarLyrics,
              subtitle: prefs.barLyrics
                  ? l10n.settingsBarLyricsOn
                  : l10n.settingsBarLyricsOff,
              value: prefs.barLyrics,
              onChanged: (value) => ref
                  .read(appPrefsProvider.notifier)
                  .setBarDisplay(barLyrics: value),
            ),
            // 播放条高级歌词：歌词含逐字时间轴（YRC/KRC）时卡拉OK 逐字高亮；
            // 开启时自动关闭翻译并禁用翻译开关（逐字高亮与翻译互斥）
            SettingSwitchTile(
              icon: prefs.barEnhancedLyrics
                  ? Icons.mic_external_on_outlined
                  : Icons.mic_external_on,
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
            // 显示翻译：全屏播放器歌词 + 播放条迷你歌词共用；卡拉OK 开启时禁用
            SettingSwitchTile(
              icon: prefs.showTranslation
                  ? Icons.translate
                  : Icons.translate_outlined,
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
          title: l10n.settingsSectionLyricStyle,
          note: l10n.settingsLyricsNote,
          children: [
            SettingSliderTile(
              icon: Icons.format_size,
              title: l10n.settingsLyricFontSize,
              subtitle: l10n.settingsLyricFontSizeDesc(
                prefs.lyricFontSize.round(),
              ),
              value: prefs.lyricFontSize,
              min: 14,
              max: 28,
              divisions: 14,
              label: '${prefs.lyricFontSize.round()}px',
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricStyle(fontSize: v),
            ),
            SettingSliderTile(
              icon: Icons.line_weight,
              title: l10n.settingsLyricLineHeight,
              subtitle: l10n.settingsLyricLineHeightDesc(
                prefs.lyricLineHeight.round(),
              ),
              value: prefs.lyricLineHeight,
              min: 42,
              max: 64,
              divisions: 11,
              label: '${prefs.lyricLineHeight.round()}px',
              onChanged: (v) => ref
                  .read(appPrefsProvider.notifier)
                  .setLyricStyle(lineHeight: v),
            ),
            SettingTile(
              icon: Icons.palette_outlined,
              title: l10n.settingsLyricPlayedColor,
              subtitle: l10n.settingsLyricPlayedColorDesc,
              trailing: _colorSwatches(
                scheme,
                current: prefs.lyricPlayedColor,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setLyricStyle(playedColor: v),
              ),
            ),
            SettingTile(
              icon: Icons.palette_outlined,
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
                        Icons.check,
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
        // 节能模式：降低频谱取帧频率（300ms 一帧）以节省 CPU
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
        // 性能模式：关闭所有动效 + 自动关闭音频频谱（全局开关）
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

// ── 下载 ──────────────────────────────────────────────────────────────

/// 下载分类（开发者模式可见）：根目录 / 文件名模板 / 音质 / 并发 /
/// 分组策略 / 限速 / 记录上限。
class DownloadSection extends ConsumerStatefulWidget {
  const DownloadSection({super.key});

  @override
  ConsumerState<DownloadSection> createState() => _DownloadSectionState();
}

class _DownloadSectionState extends ConsumerState<DownloadSection> {
  late final TextEditingController _downloadRootCtrl;
  late final TextEditingController _downloadTemplateCtrl;
  double? _downloadConcurrentDraft;
  double? _downloadSpeedDraft;
  double? _downloadHistoryLimitDraft;

  @override
  void initState() {
    super.initState();
    _downloadRootCtrl = TextEditingController(
      text: ref.read(appPrefsProvider).downloadRoot,
    );
    _downloadTemplateCtrl = TextEditingController(
      text: ref.read(appPrefsProvider).downloadFilenameTemplate,
    );
  }

  @override
  void dispose() {
    _downloadRootCtrl.dispose();
    _downloadTemplateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionDir,
          children: [
            SettingPathFieldCard(
              icon: Icons.folder_outlined,
              ctrl: _downloadRootCtrl,
              hint: l10n.settingsDownloadRootHint,
              save: (v) => _saveDownloadRoot(v, l10n),
              restoreDefault: defaultDownloadRoot,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionFilename,
          note: l10n.settingsDownloadTemplateNote,
          children: [
            SettingPathFieldCard(
              icon: Icons.text_fields_outlined,
              ctrl: _downloadTemplateCtrl,
              hint: l10n.settingsDownloadTemplateHint,
              save: (v) => _saveDownloadTemplate(v, l10n),
              restoreDefault: () => '{artist} - {title}',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionQuality,
          note: l10n.settingsDownloadQualityNote,
          children: [
            SettingTile(
              icon: Icons.high_quality_outlined,
              title: l10n.settingsDownloadQuality,
              subtitle: l10n.settingsDownloadQualityDesc(
                l10nQualityLabel(l10n, prefs.downloadQuality),
              ),
              trailing: SSegmented<String>(
                options: [
                  for (final q in downloadQualityLevels)
                    SSegmentedOption(q, l10nQualityLabel(l10n, q)),
                ],
                selected: prefs.downloadQuality,
                onChanged: (q) =>
                    ref.read(appPrefsProvider.notifier).setDownload(quality: q),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionConcurrent,
          children: [
            SettingSliderTile(
              icon: Icons.speed_outlined,
              title: l10n.settingsDownloadConcurrent,
              subtitle: l10n.settingsDownloadConcurrentDesc(
                prefs.downloadMaxConcurrent,
              ),
              value:
                  _downloadConcurrentDraft ??
                  prefs.downloadMaxConcurrent.toDouble(),
              min: 1,
              max: 5,
              divisions: 4,
              label:
                  '${(_downloadConcurrentDraft ?? prefs.downloadMaxConcurrent.toDouble()).round()}',
              width: 160,
              onChanged: (v) => setState(() => _downloadConcurrentDraft = v),
              onChangeEnd: (v) {
                setState(() => _downloadConcurrentDraft = null);
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(maxConcurrent: v.round());
              },
            ),
            SettingTile(
              icon: Icons.folder_copy_outlined,
              title: l10n.settingsDownloadGrouping,
              subtitle: switch (prefs.downloadSubdirStrategy) {
                0 => l10n.settingsGroupingFlat,
                1 => l10n.settingsGroupingPlatform,
                _ => l10n.settingsGroupingArtist,
              },
              trailing: SSegmented<int>(
                options: [
                  SSegmentedOption(0, l10n.settingsGroupingFlatLabel),
                  SSegmentedOption(1, l10n.settingsGroupingPlatformLabel),
                  SSegmentedOption(2, l10n.settingsGroupingArtistLabel),
                ],
                selected: prefs.downloadSubdirStrategy,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(subdirStrategy: v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionSpeedLimit,
          note: l10n.settingsSpeedNote,
          children: [
            SettingSliderTile(
              icon: Icons.speed_outlined,
              title: l10n.settingsDownloadSpeedLimit,
              subtitle: prefs.downloadSpeedLimit <= 0
                  ? l10n.settingsSpeedUnlimited
                  : l10n.settingsSpeedLimited(
                      _fmtSpeedLabel(prefs.downloadSpeedLimit, l10n),
                    ),
              value:
                  _downloadSpeedDraft ??
                  (prefs.downloadSpeedLimit / (1024 * 1024)).toDouble(),
              min: 0,
              max: 20,
              divisions: 40,
              label: _downloadSpeedDraft != null && _downloadSpeedDraft! <= 0
                  ? l10n.settingsSpeedUnlimitedLabel
                  : l10n.settingsSpeedMbps(
                      ((_downloadSpeedDraft ??
                              prefs.downloadSpeedLimit / (1024 * 1024)))
                          .toStringAsFixed(1),
                    ),
              width: 160,
              onChanged: (v) => setState(() => _downloadSpeedDraft = v),
              onChangeEnd: (v) {
                setState(() => _downloadSpeedDraft = null);
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(speedLimit: (v * 1024 * 1024).round());
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionHistory,
          note: l10n.settingsDownloadHistoryNote,
          children: [
            SettingSliderTile(
              icon: Icons.history_outlined,
              title: l10n.settingsDownloadHistoryLimit,
              subtitle: l10n.settingsDownloadHistoryDesc(
                prefs.downloadHistoryLimit,
              ),
              value:
                  _downloadHistoryLimitDraft ??
                  prefs.downloadHistoryLimit.toDouble(),
              min: 10,
              max: 500,
              divisions: 49,
              label: l10n.settingsDownloadHistoryCount(
                (_downloadHistoryLimitDraft ??
                        prefs.downloadHistoryLimit.toDouble())
                    .round(),
              ),
              width: 160,
              onChanged: (v) => setState(() => _downloadHistoryLimitDraft = v),
              onChangeEnd: (v) {
                setState(() => _downloadHistoryLimitDraft = null);
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(historyLimit: v.round());
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionFingerprint,
          note: l10n.settingsFingerprintNote,
          children: [
            SettingSwitchTile(
              icon: Icons.published_with_changes_outlined,
              title: l10n.settingsDownloadDynamicFingerprint,
              subtitle: l10n.settingsDownloadDynamicFingerprintDesc,
              value: prefs.downloadDynamicFingerprint,
              onChanged: (v) {
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownloadDynamicFingerprint(v);
                // 立即重注入/清除 Rust 侧指纹（开关切换即时生效，
                // 不必等下次引擎重建/重启）
                ref.read(downloadControllerProvider.notifier).syncSessions();
              },
            ),
            SettingTile(
              icon: Icons.fingerprint_outlined,
              title: l10n.settingsResetFingerprint,
              subtitle: l10n.settingsResetFingerprintDesc,
              trailing: IconButton(
                tooltip: l10n.settingsResetFingerprint,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_outlined),
                // 动态指纹开启时指纹不持久化，「重置」无意义 → 禁用
                onPressed: prefs.downloadDynamicFingerprint
                    ? null
                    : () => _resetFingerprint(context, l10n),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SettingNote(text: l10n.settingsGroupingNote),
      ],
    );
  }

  /// 重置设备指纹：重新生成并持久化，随后立即重注入 Rust（即时生效）。
  Future<void> _resetFingerprint(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsResetFingerprint,
      description: l10n.settingsResetFingerprintDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsResetFingerprint,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    ref
        .read(appPrefsProvider.notifier)
        .setDownloaderIdentity(jsonEncode(generateDownloaderIdentity()));
    ref.read(downloadControllerProvider.notifier).syncSessions();
    toast(l10n.toastFingerprintReset, type: ToastType.success);
  }

  void _saveDownloadRoot(String raw, AppLocalizations l10n) {
    final path = raw.trim();
    if (path.isEmpty) {
      toast(l10n.toastDownloadRootEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(rootDir: path);
    if (!mounted) return;
    toast(l10n.toastDownloadRootUpdated);
  }

  void _saveDownloadTemplate(String raw, AppLocalizations l10n) {
    final template = raw.trim();
    if (template.isEmpty) {
      toast(l10n.toastTemplateEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(filenameTemplate: template);
    if (!mounted) return;
    toast(l10n.toastTemplateUpdated);
  }

  String _fmtSpeedLabel(int bytesPerSec, AppLocalizations l10n) {
    if (bytesPerSec < 1024) return l10n.settingsSpeedBs(bytesPerSec);
    final kb = bytesPerSec / 1024;
    if (kb < 1024) return l10n.settingsSpeedKbs(kb.toStringAsFixed(0));
    return l10n.settingsSpeedMbs((kb / 1024).toStringAsFixed(1));
  }
}

// ── 刮削 ──────────────────────────────────────────────────────────────

/// 刮削分类：目录（留空跟随媒体库扫描目录）+ 数据源开关 + 进度统计 +
/// 立即刮削/取消。
class ScrapeSection extends ConsumerStatefulWidget {
  const ScrapeSection({super.key});

  @override
  ConsumerState<ScrapeSection> createState() => _ScrapeSectionState();
}

class _ScrapeSectionState extends ConsumerState<ScrapeSection> {
  late final TextEditingController _scrapeDirsCtrl;

  @override
  void initState() {
    super.initState();
    _scrapeDirsCtrl = TextEditingController(
      text: ref.read(appPrefsProvider).scrapeDirs.join('\n'),
    );
  }

  @override
  void dispose() {
    _scrapeDirsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    final scrape = ref.watch(scrapeControllerProvider);
    final scraper = ref.read(scrapeControllerProvider.notifier);
    final dirs = prefs.scrapeDirs.isNotEmpty ? prefs.scrapeDirs : scanDirs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionScrapeDirs,
          note: dirs.isEmpty
              ? l10n.settingsScrapeDirsEmptyNote
              : l10n.settingsScrapeDirsNote(dirs.join(' ; ')),
          children: [
            SettingPathFieldCard(
              icon: Icons.folder_outlined,
              ctrl: _scrapeDirsCtrl,
              hint: l10n.settingsScrapeDirsHint,
              save: (v) => _saveScrapeDirs(v, l10n),
              restoreDefault: () => '',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScrapeSources,
          children: [
            SettingSwitchTile(
              icon: Icons.public,
              title: l10n.settingsScrapeSourceMusicBrainz,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseMusicBrainz,
              onChanged: (v) => notifier.setScrape(useMusicBrainz: v),
            ),
            SettingSwitchTile(
              icon: Icons.queue_music,
              title: l10n.settingsScrapeSourceDeezer,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseDeezer,
              onChanged: (v) => notifier.setScrape(useDeezer: v),
            ),
            SettingSwitchTile(
              icon: Icons.storefront_outlined,
              title: l10n.settingsScrapeSourceItunes,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseItunes,
              onChanged: (v) => notifier.setScrape(useItunes: v),
            ),
            SettingSwitchTile(
              icon: Icons.music_note_outlined,
              title: l10n.settingsScrapeSourceNetease,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseNetease,
              onChanged: (v) => notifier.setScrape(useNetease: v),
            ),
            SettingSwitchTile(
              icon: Icons.library_music_outlined,
              title: l10n.settingsScrapeSourceQQMusic,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseQQMusic,
              onChanged: (v) => notifier.setScrape(useQQMusic: v),
            ),
            SettingSwitchTile(
              icon: Icons.headphones_outlined,
              title: l10n.settingsScrapeSourceKugou,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseKugou,
              onChanged: (v) => notifier.setScrape(useKugou: v),
            ),
            SettingSwitchTile(
              icon: Icons.graphic_eq_outlined,
              title: l10n.settingsScrapeSourceKuwo,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseKuwo,
              onChanged: (v) => notifier.setScrape(useKuwo: v),
            ),
            SettingSwitchTile(
              icon: Icons.mobile_screen_share_outlined,
              title: l10n.settingsScrapeSourceMigu,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseMigu,
              onChanged: (v) => notifier.setScrape(useMigu: v),
            ),
            SettingSwitchTile(
              icon: Icons.fingerprint,
              title: l10n.settingsScrapeSourceAcoustID,
              subtitle: l10n.settingsScrapeSourceDesc,
              value: prefs.scrapeUseAcoustID,
              onChanged: (v) => notifier.setScrape(useAcoustID: v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScrapeProgress,
          children: [
            _buildScrapeStatus(scheme, l10n, scrape, dirs.isNotEmpty),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: scrape.scraping
                  ? SButton(
                      label: l10n.settingsScrapeCancel,
                      icon: Icons.stop,
                      variant: SButtonVariant.error,
                      onPressed: scraper.cancel,
                    )
                  : SButton(
                      label: l10n.settingsScrapeStart,
                      icon: Icons.auto_fix_high,
                      variant: SButtonVariant.primary,
                      onPressed: _startScrape,
                    ),
            ),
          ],
        ),
      ],
    );
  }

  /// 刮削进度/结果统计区（运行中 → 进度条 + 当前文件；空闲 → 上次结果）。
  Widget _buildScrapeStatus(
    ColorScheme scheme,
    AppLocalizations l10n,
    ScrapeState scrape,
    bool dirsReady,
  ) {
    if (scrape.scraping) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (scrape.percent != null) ...[
              LinearProgressIndicator(
                value: scrape.percent,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              scrape.current.isEmpty
                  ? l10n.settingsScrapeScanning
                  : l10n.settingsScrapeCurrent(scrape.current),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _statChip(
                  scheme,
                  scheme.primary,
                  l10n.settingsScrapeSuccess,
                  scrape.success,
                ),
                _statChip(
                  scheme,
                  scheme.error,
                  l10n.settingsScrapeFailed,
                  scrape.failed,
                ),
                _statChip(
                  scheme,
                  scheme.onSurfaceVariant,
                  l10n.settingsScrapeSkipped,
                  scrape.skipped,
                ),
                _statChip(
                  scheme,
                  scheme.tertiary,
                  l10n.settingsScrapeNotFound,
                  scrape.notFound,
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (scrape.hasActivity) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scrape.error != null
                  ? scrape.error!
                  : scrape.canceled
                  ? l10n.settingsScrapeCanceled
                  : l10n.settingsScrapeDone,
              style: TextStyle(
                fontSize: 12.5,
                color: scrape.error != null
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _statChip(
                  scheme,
                  scheme.primary,
                  l10n.settingsScrapeSuccess,
                  scrape.success,
                ),
                _statChip(
                  scheme,
                  scheme.error,
                  l10n.settingsScrapeFailed,
                  scrape.failed,
                ),
                _statChip(
                  scheme,
                  scheme.onSurfaceVariant,
                  l10n.settingsScrapeSkipped,
                  scrape.skipped,
                ),
                _statChip(
                  scheme,
                  scheme.tertiary,
                  l10n.settingsScrapeNotFound,
                  scrape.notFound,
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Text(
        dirsReady ? l10n.settingsScrapeIdle : l10n.settingsScrapeNoDirs,
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _statChip(ColorScheme scheme, Color color, String label, int value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          '$label $value',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  void _startScrape() {
    final l10n = context.l10n;
    final prefs = ref.read(appPrefsProvider);
    var dirs = prefs.scrapeDirs;
    if (dirs.isEmpty) dirs = scanDirs();
    if (dirs.isEmpty) {
      toast(l10n.toastScrapeNoDirs);
      return;
    }
    ref
        .read(scrapeControllerProvider.notifier)
        .start(
          dirs: dirs,
          dbPath: '${resolveDataDir()}/scraper-state.db',
          sources: ScrapeSources(
            musicBrainz: prefs.scrapeUseMusicBrainz,
            deezer: prefs.scrapeUseDeezer,
            itunes: prefs.scrapeUseItunes,
            netease: prefs.scrapeUseNetease,
            qqMusic: prefs.scrapeUseQQMusic,
            kugou: prefs.scrapeUseKugou,
            kuwo: prefs.scrapeUseKuwo,
            migu: prefs.scrapeUseMigu,
            acoustId: prefs.scrapeUseAcoustID,
          ),
        );
  }

  void _saveScrapeDirs(String raw, AppLocalizations l10n) {
    final dirs = raw
        .split('\n')
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList();
    ref.read(appPrefsProvider.notifier).setScrape(dirs: dirs);
    if (!mounted) return;
    toast(l10n.toastScrapeDirsUpdated);
  }
}

// ── 存储 ──────────────────────────────────────────────────────────────

/// 存储分类：数据目录 / 曲库数据库 / 用户数据库路径展示与复制。
class StorageSection extends ConsumerStatefulWidget {
  const StorageSection({super.key});

  @override
  ConsumerState<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<StorageSection> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dataDir = resolveDataDir();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionFileLocation,
          children: [
            SettingTile(
              icon: Icons.folder_outlined,
              title: l10n.settingsDataDir,
              subtitle: dataDir,
              trailing: SettingCopyButton(
                value: dataDir,
                label: l10n.settingsDataDir,
              ),
            ),
            SettingTile(
              icon: Icons.album_outlined,
              title: l10n.settingsLibraryDb,
              subtitle: '$dataDir/database/library.db',
              trailing: SettingCopyButton(
                value: '$dataDir/database/library.db',
                label: l10n.settingsLibraryDbLabel,
              ),
            ),
            SettingTile(
              icon: Icons.key_outlined,
              title: l10n.settingsUserDb,
              subtitle: '$dataDir/database/user.db',
              trailing: SettingCopyButton(
                value: '$dataDir/database/user.db',
                label: l10n.settingsUserDbLabel,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── 关于 ──────────────────────────────────────────────────────────────

/// 关于分类：版本（长按 10 秒开启开发者模式）+ 引擎/服务端说明 +
/// 字体声明 + 免责声明。
///
/// 开发者长按逻辑（Timer/Stopwatch 计时与分类切换）由设置弹窗主 state
/// 持有，本组件通过回调接入并按需展示按住进度。
class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({
    super.key,
    required this.version,
    required this.devHolding,
    required this.devHoldProgress,
    required this.onDevHoldStart,
    required this.onDevHoldCancel,
  });

  final String version;
  final bool devHolding;
  final double devHoldProgress;
  final VoidCallback onDevHoldStart;
  final VoidCallback onDevHoldCancel;

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.appName,
          note: l10n.settingsAboutDesc,
          children: [
            // 长按「版本」10 秒开启开发者模式（隐藏下载接口的入口）。
            // Listener 对鼠标按住 / 触摸长按通用；悬浮弹提示 + 进度条反馈。
            Listener(
              onPointerDown: (_) => widget.onDevHoldStart(),
              onPointerUp: (_) => widget.onDevHoldCancel(),
              onPointerCancel: (_) => widget.onDevHoldCancel(),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Tooltip(
                  message: l10n.settingsDeveloperHoldHint,
                  waitDuration: const Duration(seconds: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SettingTile(
                        icon: Icons.music_note_outlined,
                        title: l10n.settingsVersion,
                        subtitle: widget.version.isEmpty
                            ? l10n.settingsVersionUnknown
                            : l10n.settingsVersionFormat(widget.version),
                        trailing: const SizedBox.shrink(),
                      ),
                      if (widget.devHolding)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: widget.devHoldProgress,
                              minHeight: 3,
                              backgroundColor: scheme.primary.withValues(
                                alpha: 0.12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SettingTile(
              icon: Icons.memory_outlined,
              title: l10n.settingsAudioEngine,
              subtitle: l10n.settingsAudioEngineDesc,
              trailing: const SizedBox.shrink(),
            ),
            SettingTile(
              icon: Icons.dns_outlined,
              title: l10n.settingsSubsonicServer,
              subtitle: l10n.settingsSubsonicDesc,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingSection(
          title: l10n.settingsSectionFontCredits,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                l10n.settingsFontCreditsText,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingSection(
          title: l10n.settingsSectionDeclaration,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                  children: [
                    TextSpan(text: l10n.settingsDeclineText),
                    _dense(
                      l10n.settingsDecline1Title,
                      l10n.settingsDecline1Body,
                    ),
                    _dense(
                      l10n.settingsDecline2Title,
                      l10n.settingsDecline2Body,
                    ),
                    _dense(
                      l10n.settingsDecline3Title,
                      l10n.settingsDecline3Body,
                    ),
                    _dense(
                      l10n.settingsDecline4Title,
                      l10n.settingsDecline4Body,
                    ),
                    _dense(
                      l10n.settingsDecline5Title,
                      l10n.settingsDecline5Body,
                    ),
                    TextSpan(text: l10n.settingsDeclineFooter),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  TextSpan _dense(String title, String body) {
    return TextSpan(
      children: [
        TextSpan(
          text: title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: body),
      ],
    );
  }
}

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

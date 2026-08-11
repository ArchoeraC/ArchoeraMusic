/// ArchoeraMusic 独立设计体系（对齐 SPlayer-Next 的自定义主题思路，
/// 但采用本项目的独立色板，不做 Google Material 原生观感）。
///
/// 设计语言：
///  - 深色为主基调（近黑偏蓝），surface 多层微差层级；
///  - 主色亮蓝 `primary`，次色紫蓝 `secondary`；
///  - 全局统一圆角（控件 10 / 卡片 12 / 弹窗 16）、细滚动条、
///    填充式无边框输入框、悬浮式圆角按钮。
library;

import 'package:flutter/material.dart';

/// 应用调色板（单一来源）。
class AppPalette {
  const AppPalette({
    required this.surface,
    required this.surfaceAlt,
    required this.surfacePanel,
    required this.surfaceBright,
    required this.field,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
  });

  final Color surface; // 应用主背景
  final Color surfaceAlt; // 次级背景（侧边栏等）
  final Color surfacePanel; // 面板/卡片
  final Color surfaceBright; // 悬浮/亮面板（按钮 secondary）
  final Color field; // 输入框填充
  final Color onSurface; // 主前景
  final Color onSurfaceVariant; // 次级前景
  final Color outline; // 分隔线/描边
  final Color primary; // 主色（亮蓝）
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondary; // 次色（紫蓝）
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;

  /// 暗色（默认主题）。
  static const dark = AppPalette(
    surface: Color(0xFF0E1117),
    surfaceAlt: Color(0xFF141824),
    surfacePanel: Color(0xFF1A1F2E),
    surfaceBright: Color(0xFF232A3D),
    field: Color(0xFF1D2333),
    onSurface: Color(0xFFE8EAF2),
    onSurfaceVariant: Color(0xFF9AA1B5),
    outline: Color(0xFF3A4155),
    primary: Color(0xFF4DA3FF),
    onPrimary: Color(0xFF0A1420),
    primaryContainer: Color(0xFF1A3A5E),
    onPrimaryContainer: Color(0xFFC9E2FF),
    secondary: Color(0xFF9B8CFF),
    onSecondary: Color(0xFF151028),
    secondaryContainer: Color(0xFF332E52),
    onSecondaryContainer: Color(0xFFE0DBFF),
    error: Color(0xFFFF6B61),
    onError: Color(0xFF2A0806),
    errorContainer: Color(0xFF5C211D),
    onErrorContainer: Color(0xFFFFDAD6),
  );

  /// 亮色（浅色主题）。
  static const light = AppPalette(
    surface: Color(0xFFF5F6FA),
    surfaceAlt: Color(0xFFEDEFF6),
    surfacePanel: Color(0xFFFFFFFF),
    surfaceBright: Color(0xFFFFFFFF),
    field: Color(0xFFEDF0F7),
    onSurface: Color(0xFF1A1D26),
    onSurfaceVariant: Color(0xFF5B6273),
    outline: Color(0xFFD2D7E4),
    primary: Color(0xFF2E7CF6),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFD8E7FF),
    onPrimaryContainer: Color(0xFF0A2E63),
    secondary: Color(0xFF6C5CE7),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE4E0FF),
    onSecondaryContainer: Color(0xFF1E1650),
    error: Color(0xFFD94438),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
  );
}

/// 全局圆角规范。
abstract final class AppRadius {
  static const control = 10.0;
  static const card = 12.0;
  static const dialog = 16.0;
  static const pill = 100.0;
}

/// 应用扩展色：暴露不受图片背景样式影响的常驻 UI 底色。
@immutable
class AppChromeColors extends ThemeExtension<AppChromeColors> {
  const AppChromeColors({
    required this.playerBarBackground,
    required this.playerBackground,
  });

  /// 播放条背景
  final Color playerBarBackground;

  /// 全屏播放器背景（实底，图片风格下也不半透明/毛玻璃）
  final Color playerBackground;

  @override
  AppChromeColors copyWith({
    Color? playerBarBackground,
    Color? playerBackground,
  }) => AppChromeColors(
    playerBarBackground: playerBarBackground ?? this.playerBarBackground,
    playerBackground: playerBackground ?? this.playerBackground,
  );

  @override
  AppChromeColors lerp(AppChromeColors? other, double t) {
    if (other == null) return this;
    return AppChromeColors(
      playerBarBackground: Color.lerp(
        playerBarBackground,
        other.playerBarBackground,
        t,
      )!,
      playerBackground: Color.lerp(
        playerBackground,
        other.playerBackground,
        t,
      )!,
    );
  }
}

/// CJK 字体回退链。
///
/// 主字体为内置 Noto Sans SC（Google 开源，字形度量最标准）；回退链
/// 优先内置 MiSans 与系统 Noto CJK SC 同族，其余为跨平台系统中文无衬线
/// 体兜底，避免混排时的基线/字高错位。
const List<String> _cjkFontFallback = [
  'MiSans',
  'Noto Sans CJK SC',
  'HarmonyOS Sans SC',
  'PingFang SC',
  'Microsoft YaHei',
  'WenQuanYi Micro Hei',
  'sans-serif',
];

/// 主题工厂：由 [AppPalette] 构建 [ThemeData]。
///
/// [accentSeed] 自定义主色种子（设置「主题色来源」custom/cover）：非空时
/// primary/secondary 家族由 `ColorScheme.fromSeed` 按该种子动态生成（对齐原版
/// generatePalette）；空则使用设计体系固定亮蓝。
/// [solid] 纯色中性色板（主题色来源=solid）：主/次色用灰阶，界面不随主题色
/// （对齐原版 SOLID_PALETTE_DARK/LIGHT）。
/// [globalTint] 全局着色：surface 家族向主色轻微偏移（对齐原版 globalTint）。
/// [imageBackground] 图片背景风格（appearanceStyle=image）：surface 家族半透明化，
/// 让底层背景图透出且内容可读（对齐原版 global.css data-appearance-style=image 规则：
/// 常规内容 22%、悬浮层 55%；可读性由 AppBackground 的 dim 遮罩保证，弹窗保持实底）。
/// [fontFamily] 界面字体（设置「界面字体」，默认内置 MiSans）。
/// [performanceMode] 性能模式：InkWell 点击水波纹/高亮改透明（NoSplash），
/// 与 MediaQuery.disableAnimations 一起实现全局无动效。
ThemeData buildAppTheme(
  AppPalette c,
  Brightness brightness, {
  Color? accentSeed,
  String fontFamily = 'MiSans',
  bool globalTint = false,
  bool solid = false,
  bool imageBackground = false,
  bool performanceMode = false,
}) {
  final dark = brightness == Brightness.dark;
  final custom = accentSeed != null;

  // 主/次色家族：solid 用中性灰阶（对齐 SOLID_PALETTE）；否则按种子生成
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  if (solid) {
    primary = dark ? const Color(0xFFE4E6EC) : const Color(0xFF2A2D35);
    onPrimary = dark ? const Color(0xFF101318) : const Color(0xFFFFFFFF);
    primaryContainer = dark ? const Color(0xFF2A2F3A) : const Color(0xFFE4E6EC);
    onPrimaryContainer = dark
        ? const Color(0xFFD6DAE3)
        : const Color(0xFF23262E);
    secondary = dark ? const Color(0xFF9AA1B5) : const Color(0xFF5B6273);
    onSecondary = dark ? const Color(0xFF101318) : const Color(0xFFFFFFFF);
    secondaryContainer = dark
        ? const Color(0xFF2A2F3A)
        : const Color(0xFFEDEFF6);
    onSecondaryContainer = dark
        ? const Color(0xFFD6DAE3)
        : const Color(0xFF23262E);
  } else {
    final generated = ColorScheme.fromSeed(
      seedColor: accentSeed ?? c.primary,
      brightness: brightness,
    );
    primary = custom ? generated.primary : c.primary;
    onPrimary = custom ? generated.onPrimary : c.onPrimary;
    primaryContainer = custom ? generated.primaryContainer : c.primaryContainer;
    onPrimaryContainer = custom
        ? generated.onPrimaryContainer
        : c.onPrimaryContainer;
    secondary = custom ? generated.secondary : c.secondary;
    onSecondary = custom ? generated.onSecondary : c.onSecondary;
    secondaryContainer = custom
        ? generated.secondaryContainer
        : c.secondaryContainer;
    onSecondaryContainer = custom
        ? generated.onSecondaryContainer
        : c.onSecondaryContainer;
  }

  // 全局着色：surface 家族向主色轻微偏移（6%，克制不喧宾夺主）
  final tint = globalTint && accentSeed != null;
  Color tinted(Color base) => tint ? Color.lerp(base, accentSeed, 0.06)! : base;

  // 图片背景模式：surface 家族半透明化让背景图透出（弹窗/卡片实底用下方 c.* 原始色）。
  final Color surface;
  final Color surfaceAlt;
  final Color surfacePanel;
  final Color surfaceBright;
  final Color field;
  if (imageBackground) {
    final scrim = c.surfaceBright.withValues(alpha: 0.22);
    surface = scrim;
    surfaceAlt = scrim;
    surfacePanel = scrim;
    surfaceBright = c.surfaceBright.withValues(alpha: 0.55);
    field = scrim;
  } else {
    surface = tinted(c.surface);
    surfaceAlt = tinted(c.surfaceAlt);
    surfacePanel = tinted(c.surfacePanel);
    surfaceBright = tinted(c.surfaceBright);
    field = tinted(c.field);
  }

  final scheme =
      ColorScheme.fromSeed(
        seedColor: c.primary,
        brightness: brightness,
      ).copyWith(
        primary: primary,
        onPrimary: onPrimary,
        primaryContainer: primaryContainer,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondary,
        onSecondary: onSecondary,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        error: c.error,
        onError: c.onError,
        errorContainer: c.errorContainer,
        onErrorContainer: c.onErrorContainer,
        surface: surface,
        onSurface: c.onSurface,
        onSurfaceVariant: c.onSurfaceVariant,
        outline: c.outline,
        outlineVariant: c.outline.withValues(alpha: 0.55),
        surfaceContainerLowest: surface,
        surfaceContainerLow: surfaceAlt,
        surfaceContainer: surfacePanel,
        surfaceContainerHigh: surfacePanel,
        surfaceContainerHighest: surfaceBright,
        surfaceTint: Colors.transparent,
      );

  // 播放条底色：图片背景风格下恢复毛玻璃——0.7 高不透明 + 外层 BackdropFilter
  // 模糊（对齐原版 global.css footer 播放栏：surface-bright/0.7 + blur16）；
  // 纯色风格恒为面板实底（tinted 跟随全局着色），不做半透明
  final playerBarBg = imageBackground
      ? c.surfaceBright.withValues(alpha: 0.7)
      : tinted(c.surfacePanel);
  // 全屏播放器背景：恒为面板实底，不随 image 风格半透明化（对齐原版
  // FullPlayer 独立背景体系——播放界面不跟随全局图片背景设定）
  final playerBg = tinted(c.surfacePanel);
  final chromeColors = AppChromeColors(
    playerBarBackground: playerBarBg,
    playerBackground: playerBg,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    // 界面字体（内置 MiSans 默认 / HarmonyOS Sans SC 可选）+ CJK 回退链，
    // 统一中英混排度量（消除字体错位）
    fontFamily: fontFamily,
    fontFamilyFallback: _cjkFontFallback,
    extensions: [chromeColors],
  );

  final inputFill = dark ? field : surfaceAlt;

  return base.copyWith(
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    // 性能模式：点击水波纹/高亮改透明（NoSplash + 透明 highlight），
    // 全局消除 InkWell/IconButton/ListTile 的按下动效
    splashFactory: performanceMode ? NoSplash.splashFactory : null,
    highlightColor: performanceMode ? Colors.transparent : null,
    // 文本统一前景色 + 回退字体链 + 行内 leading 均匀分布
    //
    // leadingDistribution=even：中文字体 ascent 通常大于 descent，
    // proportional 会把额外行高按比例堆在文字上方，造成文字视觉偏上
    // （固定高度容器中看似未垂直居中）；even 令行框上下留白相等，
    // 字形视觉中心与容器中心一致。全局覆盖所有 textTheme 样式。
    textTheme: _applyEvenLeading(
      base.textTheme.apply(
        bodyColor: c.onSurface,
        displayColor: c.onSurface,
        fontFamilyFallback: _cjkFontFallback,
      ),
    ),
    // 分隔线
    dividerColor: c.outline.withValues(alpha: 0.6),
    dividerTheme: DividerThemeData(
      color: c.outline.withValues(alpha: 0.6),
      thickness: 1,
      space: 1,
    ),
    // 卡片
    cardTheme: CardThemeData(
      color: c.surfacePanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    // 图标按钮（统一圆角）
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ),
        foregroundColor: WidgetStatePropertyAll(c.onSurface),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? c.onSurface.withValues(alpha: 0.08)
              : c.onSurface.withValues(alpha: 0.06),
        ),
      ),
    ),
    // 输入框：填充、无边框、圆角
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      hintStyle: TextStyle(
        color: c.onSurfaceVariant.withValues(alpha: 0.7),
        fontSize: 13,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(
          color: scheme.primary.withValues(alpha: 0.7),
          width: 1.2,
        ),
      ),
    ),
    // 对话框
    dialogTheme: DialogThemeData(
      // Flutter 3.44+ 中 DialogThemeData 默认 insetPadding 为 EdgeInsets.zero，
      // 未显式设置 insetPadding 的 Dialog/AlertDialog 会直接铺满窗口；
      // 全局兜底为 48，与 SDialog 等显式设置保持一致。
      insetPadding: const EdgeInsets.all(48),
      backgroundColor: c.surfacePanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
        side: BorderSide(color: c.outline.withValues(alpha: 0.5)),
      ),
      titleTextStyle: TextStyle(
        color: c.onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    // 细滚动条
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      thumbColor: WidgetStatePropertyAll(
        c.onSurface.withValues(
          alpha: brightness == Brightness.dark ? 0.22 : 0.28,
        ),
      ),
      thumbVisibility: const WidgetStatePropertyAll(true),
      radius: const Radius.circular(3),
    ),
    // 工具提示
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.surfaceBright,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      textStyle: TextStyle(color: c.onSurface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),
    // 弹出菜单
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfacePanel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.outline.withValues(alpha: 0.5)),
      ),
      textStyle: TextStyle(color: c.onSurface, fontSize: 13),
    ),
    // 页面转场：淡入 + 轻微上移
    // 覆盖全部平台，含 /player 之外的嵌套路由 push）
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final p in TargetPlatform.values)
          p: const _FadeSlidePageTransitionsBuilder(),
      },
    ),
    // 滑块（播放进度条；颜色跟随主题主色——自定义/系统主题色时同步变化）
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: c.onSurface.withValues(alpha: 0.12),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.15),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    ),
    // 进度条
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: c.onSurface.withValues(alpha: 0.1),
    ),
  );
}

/// 行内 leading 均匀分布（修复中文字体视觉偏上；见 buildAppTheme 注释）。
TextTheme _applyEvenLeading(TextTheme t) {
  TextStyle? even(TextStyle? s) =>
      s?.copyWith(leadingDistribution: TextLeadingDistribution.even);
  return t.copyWith(
    displayLarge: even(t.displayLarge),
    displayMedium: even(t.displayMedium),
    displaySmall: even(t.displaySmall),
    headlineLarge: even(t.headlineLarge),
    headlineMedium: even(t.headlineMedium),
    headlineSmall: even(t.headlineSmall),
    titleLarge: even(t.titleLarge),
    titleMedium: even(t.titleMedium),
    titleSmall: even(t.titleSmall),
    bodyLarge: even(t.bodyLarge),
    bodyMedium: even(t.bodyMedium),
    bodySmall: even(t.bodySmall),
    labelLarge: even(t.labelLarge),
    labelMedium: even(t.labelMedium),
    labelSmall: even(t.labelSmall),
  );
}

/// 页面转场：淡入 + 轻微上移（对齐原版 route-fade；首路由不转场）。
class _FadeSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlidePageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst) return child;
    // 性能模式（MediaQuery.disableAnimations）：页面转场直切，无淡入上移
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

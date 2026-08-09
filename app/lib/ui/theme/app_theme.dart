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
/// [accentSeed] 自定义主色种子（设置「主题色」）：非空时 primary/secondary
/// 家族由 `ColorScheme.fromSeed` 按该种子动态生成（对齐原版
/// appearance.themeSource=custom）；空则使用设计体系固定亮蓝。
/// [fontFamily] 界面字体（设置「界面字体」，默认内置 MiSans）。
ThemeData buildAppTheme(AppPalette c, Brightness brightness,
    {Color? accentSeed, String fontFamily = 'MiSans'}) {
  final custom = accentSeed != null;
  final generated = ColorScheme.fromSeed(
    seedColor: accentSeed ?? c.primary,
    brightness: brightness,
  );
  final scheme = ColorScheme.fromSeed(
    seedColor: c.primary,
    brightness: brightness,
  ).copyWith(
    primary: custom ? generated.primary : c.primary,
    onPrimary: custom ? generated.onPrimary : c.onPrimary,
    primaryContainer: custom ? generated.primaryContainer : c.primaryContainer,
    onPrimaryContainer:
        custom ? generated.onPrimaryContainer : c.onPrimaryContainer,
    secondary: custom ? generated.secondary : c.secondary,
    onSecondary: custom ? generated.onSecondary : c.onSecondary,
    secondaryContainer:
        custom ? generated.secondaryContainer : c.secondaryContainer,
    onSecondaryContainer:
        custom ? generated.onSecondaryContainer : c.onSecondaryContainer,
    error: c.error,
    onError: c.onError,
    errorContainer: c.errorContainer,
    onErrorContainer: c.onErrorContainer,
    surface: c.surface,
    onSurface: c.onSurface,
    onSurfaceVariant: c.onSurfaceVariant,
    outline: c.outline,
    outlineVariant: c.outline.withValues(alpha: 0.55),
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surfaceAlt,
    surfaceContainer: c.surfacePanel,
    surfaceContainerHigh: c.surfacePanel,
    surfaceContainerHighest: c.surfaceBright,
    surfaceTint: Colors.transparent,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    // 界面字体（内置 MiSans 默认 / HarmonyOS Sans SC 可选）+ CJK 回退链，
    // 统一中英混排度量（消除字体错位）
    fontFamily: fontFamily,
    fontFamilyFallback: _cjkFontFallback,
  );

  final inputFill = brightness == Brightness.dark ? c.field : c.surfaceAlt;

  return base.copyWith(
    scaffoldBackgroundColor: c.surface,
    canvasColor: c.surface,
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
    ),
    // 图标按钮（统一圆角）
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.control)),
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
      hintStyle: TextStyle(color: c.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 13),
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
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7), width: 1.2),
      ),
    ),
    // 对话框
    dialogTheme: DialogThemeData(
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
        c.onSurface.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.28),
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
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2)),
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
    // 页面转场：淡入 + 轻微上移（对齐原版 route-fade 的柔和感；
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
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position:
            Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero)
                .animate(curved),
        child: child,
      ),
    );
  }
}

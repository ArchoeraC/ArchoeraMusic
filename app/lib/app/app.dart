import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../l10n/l10n.dart';
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../theme/app_theme.dart';
import '../theme/cover_color.dart';
import '../widgets/common/app_shortcuts.dart';
import '../widgets/common/toast.dart';
import 'bootstrap.dart';
import 'router.dart';
import 'theme_provider.dart';

/// ArchoeraMusic 应用根：主题 + 路由 + 启动门。
///
/// 主题逻辑在 theme_provider.dart，路由在 router.dart，启动初始化
/// （登录态恢复 / Splash 过渡）在 bootstrap.dart——本文件只负责组装。
class ArchoeraMusicApp extends ConsumerWidget {
  const ArchoeraMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final prefs = ref.watch(appPrefsProvider);
    final locale = ref.watch(localeProvider);
    // 主色种子（对齐原版 theme.ts generatePalette + trackedColorForCover）：
    // custom → 自定义主色；cover → 当前播放封面提取；default → 跟随系统主题色
    // （读取失败回退默认亮蓝）；solid → 无种子（中性灰阶）。
    final coverAccent = ref.watch(coverColorProvider);
    final systemAccent = ref.watch(systemAccentProvider).value;
    final accent = switch (prefs.themeSource) {
      'custom' => prefs.accentColor,
      'cover' => coverAccent,
      'default' => systemAccent,
      _ => null,
    };
    // 图片背景风格（有效时）强制暗色 + 全局着色（对齐原版 effectiveStyle/isDark/
    // effectiveGlobalTint：appearanceStyle=image 无 src 时回退 solid）
    final imageStyle =
        prefs.appearanceStyle == 'image' && prefs.backgroundImage != null;
    final globalTint = prefs.globalTint || imageStyle;
    final effectiveThemeMode = imageStyle ? ThemeMode.dark : themeMode;
    final fontFamily = prefs.fontFamily;
    // 性能模式：全局关闭动效（隐式 Animated* 系列自动 0 时长）+ 频谱关闭。
    final performanceMode = prefs.performanceMode;
    return AuthBootstrap(
      child: MaterialApp.router(
        title: 'ArchoeraMusic',
        // 国际化：locale 跟随设置/系统；Material 内建文案（菜单/日期等）自动本地化
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildAppTheme(AppPalette.light, Brightness.light,
            accentSeed: accent,
            fontFamily: fontFamily,
            globalTint: globalTint,
            solid: prefs.themeSource == 'solid',
            imageBackground: imageStyle,
            performanceMode: performanceMode),
        darkTheme: buildAppTheme(AppPalette.dark, Brightness.dark,
            accentSeed: accent,
            fontFamily: fontFamily,
            globalTint: globalTint,
            solid: prefs.themeSource == 'solid',
            imageBackground: imageStyle,
            performanceMode: performanceMode),
        themeMode: effectiveThemeMode,
        routerConfig: appRouter,
        builder: (context, child) {
          // 性能模式：在应用子树外加一层 MediaQuery.disableAnimations——
          // MaterialApp 自身的 MediaQuery 位于本 builder 之上，此处覆盖
          // 影响 SplashGate 及以下（Navigator/路由/浮层），隐式 Animated*
          // 组件会自动按 disableAnimations 退化为 0 时长（Flutter 内建支持）。
          var appChild = child ?? const SizedBox.shrink();
          Widget gate = SplashGate(
            child: AppShortcuts(
              child: ToastOverlay(child: appChild),
            ),
          );
          if (performanceMode) {
            gate = MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: gate,
            );
          }
          return gate;
        },
      ),
    );
  }
}

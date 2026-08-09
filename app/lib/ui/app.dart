import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_shell.dart';
import 'pages/download_page.dart';
import 'pages/favorites_page.dart';
import 'pages/history_page.dart';
import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/liked_page.dart';
import 'pages/player_page.dart';
import 'pages/search_page.dart';
import 'pages/streaming_detail_pages.dart';
import 'pages/streaming_page.dart';
import 'theme/app_theme.dart';
import 'widgets/app_shortcuts.dart';
import 'widgets/splash_screen.dart';
import 'widgets/toast.dart';

import '../core/playback/playback_notifier.dart';
import '../core/downloader/download_controller.dart';
import '../core/state/app_prefs.dart';
import '../core/state/providers.dart';
import '../l10n/generated/app_localizations.dart';
import '../l10n/l10n.dart';

/// 根导航器 key（供 MaterialApp 外的组件，如托盘确认弹窗，定位根 Navigator）。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 主题模式（对照原项目 appearance.themeMode：light / dark / system）。
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;

  /// 循环切换 light → dark → system（对齐原项目 NavHeader 主题按钮）。
  void cycle() {
    state = switch (state) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.light,
    };
  }

  /// 显式设置主题模式（设置弹窗三态选择）。
  void setMode(ThemeMode mode) => state = mode;
}

/// 应用路由（对齐原项目 router：壳内分支 + 全屏播放器覆盖层）。
///
/// 壳内分支（带侧边栏 + 顶部栏 + 底部播放条）：首页 / 音乐库 /
/// 我喜欢 / 收藏 / 历史 / 下载；搜索为隐藏分支（不在侧边栏，
/// 由顶栏搜索框/快捷键进入——对齐原版：搜索不放侧边栏）。
/// 设置改为顶栏齿轮弹窗（settings_dialog.dart），不占路由分支。
/// 顶层 `/player`：全屏播放器覆盖层（点击播放条封面展开，盖住整个壳，
/// 含播放条——对齐原项目 FullPlayer 的 isPlayerExpanded 语义）。
final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/', builder: (context, state) => const HomePage()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              builder: (context, state) => const LibraryPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/liked',
              builder: (context, state) => const LikedPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/favorites',
              builder: (context, state) => const FavoritesPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/history',
              builder: (context, state) => const HistoryPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/download',
              builder: (context, state) => const DownloadPage(),
            ),
          ],
        ),
        // 隐藏分支：搜索（不在侧边栏，顶栏搜索框 context.go 进入）
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              builder: (context, state) => SearchPage(
                initialQuery: state.uri.queryParameters['q'] ?? '',
              ),
            ),
          ],
        ),
        // 流媒体分支：服务器媒体库（歌曲/专辑/歌手/歌单 + 详情页）
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/streaming',
              builder: (context, state) => const StreamingPage(),
            ),
            GoRoute(
              path: '/streaming/album/:id',
              builder: (context, state) => StreamingAlbumDetailPage(
                id: Uri.decodeComponent(state.pathParameters['id'] ?? ''),
              ),
            ),
            GoRoute(
              path: '/streaming/artist/:id',
              builder: (context, state) => StreamingArtistDetailPage(
                id: Uri.decodeComponent(state.pathParameters['id'] ?? ''),
              ),
            ),
            GoRoute(
              path: '/streaming/playlist/:id',
              builder: (context, state) => StreamingPlaylistDetailPage(
                id: Uri.decodeComponent(state.pathParameters['id'] ?? ''),
              ),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      parentNavigatorKey: rootNavigatorKey,
      path: '/player',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        transitionsBuilder:
            (context, animation, secondaryAnimation, child) {
          // 底部展开 + 轻微放大 + 淡入（对齐原版 FullPlayer 从底部
          // 展开的覆盖层语义；easeOutQuart 收尾更柔顺，避免生硬）
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutQuart,
            reverseCurve: Curves.easeInQuart,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.08),
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
                child: child,
              ),
            ),
          );
        },
        child: const PlayerPage(),
      ),
    ),
  ],
);

/// ArchoeraMusic 应用根：主题 + 路由。
class ArchoeraMusicApp extends ConsumerWidget {
  const ArchoeraMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final prefs = ref.watch(appPrefsProvider);
    final locale = ref.watch(localeProvider);
    // 主色种子：开启「跟随系统主题色」时取系统色（读取失败回退自定义色）
    final systemAccent = ref.watch(systemAccentProvider).value;
    final accent = prefs.accentSystem ? systemAccent : prefs.accentColor;
    final fontFamily = prefs.fontFamily;
    return _AuthBootstrap(
      child: MaterialApp.router(
        title: 'ArchoeraMusic',
        // 国际化：locale 跟随设置/系统；Material 内建文案（菜单/日期等）自动本地化
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildAppTheme(AppPalette.light, Brightness.light,
            accentSeed: accent, fontFamily: fontFamily),
        darkTheme: buildAppTheme(AppPalette.dark, Brightness.dark,
            accentSeed: accent, fontFamily: fontFamily),
        themeMode: themeMode,
        routerConfig: appRouter,
        builder: (context, child) => SplashGate(
          child: AppShortcuts(
            child: ToastOverlay(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}

/// 启动时初始化网易云登录态（匿名注册 + 读取持久化账号）。
class _AuthBootstrap extends ConsumerStatefulWidget {
  const _AuthBootstrap({required this.child});

  final Widget child;

  @override
  ConsumerState<_AuthBootstrap> createState() => _AuthBootstrapState();
}

class _AuthBootstrapState extends ConsumerState<_AuthBootstrap> {
  @override
  void initState() {
    super.initState();
    // 异步初始化：不阻塞首帧渲染
    Future<void>.microtask(() async {
      // 并行：恢复播放现场（含位置续播）与网易云登录态初始化互不阻塞
      await Future.wait([
        ref.read(playbackProvider.notifier).restore(),
        ref.read(neteaseAuthProvider.notifier).init(),
      ]);
      // 下载引擎初始化（触发 build → init 注册回调 + 注入已持久化会话）。
      // 放在登录态恢复之后：注入 Rust 的 session/cookie 始终取最新状态。
      ref.read(downloadControllerProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 登录态变化（含启动 init 后）时同步红心集合；
    // 酷狗 provider 仅在登录/登出时 notify，不会因普通 API 调用触发。
    ref.listen(neteaseAuthProvider, (_, _) {
      ref.read(likeControllerProvider).sync();
      // 登录/登出后把最新 cookie 重新注入下载引擎（幂等）
      ref.read(downloadControllerProvider.notifier).syncSessions();
    });
    ref.listen(kugouApiProvider, (_, _) {
      ref.read(likeControllerProvider).sync();
      ref.read(downloadControllerProvider.notifier).syncSessions();
    });
    return widget.child;
  }
}

/// 启动过渡门：品牌 Splash 覆盖整个应用，1.9s 后 550ms 淡出（轻微上移缩放）
/// 过渡到主界面，动画结束才从树中移除。
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child});

  final Widget child;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate>
    with SingleTickerProviderStateMixin {
  /// 淡出过渡（0 → 1）。注意：控制器初始 value 为 0，
  /// 因此 opacity 必须用 `1 → 0` 的 Tween——否则首帧 Splash 透明，
  /// 露出底部主界面（曾出现的「先进主页再进动画」bug）。
  late final AnimationController _dismiss = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );

  bool _removed = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 1900), () {
      if (!mounted) return;
      _dismiss.forward().then((_) {
        if (mounted) setState(() => _removed = true);
      });
    });
  }

  @override
  void dispose() {
    _dismiss.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_removed)
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(
                CurvedAnimation(
                  parent: _dismiss,
                  curve: Curves.easeInCubic,
                ),
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 1, end: 0.98).animate(
                  CurvedAnimation(
                    parent: _dismiss,
                    curve: Curves.easeInCubic,
                  ),
                ),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(0, -0.03),
                  ).animate(CurvedAnimation(
                    parent: _dismiss,
                    curve: Curves.easeInCubic,
                  )),
                  child: const SplashScreen(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

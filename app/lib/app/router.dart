// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../pages/download_page.dart';
import '../pages/favorites_page.dart';
import '../pages/history_page.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/liked_page.dart';
import '../pages/player_page.dart';
import '../pages/search_page.dart';
import '../pages/streaming/album_detail_page.dart';
import '../pages/streaming/artist_detail_page.dart';
import '../pages/streaming/playlist_detail_page.dart';
import '../pages/streaming/streaming_page.dart';
import 'player_route_controller.dart';
import 'player_route_curves.dart';
import 'shell.dart';

/// 根导航器 key（供 MaterialApp 外的组件，如托盘确认弹窗，定位根 Navigator）。
final rootNavigatorKey = GlobalKey<NavigatorState>();

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
      path: kPlayerRoutePath,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        // 非不透明：过渡期间 Overlay 仍绘制下方主页（主页保持原位，不做
        // 缩放/淡出，只被播放页上滑盖住）。展开动画结束后壳内容由
        // `OffstageWhenComplete` 停绘/停 ticker（State 保留），背后绘制开销为零。
        opaque: false,
        transitionDuration: kPlayerRouteTransitionDuration,
        reverseTransitionDuration: kPlayerRouteTransitionDuration,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // 性能模式（MediaQuery.disableAnimations）：播放页直切，无展开动效
          if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
            return child;
          }
          // 纯垂直上滑（对齐原版 FullPlayer 的 `translate-y-full → 0`，
          // 时长见 `kPlayerRouteTransitionDuration`）。
          // 曲线改成单峰：展开先快后慢、收起先慢后快（见
          // `player_route_curves.dart`）；收起走 reverseCurve，Flutter 直接把它
          // 作用在 1 → 0 的递减值上，因此两条曲线都用 ease-out 形状。
          final curved = CurvedAnimation(
            parent: animation,
            curve: kPlayerRouteOpenCurve,
            reverseCurve: kPlayerRouteCloseCurve,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
        child: const PlayerPage(),
      ),
    ),
  ],
);

/// 展开全屏播放页（幂等）。
///
/// 只转发一条**打开事件**给 [PlayerRouteController]：开关状态、重复点击、
/// 收起期间的挂起请求、push 被吞的自愈全部由状态机负责，这里不再维护
/// inFlight / closing / deferred 之类的模块级布尔量与兜底定时器。
///
/// [router] 仅供测试注入；业务代码一律省略（使用全局 [appRouter]）。
void openPlayerPage({GoRouter? router}) =>
    PlayerRouteController.instance.open(router ?? appRouter);

/// 收起全屏播放页（幂等；收起动画期间重复调用忽略）。
void closePlayerPage({GoRouter? router}) =>
    PlayerRouteController.instance.close(router ?? appRouter);

/// 打开 / 关闭全屏播放页（快捷键 `ShortcutAction.openPlayer` 的切换入口）。
void togglePlayerPage({GoRouter? router}) =>
    PlayerRouteController.instance.toggle(router ?? appRouter);

/// 当前是否已展开全屏播放页（含展开中 / 收起中）。
///
/// 来自状态机事件，不再用路由栈或 push future 推断。
bool get isPlayerPageOpen => PlayerRouteController.instance.isOpen;

/// 测试用：复位开关状态（单例状态会跨用例泄漏；用例结束时常有页面未关闭）。
@visibleForTesting
void resetPlayerPageRouteStateForTest() =>
    PlayerRouteController.instance.resetForTest();

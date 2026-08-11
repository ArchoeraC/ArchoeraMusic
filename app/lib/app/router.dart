import 'package:flutter/material.dart';
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
      path: '/player',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        transitionsBuilder:
            (context, animation, secondaryAnimation, child) {
          // 性能模式（MediaQuery.disableAnimations）：播放页直切，无展开动效
          if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
            return child;
          }
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

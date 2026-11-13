// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

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
import '../services/log/log.dart';
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
      path: '/player',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        // 非不透明：过渡期间 Overlay 仍绘制下方主页（主页保持原位，不做
        // 缩放/淡出，只被播放页上滑盖住）。展开动画结束后壳内容由
        // OffstageWhenComplete 停绘/停 ticker（State 保留），背后绘制开销为零。
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

/// 全屏播放页路由路径（`openPlayerPage` / 栈内匹配判定共用）。
const String kPlayerRoutePath = '/player';

/// 一次 push 是否在途（防止封面连点 / 快捷键长按叠加出多层播放页）。
///
/// 只表示「已经 push、还没 pop」，**不代表**播放页在栈上（判定见
/// [isPlayerPageOpen]）。
bool _playerRouteInFlight = false;

/// 收起动画是否在途（防止快捷键连按重复 pop 掉下层页面）。
///
/// 由 [closePlayerPage] 置位，由 [notifyPlayerPageDisposed]（路由真正卸载）
/// 或兜底定时器复位 —— **不能**用 push future 复位：go_router 在 pop 的瞬间
/// 就完成 future，此时收起动画才刚开始（见 2026-11-12 的连点误 pop 事故）。
bool _playerRouteClosing = false;

/// 收起动画期间收到的「打开」请求：等路由真正卸载后再 push。
///
/// 收起动画还没走完就 push，会让新的 imperative 匹配与正在归还的那一条抢
/// 同一个位置（go_router 在 release 下可能只更新配置却不重绘，
/// 见 flutter/flutter#188307）。延迟到卸载后 push 既避开竞态，也不会出现
/// 「上滑与下滑同时进行」的观感。
bool _deferredOpen = false;

/// 收起兜底定时器（路由万一没有按预期卸载时复位守卫，防止永久锁死）。
Timer? _closingTimer;

/// 最近一次执行 push 的路由器（测试会注入独立 GoRouter；延迟打开要回到同一个）。
GoRouter? _openRouter;

/// 当前是否已展开全屏播放页（**从路由栈实时推导**）。
///
/// 不能用模块布尔量表示「已打开」，也不能用
/// `routerDelegate.currentConfiguration.uri.path` 判断：
/// - `uri` 只反映非 [ImperativeRouteMatch] 的匹配，`push('/player')` 产生的
///   正是 imperative match，用 uri 判断会恒为 false（2026-11-12：播放页打开后
///   关不掉）；
/// - 用 push future 复位布尔量则会**永久锁死**：go_router 的
///   `GoRouterDelegate._setCurrentConfiguration` 在整栈替换（`go()`、分支跳转、
///   深链跳转）时直接丢弃 imperative 匹配，**不会完成** push 的 completer，
///   `whenComplete` 永不触发 —— 播放页从界面上消失，而开关守卫仍认为它开着，
///   之后封面点击 / 快捷键全部静默无效，且没有任何日志/异常
///   （2026-11-13 现场复现：播放页打开时按「前往音乐库」等 go 导航）。
bool get isPlayerPageOpen => _hasPlayerMatch(_openRouter ?? appRouter);

/// 展开全屏播放页（幂等）。
///
/// 防护：
/// 1. 播放页已在栈上（真实栈判定）→ 直接返回；
/// 2. 已有一次 push 在途（尚未 pop）→ 直接返回；
/// 3. 收起动画未结束 → 记下请求，等播放页路由卸载后再 push（见
///    [_deferredOpen]）。
///
/// 快捷键（`ShortcutAction.openPlayer`）与播放条封面统一走此入口。
///
/// [router] 仅供测试注入；业务代码一律省略（使用全局 [appRouter]）。
void openPlayerPage({GoRouter? router}) {
  final r = router ?? appRouter;
  if (_playerRouteInFlight || _hasPlayerMatch(r)) return;
  if (_playerRouteClosing) {
    _deferredOpen = true;
    return;
  }
  _playerRouteInFlight = true;
  _openRouter = r;
  r.push(kPlayerRoutePath).whenComplete(() {
    _playerRouteInFlight = false;
  });
  _verifyPushed(r);
}

/// 播放页路由是否在 [router] 的栈上（含 shell 内部，递归查找）。
bool _hasPlayerMatch(GoRouter router) =>
    _matchContainsPlayer(router.routerDelegate.currentConfiguration.matches);

bool _matchContainsPlayer(List<RouteMatchBase> matches) {
  for (final match in matches) {
    if (match is ImperativeRouteMatch &&
        match.matchedLocation == kPlayerRoutePath) {
      return true;
    }
    if (match is ShellRouteMatch && _matchContainsPlayer(match.matches)) {
      return true;
    }
  }
  return false;
}

/// push 之后核对一次：匹配没进栈就释放守卫，避免「再也打不开」。
///
/// push 的匹配由路由解析（微任务）写入配置，正常情况下隔一帧必然可见。
/// 若仍不可见，说明这次 push 被上游吞掉了（整栈替换丢弃 imperative 匹配、
/// 路由解析事务被新导航覆盖等）—— completer 不会完成，
/// [_playerRouteInFlight] 会永久为真。这里自愈：最多让用户多点一次。
void _verifyPushed(GoRouter router) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // 期间已经正常关闭 / 已复位：无需核对（避免误报）。
    if (!_playerRouteInFlight || _playerRouteClosing) return;
    if (!_hasPlayerMatch(router)) {
      _playerRouteInFlight = false;
      Log.w('player', 'open: 播放页一帧后仍未进栈，已释放开关守卫（下次点击重试）');
      return;
    }
    // 匹配在栈上：补一次 Router 通知。release 下 go_router 偶发只更新了
    // 配置却不重绘（flutter/flutter#188307），补通知后新页必定被重建出来，
    // 避免「配置里已打开、界面上打不开」的静默状态。
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    router.routerDelegate.notifyListeners();
  });
}

/// 收起全屏播放页（幂等；收起动画期间重复调用忽略）。
///
/// `canPop()` 守住「push 还没被路由处理」的窗口：同一帧内连按快捷键会先 open
/// 再 close，此时页栈里还没有播放页，`pop()` 会抛 `GoError: There is nothing to pop`。
void closePlayerPage({GoRouter? router}) {
  final r = router ?? appRouter;
  if (_playerRouteClosing || !_hasPlayerMatch(r) || !r.canPop()) return;
  _playerRouteClosing = true;
  r.pop();
  // 兜底：路由万一没有走到 dispose（异常卸载 / 被整栈替换吞掉），
  // 也不能让守卫永久停在收起态 —— 转场时长之后强制复位。
  _closingTimer?.cancel();
  _closingTimer = Timer(
    kPlayerRouteTransitionDuration + const Duration(milliseconds: 100),
    () {
      _closingTimer = null;
      if (!_playerRouteClosing) return;
      _playerRouteClosing = false;
      _flushDeferredOpen();
    },
  );
}

/// 播放页路由已从树上卸载（收起动画结束，路由真正移出导航栈）。
///
/// 由 `PlayerPage.dispose` 调用：这是「收起完成」唯一可靠的时点——
/// push future 在 pop 瞬间就完成，那时动画才刚开始。
void notifyPlayerPageDisposed() {
  _playerRouteClosing = false;
  // 播放页已不在栈上：无论这次 push 是正常 pop、还是被整栈替换静默丢弃，
  // 「push 在途」都必须放开（后者不会完成 push future，只能在这里兜住）。
  _playerRouteInFlight = false;
  _closingTimer?.cancel();
  _closingTimer = null;
  _flushDeferredOpen();
}

/// 执行收起期间挂起的打开请求。
void _flushDeferredOpen() {
  if (!_deferredOpen) return;
  _deferredOpen = false;
  // dispose / 兜底定时器可能落在 Navigator 的帧内收尾流程里：push 推迟到
  // 帧末，避免在 build 阶段触发路由通知（release 下会被静默丢弃）。
  final binding = WidgetsBinding.instance;
  binding.addPostFrameCallback((_) {
    final r = _openRouter ?? appRouter;
    if (_hasPlayerMatch(r)) return;
    openPlayerPage(router: r);
  });
  // 挂起请求可能发生在帧末兜底定时器里（此时没有待渲染的内容）：
  // 显式要一帧，保证上面的帧末回调一定会被执行。
  binding.ensureVisualUpdate();
}

/// 打开 / 关闭全屏播放页（快捷键 `ShortcutAction.openPlayer` 的切换入口）。
void togglePlayerPage({GoRouter? router}) {
  final r = router ?? appRouter;
  if (_hasPlayerMatch(r)) {
    closePlayerPage(router: r);
  } else {
    openPlayerPage(router: r);
  }
}

/// 测试用：复位开关状态（模块级状态会跨用例泄漏；用例结束时常有页面未关闭）。
@visibleForTesting
void resetPlayerPageRouteStateForTest() {
  _playerRouteInFlight = false;
  _playerRouteClosing = false;
  _deferredOpen = false;
  _openRouter = null;
  _closingTimer?.cancel();
  _closingTimer = null;
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页开关入口回归（2026-11-12 线上问题：播放页打开后关闭按钮无响应）。
///
/// 根因：`isPlayerPageOpen` 曾用 `routerDelegate.currentConfiguration.uri.path`
/// 判断，而 go_router 的 `RouteMatchList.uri` **只反映非 imperative 匹配**——
/// `push('/player')` 产生的是 [ImperativeRouteMatch]，uri 仍停在壳层地址，
/// 于是 `closePlayerPage()` 的守卫恒为 false 直接 return，关闭按钮 / 快捷键都失效。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:archoera_music/app/router.dart';
import 'package:archoera_music/app/player_route_curves.dart';

void main() {
  // 开关状态是模块级全局量：用例之间必须复位（上一个用例可能停在播放页）。
  setUp(resetPlayerPageRouteStateForTest);

  testWidgets('push 出来的播放页能被 closePlayerPage 关闭，并可再次打开', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(path: '/player', builder: (_, _) => const _PlayerRoutePage()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(isPlayerPageOpen, isTrue);

    // 锚定 go_router 语义：imperative push 不参与 uri，旧判断在这里拿到 '/home'。
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/home',
      reason: '若此断言失效，说明 go_router 语义变了，可重新评估 isPlayerPageOpen 的实现',
    );

    closePlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsNothing);
    expect(isPlayerPageOpen, isFalse);

    // 关闭后状态复位：还能再打开。
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('重复关闭不会多 pop 掉壳层；未打开时关闭是空操作', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(path: '/player', builder: (_, _) => const _PlayerRoutePage()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    closePlayerPage(router: router); // 未打开：不应抛 GoError
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);

    // 收起动画在途时重复关闭：第二次被忽略，壳层不会被连带 pop。
    closePlayerPage(router: router);
    closePlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('player'), findsNothing);

    // 反复开关仍然可用（收起结束时复位守卫）。
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    closePlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('播放页打开时整栈替换（go）不会把开关锁死', (tester) async {
    // 2026-11-13 现场问题：收起后「一定时间内」打不开播放页，无日志、单测全绿。
    // 根因：go_router 的 `GoRouterDelegate._setCurrentConfiguration` 在整栈替换
    // （`go()` / 分支跳转 / 深链）时直接丢弃 imperative 匹配，**不会**完成
    // `push()` 的 completer → `whenComplete` 永不触发 → 旧的布尔守卫永久停在
    // 「已打开」，之后封面点击与快捷键都静默无效（`canPop()` 也已是 false，
    // 连 toggle 都退化成空操作）。
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(path: '/library', builder: (_, _) => const Text('library')),
        GoRoute(path: '/player', builder: (_, _) => const _PlayerRoutePage()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(isPlayerPageOpen, isTrue);

    // 「前往音乐库」之类的 go 导航：播放页匹配被丢弃（不经过 pop）。
    router.go('/library');
    await tester.pumpAndSettle();
    expect(find.text('library'), findsOneWidget);
    expect(
      isPlayerPageOpen,
      isFalse,
      reason: '状态必须来自真实路由栈，不能依赖 push future（它永远不会完成）',
    );

    // 还能再次打开（旧实现这里会被静默拦掉）。
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(isPlayerPageOpen, isTrue);
  });

  testWidgets('收起动画期间请求打开：收起结束后自动打开，不丢请求', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(
          path: '/player',
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            opaque: false,
            transitionDuration: kPlayerRouteTransitionDuration,
            reverseTransitionDuration: kPlayerRouteTransitionDuration,
            transitionsBuilder: (context, animation, secondary, child) =>
                FadeTransition(opacity: animation, child: child),
            // 真实播放页在 dispose 里回报「收起完成」（见 notifyPlayerPageDisposed）。
            child: const _PlayerRoutePage(),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);

    closePlayerPage(router: router);
    await tester.pump(const Duration(milliseconds: 60)); // 收起动画中途
    openPlayerPage(router: router); // 立刻又要打开
    await tester.pumpAndSettle();

    expect(find.text('player'), findsOneWidget, reason: '收起期间的打开请求不能丢');
    expect(isPlayerPageOpen, isTrue);
  });
}

/// 模拟真实播放页的收起收尾约定：路由卸载时回报 [notifyPlayerPageDisposed]。
class _PlayerRoutePage extends StatefulWidget {
  const _PlayerRoutePage();

  @override
  State<_PlayerRoutePage> createState() => _PlayerRoutePageState();
}

class _PlayerRoutePageState extends State<_PlayerRoutePage> {
  @override
  void dispose() {
    notifyPlayerPageDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('player');
}

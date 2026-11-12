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

void main() {
  // 开关状态是模块级全局量：用例之间必须复位（上一个用例可能停在播放页）。
  setUp(resetPlayerPageRouteStateForTest);

  testWidgets('push 出来的播放页能被 closePlayerPage 关闭，并可再次打开', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('home')),
        GoRoute(path: '/player', builder: (_, _) => const Text('player')),
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
        GoRoute(path: '/player', builder: (_, _) => const Text('player')),
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

    // 反复开关仍然可用（状态在 whenComplete 里复位）。
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    closePlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}

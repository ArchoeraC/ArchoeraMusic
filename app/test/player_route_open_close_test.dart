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

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:archoera_music/app/player_route_controller.dart';
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
            // 真实播放页在 dispose 里回报「路由已卸载」（见 routeDetached）。
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

  /// 快捷键连按 / 快速点封面：`push` 与 `pop` 挤在同一帧，播放页可能**从未构建**
  /// （因此既没有 attach 也没有 detach 事件）。旧实现会永远停在 closing，
  /// 之后的打开请求全部被挂起 → 用户看到「按一下快捷键后整个播放页再也打不开」。
  testWidgets('同一帧内打开后立刻关闭：不会卡在 closing，之后仍能打开', (tester) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openPlayerPage(router: router);
    closePlayerPage(router: router); // 页面还没构建/挂载
    await tester.pumpAndSettle();

    expect(
      PlayerRouteController.instance.phase,
      PlayerRoutePhase.closed,
      reason: '必须收敛为 closed，否则后续打开请求会被挂起',
    );
    expect(find.text('player'), findsNothing);

    // 仍然可再次打开（旧实现这里会静默无效）。
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(PlayerRouteController.instance.phase, PlayerRoutePhase.open);
  });

  /// 连按快捷键（每帧一次 toggle）：状态机不能因此进入 push/pop 抖动，
  /// 安静下来后「状态」必须与「界面上有没有播放页」一致。
  testWidgets('每帧一次连续切换：状态与界面保持一致，且不抛异常', (tester) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    for (var i = 0; i < 40; i++) {
      togglePlayerPage(router: router);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final visible = find.text('player').evaluate().isNotEmpty;
    expect(
      isPlayerPageOpen,
      visible,
      reason: '状态机与真实界面不能失步（否则下一次打开/关闭会静默无效）',
    );
    expect(
      PlayerRouteController.instance.phase == PlayerRoutePhase.opening ||
          PlayerRouteController.instance.phase == PlayerRoutePhase.closing,
      isFalse,
      reason: '动画结束后不允许停在过渡态（停在 closing 会让后续打开请求永久挂起）',
    );

    // 收敛后仍可正常开关。
    if (isPlayerPageOpen) {
      closePlayerPage(router: router);
      await tester.pumpAndSettle();
    }
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('同一帧内打开后立刻整栈替换（页面从未构建）：不会卡在 opening', (tester) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openPlayerPage(router: router);
    // 打开的同时「前往音乐库」：新导航覆盖这次 push，播放页可能从未构建。
    router.go('/library');
    await tester.pumpAndSettle();

    expect(
      PlayerRouteController.instance.phase,
      isNot(PlayerRoutePhase.opening),
      reason: '页面从未挂载时必须收敛（帧末核对兜底）',
    );
    expect(find.text('player'), findsNothing);

    // 仍能正常打开（旧实现会静默无效）。
    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(PlayerRouteController.instance.phase, PlayerRoutePhase.open);
  });

  /// 快捷键在弹窗打开时也会触发：关闭播放页不能把顶上的弹窗（或更下层页面）
  /// 误 pop 掉，更不能靠「重试 pop」连续 pop。
  testWidgets('播放页顶上有弹窗时，关闭播放页不会误 pop 其它路由', (tester) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    openPlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);

    router.routerDelegate.navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('popup')),
    );
    await tester.pumpAndSettle();
    expect(find.text('popup'), findsOneWidget);

    closePlayerPage(router: router);
    await tester.pumpAndSettle();

    expect(find.text('popup'), findsOneWidget, reason: '不能误 pop 顶上的弹窗');
    // 播放页被不透明弹窗盖住 → offstage，仍应挂在树上。
    expect(find.text('player', skipOffstage: false), findsOneWidget);
    expect(PlayerRouteController.instance.phase, PlayerRoutePhase.open);

    // 弹窗关掉之后仍能正常收起播放页。
    router.routerDelegate.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    closePlayerPage(router: router);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsNothing);
    expect(PlayerRouteController.instance.phase, PlayerRoutePhase.closed);
  });
}

/// 与真实 appRouter 同构的最小路由（`/player` 用非不透明转场页）。
GoRouter _testRouter() => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('home')),
    GoRoute(path: '/library', builder: (_, _) => const Text('library')),
    GoRoute(
      path: kPlayerRoutePath,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        opaque: false,
        transitionDuration: kPlayerRouteTransitionDuration,
        reverseTransitionDuration: kPlayerRouteTransitionDuration,
        transitionsBuilder: (context, animation, secondary, child) =>
            FadeTransition(opacity: animation, child: child),
        child: const _PlayerRoutePage(),
      ),
    ),
  ],
);

/// 模拟真实播放页的收起收尾约定：
/// - `didChangeDependencies` 上报「已绑定路由动画」；
/// - 动画走完 / 收起走完上报 opened / dismissed；
/// - `dispose` 上报「路由已卸载」。
class _PlayerRoutePage extends StatefulWidget {
  const _PlayerRoutePage();

  @override
  State<_PlayerRoutePage> createState() => _PlayerRoutePageState();
}

class _PlayerRoutePageState extends State<_PlayerRoutePage> {
  Animation<double>? _animation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _animation)) return;
    _animation?.removeStatusListener(_onStatus);
    _animation = animation;
    animation?.addStatusListener(_onStatus);
    if (animation != null) {
      PlayerRouteController.instance.routeAttached(animation, ModalRoute.of(context));
    }
  }

  void _onStatus(AnimationStatus status) {
    final animation = _animation;
    if (animation == null) return;
    if (status == AnimationStatus.completed) {
      PlayerRouteController.instance.routeOpened(animation);
    } else if (status == AnimationStatus.dismissed) {
      PlayerRouteController.instance.routeDismissed(animation);
    }
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatus);
    PlayerRouteController.instance.routeDetached(_animation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('player');
}

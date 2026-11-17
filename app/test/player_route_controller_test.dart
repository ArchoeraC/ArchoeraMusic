// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页开关状态机（[PlayerRouteController]）回归：
/// - 阶段只由事件推进（打开/关闭命令 + 页面回报），不再靠监听动画值反推；
/// - 状态字段同步生效（守卫读到的永远是最新值），通知压到微任务（构建期
///   上报不会触发「build 期间修改状态」断言——旧实现正是在这里抛异常，把
///   壳层的清理逻辑打断，界面永久停在停绘态）；
/// - 关闭后迅速重开时，旧实例的卸载/收起事件不能清掉新实例的状态。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/app/player_route_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final controller = PlayerRouteController.instance;
  setUp(controller.resetForTest);
  tearDown(controller.resetForTest);

  AnimationController newAnimation() => AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(seconds: 1),
  );

  group('页面事件推进阶段', () {
    test('绑定动画 → opening；动画走完 → open；路由卸载 → closed', () {
      final route = newAnimation();
      addTearDown(route.dispose);

      expect(controller.phase, PlayerRoutePhase.closed);
      expect(controller.isOpen, isFalse);

      controller.routeAttached(route, null);
      expect(controller.phase, PlayerRoutePhase.opening);
      expect(controller.animation, same(route));
      expect(controller.isOpen, isTrue);

      controller.routeOpened(route);
      expect(controller.phase, PlayerRoutePhase.open);

      controller.routeDetached(route);
      expect(controller.phase, PlayerRoutePhase.closed);
      expect(controller.animation, isNull);
      expect(controller.isOpen, isFalse);
    });

    test('旧实例的卸载 / 收起事件不会清掉新实例（身份守卫）', () {
      final oldRoute = newAnimation();
      final newRoute = newAnimation();
      addTearDown(oldRoute.dispose);
      addTearDown(newRoute.dispose);

      controller.routeAttached(oldRoute, null);
      // 新实例挂载：写入自己的路由动画（旧实例尚未 dispose）。
      controller.routeAttached(newRoute, null);
      expect(controller.animation, same(newRoute));

      controller.routeDetached(oldRoute);
      expect(
        controller.animation,
        same(newRoute),
        reason: '旧实例清空后壳层会拿到 0 动画，永久停在折叠/停绘态',
      );
      expect(controller.phase, PlayerRoutePhase.opening);

      controller.routeDismissed(oldRoute);
      expect(controller.phase, PlayerRoutePhase.opening);

      // 新实例自己卸载：正常收敛。
      controller.routeDetached(newRoute);
      expect(controller.phase, PlayerRoutePhase.closed);
    });

    test('重复绑定同一动画只通知一次（幂等）', () async {
      final route = newAnimation();
      addTearDown(route.dispose);
      var notifications = 0;
      void listener() => notifications++;
      controller.addListener(listener);
      addTearDown(() => controller.removeListener(listener));

      controller.routeAttached(route, null);
      await pumpEventQueue();
      expect(notifications, 1);

      controller.routeAttached(route, null);
      await pumpEventQueue();
      expect(notifications, 1);
    });

    test('路由卸载后补发收起期间挂起的打开请求', () async {
      // 事件顺序：打开 →（收起命令由路由测试覆盖）→ 卸载。
      // 这里只验证「卸载事件会把状态收敛干净」，挂起补发在
      // player_route_open_close_test 里做端到端验证。
      final route = newAnimation();
      addTearDown(route.dispose);
      controller.routeAttached(route, null);
      controller.routeOpened(route);
      controller.routeDetached(null); // 不带动画的卸载事件（旧实例兜底路径）
      expect(controller.phase, PlayerRoutePhase.closed);
    });
  });

  group('通知时机', () {
    test('状态同步生效、通知延后到微任务', () async {
      final route = newAnimation();
      addTearDown(route.dispose);
      var seen = -1;
      controller.addListener(() => seen = controller.phase.index);

      controller.routeAttached(route, null);
      // 事件当帧即可读到最新阶段（命令守卫依赖这一点）。
      expect(controller.phase, PlayerRoutePhase.opening);
      expect(seen, -1, reason: '通知必须离开当前调用栈（构建期安全）');

      await pumpEventQueue();
      expect(seen, PlayerRoutePhase.opening.index);
    });

    testWidgets('在 build 期上报事件不抛「构建期修改」异常', (tester) async {
      final route = newAnimation();
      addTearDown(route.dispose);
      var reported = false;
      // 模拟 PlayerPage 在 didChangeDependencies（构建期）上报绑定事件。
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            if (!reported) {
              reported = true;
              controller.routeAttached(route, null);
            }
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(controller.phase, PlayerRoutePhase.opening);
    });
  });
}

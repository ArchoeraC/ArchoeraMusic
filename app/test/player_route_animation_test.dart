// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页路由动画写入器回归：
/// - 关闭后迅速重开时新旧 `PlayerPage` 实例会短暂重叠，旧实例 `dispose` 清空
///   动画时**只能**清掉自己写入的那个，不能把新实例刚写入的动画抹掉；
/// - 否则壳层（`AppShell` 的展开/卸载判定 / 顶栏下拉收起）会停在错误状态。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/player_route_animation.dart';

void main() {
  test('旧实例清理不会抹掉新实例写入的路由动画', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(playerRouteAnimationProvider.notifier);

    final oldRoute = const AlwaysStoppedAnimation<double>(0.2);
    final newRoute = const AlwaysStoppedAnimation<double>(0.8);

    notifier.set(oldRoute);
    // 新实例挂载：写入自己的路由动画（旧实例尚未 dispose）。
    notifier.set(newRoute);
    expect(container.read(playerRouteAnimationProvider), same(newRoute));

    // 旧实例 dispose：只允许清掉自己那个。
    notifier.clear(oldRoute);
    expect(
      container.read(playerRouteAnimationProvider),
      same(newRoute),
      reason: '旧实例清空后壳层会拿到 AlwaysStoppedAnimation(0)，卡在折叠态',
    );

    // 新实例自己 dispose：正常清空。
    notifier.clear(newRoute);
    expect(container.read(playerRouteAnimationProvider), isNull);
  });

  test('重复写入同一动画不触发通知；无动画时 clear 是空操作', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(playerRouteAnimationProvider.notifier);

    final route = const AlwaysStoppedAnimation<double>(0.5);
    notifier.set(route);
    notifier.set(route);

    notifier.clear(null);
    expect(container.read(playerRouteAnimationProvider), same(route));
  });
}

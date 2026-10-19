// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 应用壳页面切换转场注册表。
///
/// 新增转场只需：
/// 1. 在 `transitions/` 新建模块并实现 [RouteTransition]；
/// 2. 加进 [routeTransitions]；
/// 3. 在 `prefs_appearance.dart` 的 `routeTransitionIds` 登记同一个 id；
/// 4. `test/route_transition_registry_test.dart` 会守卫两处一致。
library;

import 'route_transition.dart';
import 'transitions/fade_route_transition.dart';
import 'transitions/none_route_transition.dart';
import 'transitions/slide_route_transition.dart';
import 'transitions/zoom_route_transition.dart';

/// 内建页面转场（顺序仅用于注册表遍历）。
const List<RouteTransition> routeTransitions = <RouteTransition>[
  NoneRouteTransition(),
  FadeRouteTransition(),
  SlideRouteTransition(),
  ZoomRouteTransition(),
];

final Map<String, RouteTransition> _transitionsById = <String, RouteTransition>{
  for (final transition in routeTransitions) transition.id: transition,
};

/// id → 页面转场；未知 id 回退 `fade`（旧数据/降级安全）。
RouteTransition routeTransitionFor(String id) =>
    _transitionsById[id] ?? _transitionsById['fade']!;

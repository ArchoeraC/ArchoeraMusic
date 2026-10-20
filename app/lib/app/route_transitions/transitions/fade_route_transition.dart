// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `fade`：150ms 淡入（原版进入 0.15s）。
library;

import 'package:material_ui/material_ui.dart';

import '../route_transition.dart';

class FadeRouteTransition extends RouteTransition {
  const FadeRouteTransition();

  @override
  String get id => 'fade';

  @override
  Duration get duration => routeTransitionDuration;

  @override
  Widget build(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) => FadeTransition(opacity: routeTransitionCurved(animation), child: child);
}

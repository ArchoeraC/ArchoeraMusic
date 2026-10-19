// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `zoom`：从 0.97 放大到 1 并淡入（原版 route-zoom 进入 scale(0.97)）。
library;

import 'package:material_ui/material_ui.dart';

import '../route_transition.dart';

class ZoomRouteTransition extends RouteTransition {
  const ZoomRouteTransition();

  @override
  String get id => 'zoom';

  @override
  Duration get duration => routeTransitionDuration;

  @override
  Widget build(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    final curved = routeTransitionCurved(animation);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

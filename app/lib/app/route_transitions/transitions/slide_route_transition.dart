// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `slide`：从右侧 +6px 滑入并淡入（原版 route-slide 进入
/// translateX(6px)）。
library;

import 'package:material_ui/material_ui.dart';

import '../route_transition.dart';

class SlideRouteTransition extends RouteTransition {
  const SlideRouteTransition();

  @override
  String get id => 'slide';

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
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.008, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

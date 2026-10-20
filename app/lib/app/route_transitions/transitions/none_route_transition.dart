// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `none`：无转场，直接显示新分支。
library;

import 'package:material_ui/material_ui.dart';

import '../route_transition.dart';

class NoneRouteTransition extends RouteTransition {
  const NoneRouteTransition();

  @override
  String get id => 'none';

  @override
  Duration get duration => Duration.zero;

  @override
  bool get isNoop => true;

  @override
  Widget build(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) => child;
}

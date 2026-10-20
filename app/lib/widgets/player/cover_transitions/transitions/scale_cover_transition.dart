// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `scale`：轻微缩放 + 位移 + 淡入淡出（默认）。
library;

import 'package:material_ui/material_ui.dart';

import '../cover_transition.dart';
import 'out_in_cover_transition.dart';

class ScaleCoverTransition extends CoverTransition {
  const ScaleCoverTransition();

  @override
  String get id => 'scale';

  @override
  Widget build(BuildContext context, CoverTransitionContext c) =>
      OutInCoverTransition(
        coverKey: c.coverKey,
        next: c.next,
        slide: false,
        leaveDuration: const Duration(milliseconds: 200),
        enterDuration: const Duration(milliseconds: 350),
        // 旧封面略放大离场、新封面从 94% 放大入场；比单纯 ±10px 位移更可感知。
        shift: 16,
        leaveScale: 1.06,
        enterScale: 0.94,
        child: c.child,
      );
}

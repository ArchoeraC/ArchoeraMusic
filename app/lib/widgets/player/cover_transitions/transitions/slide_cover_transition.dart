// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `slide`：全幅滑动，方向跟随播放顺序。
library;

import 'package:material_ui/material_ui.dart';

import '../cover_transition.dart';
import 'out_in_cover_transition.dart';

class SlideCoverTransition extends CoverTransition {
  const SlideCoverTransition();

  @override
  String get id => 'slide';

  @override
  Widget build(BuildContext context, CoverTransitionContext c) =>
      OutInCoverTransition(
        coverKey: c.coverKey,
        next: c.next,
        slide: true,
        leaveDuration: const Duration(milliseconds: 350),
        enterDuration: const Duration(milliseconds: 400),
        child: c.child,
      );
}

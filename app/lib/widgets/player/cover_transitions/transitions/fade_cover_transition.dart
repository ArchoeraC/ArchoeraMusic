// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `fade`：新旧封面双层叠加、纯透明度交叉淡化，不做位移或缩放。
library;

import 'package:material_ui/material_ui.dart';

import '../../../common/cross_fade_switcher.dart';
import '../cover_transition.dart';

class FadeCoverTransition extends CoverTransition {
  const FadeCoverTransition();

  @override
  String get id => 'fade';

  @override
  Widget build(BuildContext context, CoverTransitionContext c) =>
      CrossFadeSwitcher(
        switchKey: c.coverKey,
        // 比上游 SImg 的 200ms 略长，便于感知；只改透明度，避免与封面
        // 自身的播放/暂停缩放叠加成“边淡边动”的观感。
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeInOutCubic,
        child: c.child,
      );
}

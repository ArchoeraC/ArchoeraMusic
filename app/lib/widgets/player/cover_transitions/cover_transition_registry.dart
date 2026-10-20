// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 封面切换动效注册表。
///
/// 新增动效只需：
/// 1. 在 `transitions/` 新建模块并实现 [CoverTransition]；
/// 2. 加进 [coverTransitions]；
/// 3. 在 `prefs_player.dart` 的 `transitionStyles` 登记同一个 id；
/// 4. `test/cover_transition_registry_test.dart` 会守卫两处一致。
library;

import 'cover_transition.dart';
import 'transitions/fade_cover_transition.dart';
import 'transitions/scale_cover_transition.dart';
import 'transitions/slide_cover_transition.dart';

/// 内建封面动效（顺序仅用于注册表遍历）。
const List<CoverTransition> coverTransitions = <CoverTransition>[
  ScaleCoverTransition(),
  SlideCoverTransition(),
  FadeCoverTransition(),
];

final Map<String, CoverTransition> _transitionsById = <String, CoverTransition>{
  for (final transition in coverTransitions) transition.id: transition,
};

/// id → 封面动效；未知 id 回退 `scale`（旧数据/降级安全）。
CoverTransition coverTransitionFor(String id) =>
    _transitionsById[id] ?? _transitionsById['scale']!;

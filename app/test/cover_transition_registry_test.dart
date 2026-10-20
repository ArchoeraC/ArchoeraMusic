// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 封面切换动效注册表守卫：
/// - `transitionStyles`（偏好白名单）与注册表 id 集合必须一致，避免设置里
///   能选到未注册动效、或注册了却无法持久化；
/// - 未知 id 一律回退 `scale`（旧数据/降级安全）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/prefs_player.dart';
import 'package:archoera_music/widgets/player/cover_transitions/cover_transition_registry.dart';

void main() {
  test('注册表 id 与偏好白名单一致', () {
    final ids = coverTransitions.map((transition) => transition.id).toSet();
    expect(ids, equals(transitionStyles));
  });

  test('未知动效回退 scale', () {
    expect(coverTransitionFor('scale').id, 'scale');
    expect(coverTransitionFor('slide').id, 'slide');
    expect(coverTransitionFor('fade').id, 'fade');
    expect(coverTransitionFor('not-a-transition').id, 'scale');
    expect(coverTransitionFor('').id, 'scale');
  });

  test('每个动效 id 唯一', () {
    final ids = coverTransitions.map((transition) => transition.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}

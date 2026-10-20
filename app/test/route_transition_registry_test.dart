// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 页面切换转场注册表守卫：
/// - `routeTransitionIds`（偏好白名单）与注册表 id 集合必须一致，避免设置里
///   能选到未注册转场、或注册了却无法持久化；
/// - 未知 id 一律回退 `fade`（旧数据/降级安全）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/app/route_transitions/route_transition_registry.dart';
import 'package:archoera_music/stores/prefs_appearance.dart' as prefs;

void main() {
  test('注册表 id 与偏好白名单一致', () {
    final ids = routeTransitions.map((transition) => transition.id).toSet();
    expect(ids, equals(prefs.routeTransitionIds));
  });

  test('未知转场回退 fade', () {
    expect(routeTransitionFor('fade').id, 'fade');
    expect(routeTransitionFor('none').id, 'none');
    expect(routeTransitionFor('slide').id, 'slide');
    expect(routeTransitionFor('zoom').id, 'zoom');
    expect(routeTransitionFor('not-a-transition').id, 'fade');
    expect(routeTransitionFor('').id, 'fade');
  });

  test('每个转场 id 唯一', () {
    final ids = routeTransitions.map((transition) => transition.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('none 无动效，其余均有动效', () {
    expect(routeTransitionFor('none').isNoop, isTrue);
    for (final id in ['fade', 'slide', 'zoom']) {
      expect(routeTransitionFor(id).isNoop, isFalse);
    }
  });
}

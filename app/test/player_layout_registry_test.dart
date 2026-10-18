// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页布局注册表守卫：
/// - `coverLayouts`（偏好白名单）与注册表 id 集合必须一致，避免设置里能选到
///   未注册布局、或注册了却无法持久化；
/// - 未知 id 一律回退 `default`（旧数据/降级安全）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/pages/player/layouts/player_layout.dart';
import 'package:archoera_music/stores/prefs_player.dart';

void main() {
  test('注册表 id 与偏好白名单一致', () {
    final ids = playerLayouts.map((layout) => layout.id).toSet();
    expect(ids, equals(coverLayouts));
  });

  test('未知布局回退 default', () {
    expect(playerLayoutFor('default').id, 'default');
    expect(playerLayoutFor('fullscreen').id, 'fullscreen');
    expect(playerLayoutFor('vutron').id, 'vutron');
    expect(playerLayoutFor('not-a-layout').id, 'default');
    expect(playerLayoutFor('').id, 'default');
  });

  test('每个布局 id 唯一', () {
    final ids = playerLayouts.map((layout) => layout.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}

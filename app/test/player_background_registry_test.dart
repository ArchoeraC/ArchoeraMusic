// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页背景注册表守卫：
/// - `playerBgTypes`（偏好白名单）与注册表 id 集合必须一致，避免设置里能选到
///   未注册背景、或注册了却无法持久化；
/// - 未知 id 一律回退 `gradient`（旧数据/降级安全）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/prefs_player.dart';
import 'package:archoera_music/widgets/player/background/player_background_registry.dart';

void main() {
  test('注册表 id 与偏好白名单一致', () {
    final ids = playerBackgrounds.map((style) => style.id).toSet();
    expect(ids, equals(playerBgTypes));
  });

  test('未知背景回退 gradient', () {
    expect(playerBackgroundFor('gradient').id, 'gradient');
    expect(playerBackgroundFor('blur').id, 'blur');
    expect(playerBackgroundFor('ripple').id, 'ripple');
    expect(playerBackgroundFor('not-a-background').id, 'gradient');
    expect(playerBackgroundFor('').id, 'gradient');
  });

  test('每个背景 id 唯一', () {
    final ids = playerBackgrounds.map((style) => style.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}

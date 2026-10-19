// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 侧边栏导航高亮样式注册表守卫：
/// - `sidebarNavStyleIds`（偏好白名单）与注册表 id 集合必须一致，避免设置里
///   能选到未注册样式、或注册了却无法持久化；
/// - 未知 id 一律回退 `default`（旧数据/降级安全）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/prefs_appearance.dart' as prefs;
import 'package:archoera_music/widgets/layout/side_bar/nav_styles/sidebar_nav_style_registry.dart';

void main() {
  test('注册表 id 与偏好白名单一致', () {
    final ids = sidebarNavStyles.map((style) => style.id).toSet();
    expect(ids, equals(prefs.sidebarNavStyleIds));
  });

  test('未知样式回退 default', () {
    expect(sidebarNavStyleFor('default').id, 'default');
    expect(sidebarNavStyleFor('animated').id, 'animated');
    expect(sidebarNavStyleFor('not-a-style').id, 'default');
    expect(sidebarNavStyleFor('').id, 'default');
  });

  test('每个样式 id 唯一', () {
    final ids = sidebarNavStyles.map((style) => style.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('滑动指示条开关', () {
    expect(sidebarNavStyleFor('animated').slidingIndicator, isTrue);
    expect(sidebarNavStyleFor('default').slidingIndicator, isFalse);
  });
}

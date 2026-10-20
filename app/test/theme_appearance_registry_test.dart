// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 主题色来源 / 外观风格注册表守卫：
/// - 注册表 id 与偏好白名单必须一致，避免设置里能选到未注册项、或注册了
///   却无法持久化；
/// - 未知 id 一律回退 `default` / `solid`（旧数据/降级安全）；
/// - 来源映射与外观生效条件保持既有行为。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/app/appearance_styles/appearance_style_registry.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/prefs_appearance.dart' as prefs;
import 'package:archoera_music/theme/theme_sources/theme_source_registry.dart';
import 'package:archoera_music/theme/theme_sources/theme_source_style.dart';

void main() {
  group('注册表结构', () {
    test('主题色来源 id 与偏好白名单一致', () {
      final ids = themeSources.map((source) => source.id).toSet();
      expect(ids, equals(prefs.themeSourceIds));
    });

    test('外观风格 id 与偏好白名单一致', () {
      final ids = appearanceStyles.map((style) => style.id).toSet();
      expect(ids, equals(prefs.appearanceStyleIds));
    });

    test('主题色来源 id 唯一', () {
      final ids = themeSources.map((source) => source.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('外观风格 id 唯一', () {
      final ids = appearanceStyles.map((style) => style.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('未知主题色来源回退 default', () {
      expect(themeSourceStyleFor('default').id, 'default');
      expect(themeSourceStyleFor('custom').id, 'custom');
      expect(themeSourceStyleFor('cover').id, 'cover');
      expect(themeSourceStyleFor('solid').id, 'solid');
      expect(themeSourceStyleFor('not-a-source').id, 'default');
      expect(themeSourceStyleFor('').id, 'default');
    });

    test('未知外观风格回退 solid', () {
      expect(appearanceStyleFor('solid').id, 'solid');
      expect(appearanceStyleFor('image').id, 'image');
      expect(appearanceStyleFor('not-a-style').id, 'solid');
      expect(appearanceStyleFor('').id, 'solid');
    });
  });

  group('主题色来源映射', () {
    const systemAccent = Color(0xFF3366CC);
    const coverAccent = Color(0xFFCC6633);
    const customAccent = Color(0xFF33CC66);
    final customPrefs = AppPrefs(
      initialData: {prefs.accentKey: customAccent.toARGB32()},
    );
    final defaultPrefs = AppPrefs();
    final context = ThemeSourceContext(
      prefs: defaultPrefs,
      systemAccent: systemAccent,
      coverAccent: coverAccent,
    );

    test('default → systemAccent', () {
      expect(
        themeSourceStyleFor('default').accentSeed(context),
        equals(systemAccent),
      );
    });

    test('custom → prefs.accentColor', () {
      expect(
        themeSourceStyleFor('custom')
            .accentSeed(ThemeSourceContext(prefs: customPrefs)),
        equals(customAccent),
      );
    });

    test('cover → coverAccent', () {
      expect(
        themeSourceStyleFor('cover').accentSeed(context),
        equals(coverAccent),
      );
    });

    test('solid → null 且 solid=true', () {
      final solid = themeSourceStyleFor('solid');
      expect(solid.accentSeed(context), isNull);
      expect(solid.solid, isTrue);
      for (final id in ['default', 'custom', 'cover']) {
        expect(themeSourceStyleFor(id).solid, isFalse);
      }
    });

    test('设置项显隐标记', () {
      expect(themeSourceStyleFor('custom').allowsCustomAccent, isTrue);
      expect(themeSourceStyleFor('cover').usesCoverAccent, isTrue);
      for (final id in ['default', 'solid']) {
        expect(themeSourceStyleFor(id).allowsCustomAccent, isFalse);
        expect(themeSourceStyleFor(id).usesCoverAccent, isFalse);
      }
    });

    test('仅 default 订阅系统强调色', () {
      expect(themeSourceStyleFor('default').usesSystemAccent, isTrue);
      for (final id in ['custom', 'cover', 'solid']) {
        expect(themeSourceStyleFor(id).usesSystemAccent, isFalse);
      }
    });
  });

  group('外观风格', () {
    test('image 使用图片背景，solid 不使用', () {
      expect(appearanceStyleFor('image').usesImageBackground, isTrue);
      expect(appearanceStyleFor('solid').usesImageBackground, isFalse);
    });

    test('无背景图时 effectiveImageBackground=false', () {
      final empty = AppPrefs();
      expect(
        appearanceStyleFor('image').effectiveImageBackground(empty),
        isFalse,
      );
      expect(
        appearanceStyleFor('solid').effectiveImageBackground(empty),
        isFalse,
      );

      final withImage = AppPrefs(
        initialData: {prefs.backgroundImageKey: '/tmp/background.png'},
      );
      expect(
        appearanceStyleFor('image').effectiveImageBackground(withImage),
        isTrue,
      );
      expect(
        appearanceStyleFor('solid').effectiveImageBackground(withImage),
        isFalse,
      );
    });
  });

  group('偏好白名单', () {
    test('非法 themeSource 读取回退 default，且不写入', () {
      final bad = AppPrefs(initialData: {prefs.themeSourceKey: 'nope'});
      expect(bad.themeSource, 'default');
      expect(bad.copyWithThemeSource('nope').themeSource, 'default');
      expect(bad.copyWithThemeSource('cover').themeSource, 'cover');
    });

    test('非法 appearanceStyle 读取回退 solid，且不写入', () {
      final bad = AppPrefs(initialData: {prefs.appearanceStyleKey: 'nope'});
      expect(bad.appearanceStyle, 'solid');
      expect(bad.copyWithAppearanceStyle('nope').appearanceStyle, 'solid');
      expect(bad.copyWithAppearanceStyle('image').appearanceStyle, 'image');
    });
  });
}

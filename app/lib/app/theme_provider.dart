// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/app_prefs.dart';

/// 主题模式（对照原项目 appearance.themeMode：light / dark / system）。
///
/// 持久化到 `app_prefs`（重启后保持）；`system` 由平台桥接推送的深浅色驱动
/// （见 `systemThemeProvider` 与 `app.dart` 的 effectiveThemeMode 解析）。
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final m = ref.watch(appPrefsProvider.select((p) => p.themeMode));
    return switch (m) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  /// 显式设置主题模式（设置弹窗三态选择）——写入偏好并落盘。
  void setMode(ThemeMode mode) {
    final v = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    };
    ref.read(appPrefsProvider.notifier).setThemeMode(v);
  }

  /// 循环切换 light → dark → system（对齐原项目 NavHeader 主题按钮）。
  void cycle() {
    final next = switch (state) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.light,
    };
    setMode(next);
  }
}

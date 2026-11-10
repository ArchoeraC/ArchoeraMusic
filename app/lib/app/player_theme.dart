// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器专用主题。
///
/// 播放页是全屏沉浸界面，背景恒为暗色体系（模糊封面 + 黑色压暗 / 深色纯色 /
/// 水纹 / 流体；主题渐变也用暗色底），前景（文字 / 图标 / 歌词 / 进度条）
/// 必须固定为亮色。若直接沿用应用当前主题，浅色模式下前景会跟着变成深色，
/// 压在暗背景上就成了「反色」——本 provider 固定用暗色主题隔离这一点。
///
/// 主色种子 / 字体 / 纯色来源 / 性能模式仍与应用设置保持一致；仅明暗方向
/// 固定为暗色。参考 SPlayer-Next 播放页用封面派生的固定亮色前景
/// （`text-cover`，不随全局明暗切换）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../theme/app_theme.dart';
import '../theme/cover_color.dart';
import '../theme/theme_sources/theme_source_registry.dart';
import '../theme/theme_sources/theme_source_style.dart';

/// 全屏播放器固定使用的暗色主题。
final playerThemeProvider = Provider<ThemeData>((ref) {
  final prefs = ref.watch(appPrefsProvider);
  // 主色种子与应用根主题同源（default/custom/cover/solid）。
  final coverAccent = ref.watch(coverColorProvider);
  final systemAccent = ref.watch(systemAccentProvider).value;
  final source = themeSourceStyleFor(prefs.themeSource);
  final accent = source.accentSeed(
    ThemeSourceContext(
      prefs: prefs,
      coverAccent: coverAccent,
      systemAccent: systemAccent,
    ),
  );
  return buildAppTheme(
    AppPalette.dark,
    Brightness.dark,
    accentSeed: accent,
    fontFamily: prefs.fontFamily,
    globalTint: prefs.globalTint,
    solid: source.solid,
    performanceMode: prefs.performanceMode,
  );
});

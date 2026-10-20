// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 外观风格契约。
///
/// 外观风格按模块拆分，通过注册表接入；新增风格不再修改 `shell.dart` 的
/// 判断与背景层实现。
library;

import 'package:material_ui/material_ui.dart';

import '../../stores/app_prefs.dart';

/// 一种外观风格（纯色 / 图片背景等）。
abstract class AppearanceStyle {
  const AppearanceStyle();

  /// 偏好里的稳定 id（须登记到 `prefs_appearance.dart` 的 `appearanceStyleIds`）。
  String get id;

  /// 该风格是否以图片作为背景（用于设置页显隐图片背景配置）。
  bool get usesImageBackground;

  /// 当前偏好下图片背景是否真正生效（如 image 风格但尚未选图 → false，
  /// 回退纯色观感；对齐原版 effectiveStyle）。
  bool effectiveImageBackground(AppPrefs prefs);

  /// 构建背景层；不需要背景层时返回 null。
  Widget? buildBackground(BuildContext context, AppPrefs prefs);
}

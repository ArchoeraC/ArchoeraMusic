// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 主题色来源样式契约与只读上下文。
///
/// 主题色来源按模块拆分，通过注册表接入；新增来源不再修改 `app.dart` 的
/// `switch` 分支。来源只负责回答「主色种子是什么 / 是否纯色 / 设置项怎么显隐」，
/// 具体调色算法仍由 `app_theme.dart` 统一实现。
library;

import 'package:material_ui/material_ui.dart';

import '../../stores/app_prefs.dart';

/// 解析主题色来源所需的只读快照。
class ThemeSourceContext {
  const ThemeSourceContext({
    required this.prefs,
    this.coverAccent,
    this.systemAccent,
  });

  /// 当前外观偏好（自定义主色等来源参数从这里读取）。
  final AppPrefs prefs;

  /// 当前封面提取色；未取到 / 非 cover 来源时为 null。
  final Color? coverAccent;

  /// 系统主题色；读取失败 / 非 default 来源时为 null。
  final Color? systemAccent;
}

/// 一种主题色来源。
abstract class ThemeSourceStyle {
  const ThemeSourceStyle();

  /// 偏好里的稳定 id（须登记到 `prefs_appearance.dart` 的 `themeSourceIds`）。
  String get id;

  /// 主色种子；null = 使用设计体系固定色板（非纯色来源也应回退默认亮蓝）。
  Color? accentSeed(ThemeSourceContext context);

  /// 是否使用纯色中性色板（无主题色，主/次色用灰阶）。
  bool get solid => false;

  /// 设置页是否显示「自定义主色」设置项。
  bool get allowsCustomAccent => false;

  /// 设置页是否显示「封面取色」说明；取色 provider 的启用条件之一。
  bool get usesCoverAccent => false;

  /// 是否以系统强调色作为主色种子（仅 default 来源需要订阅系统色事件）。
  bool get usesSystemAccent => false;
}

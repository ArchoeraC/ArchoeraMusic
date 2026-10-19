// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 封面切换动效契约与只读上下文。
///
/// 动效按模块拆分，通过注册表接入；新增动效不再修改
/// `cover_switcher.dart` 的分支。
library;

import 'package:material_ui/material_ui.dart';

/// 封面切换所需的只读快照。
class CoverTransitionContext {
  const CoverTransitionContext({
    required this.coverKey,
    required this.next,
    required this.child,
  });

  /// 封面身份（切歌即变化，触发切换动效）。
  final Object coverKey;

  /// 切歌方向（true = 下一首，新封面从右进；仅滑动类动效使用）。
  final bool next;

  /// 新封面内容。
  final Widget child;
}

/// 一种封面切换动效。
abstract class CoverTransition {
  const CoverTransition();

  /// 偏好里的稳定 id（须登记到 `transitionStyles`）。
  String get id;

  /// 构建切换包装；系统关闭动画时由实现直接换图。
  Widget build(BuildContext context, CoverTransitionContext c);
}

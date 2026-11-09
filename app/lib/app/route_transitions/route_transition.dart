// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 应用壳页面切换转场契约。
///
/// 转场按模块拆分，通过注册表接入；新增转场不再修改
/// `shell.dart` 的 `switch` 分支。
library;

import 'package:material_ui/material_ui.dart';

/// 内建转场统一时长（对齐原版进入动画 0.15s）。
const Duration routeTransitionDuration = Duration(milliseconds: 150);

/// 进入/退出曲线（对齐原版 route-fade/slide/zoom 的 ease-out / ease-in）。
const Curve routeTransitionCurve = Curves.easeOut;
const Curve routeTransitionReverseCurve = Curves.easeIn;

/// 按统一曲线包装分支动画控制器。
Animation<double> routeTransitionCurved(Animation<double> animation) =>
    CurvedAnimation(
      parent: animation,
      curve: routeTransitionCurve,
      reverseCurve: routeTransitionReverseCurve,
    );

/// 一种页面切换转场。
abstract class RouteTransition {
  const RouteTransition();

  /// 偏好里的稳定 id（须登记到 `prefs_appearance.dart` 的 `routeTransitionIds`）。
  String get id;

  /// 进入动画时长；无动效转场返回 [Duration.zero]。
  Duration get duration;

  /// 是否无动效（直接渲染 child，不驱动控制器）。
  bool get isNoop => false;

  /// 构建转场包装；[animation] 为分支控制器的原始进度。
  Widget build(BuildContext context, Animation<double> animation, Widget child);
}

/// 性能模式动效工具。
///
/// Flutter 3.44 的隐式 Animated* 组件不会自动读取
/// `MediaQuery.disableAnimations`（implicit_animations.dart 中
/// `controller.duration = widget.duration` 无条件赋值），需要显式把
/// duration 归零——本文件提供统一入口，所有 Animated* / 显式控制器
/// 站点共用同一判断。
library;

import 'package:flutter/widgets.dart';

/// 是否处于性能模式（`MediaQuery.disableAnimations`，由 app.dart 包裹）。
bool noAnim(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// 性能模式下动效时长归零，否则返回 [d]。
///
/// 隐式 Animated* 组件与显式 `AnimationController`/`ScrollController`
/// 的时长统一经此计算，保证性能模式全量直切。
Duration animDuration(
  BuildContext context, [
  Duration d = const Duration(milliseconds: 200),
]) =>
    noAnim(context) ? Duration.zero : d;

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 愚人节特供「整活模式」的跨层共享状态与滚动反向控制器（独立库）。
///
/// 独立成库的原因：进度条 / 播放控制 / 快捷键等**叶子组件**需要判断整活模式
/// 是否激活，但彩蛋主库（`easter_egg.dart`）会拉入 PlaybackNotifier / 弹窗 /
/// 控件等重依赖，直接 import 易造成循环依赖。与 [easterEggDodge]
/// （`easter_egg_visual_state.dart`）同款策略：把裸 [ValueNotifier] 与滚动
/// 反向控制器放在本文件，双方各自 import。
library;

import 'package:material_ui/material_ui.dart';

/// 整活模式是否激活的全局开关。
///
/// 用裸 [ValueNotifier]（不依赖 `ProviderScope`）：叶子组件（如
/// `PlaybackSlider`）可能在无 Riverpod 容器的测试场景被渲染，用 ValueNotifier
/// 不会有 `No ProviderScope found` 风险。由根 [AprilFoolsHost] 负责同步。
final ValueNotifier<bool> aprilFoolsActiveNotifier = ValueNotifier<bool>(false);

/// 触发/投降语义的纯函数（便于确定性单测，不依赖时钟 / 偏好 / 环境）。
///
/// - [safeMode]（`ARCHOERA_EGG_SAFE=1`）时整活模式整体禁用，恒 false；
/// - [force] 为环境覆盖（`ARCHOERA_EGG_FOOL=1` → true / `=0` → false）：
///   非 null 时优先于日期、开关与持久化状态（便于调试）；
/// - [enabled] 为用户开关（设置页「愚人节整活」）；关闭后永不自动激活；
/// - [active] 已激活时「重申」激活（跨重启保留，直到投降）；
/// - 否则仅在 4 月 1 日且当年未投降时激活。
bool shouldAutoActivate({
  required DateTime now,
  required bool active,
  required int? surrenderedYear,
  required bool safeMode,
  required bool? force,
  bool enabled = true,
}) {
  if (safeMode || force == false) return false;
  if (force == true) return true;
  if (!enabled) return false;
  if (active) return true;
  return now.month == 4 && now.day == 1 && surrenderedYear != now.year;
}

/// 滚轮反向的 [ScrollController]。
///
/// 配合根 `AprilFoolsHost` 安装的 `PrimaryScrollController`，对**未显式传入
/// controller** 的纵向 ScrollView 生效（显式 controller 的少数滚动视图
/// 不受影响）。复写 [createScrollPosition] 以产出 [PrankScrollPosition]。
///
/// 注：Navigator 的每个路由都会注入自己的 `PrimaryScrollController`，在桌面上
/// 会遮蔽外层控制器，故应用内实际的反向由宿主顶层的
/// `_AprilFoolsWheelInverter` 兜底；本控制器保留为规范机制与单测覆盖。
class PrankScrollController extends ScrollController {
  PrankScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return PrankScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      oldPosition: oldPosition,
      keepScrollOffset: keepScrollOffset,
    );
  }
}

/// 把滚轮 delta 取反的滚动位置（视觉与手感「倒放」，但滚动范围不变）。
class PrankScrollPosition extends ScrollPositionWithSingleContext {
  PrankScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.oldPosition,
    super.keepScrollOffset,
  });

  @override
  void pointerScroll(double delta) => super.pointerScroll(-delta);
}

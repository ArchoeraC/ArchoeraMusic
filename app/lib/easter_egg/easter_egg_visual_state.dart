// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 彩蛋全局视觉状态（独立库）。
///
/// 独立成库的原因：组件躲避（MouseDodge）会被通用组件（SButton / SettingTile
/// 等）引用，而这些组件不能依赖彩蛋主库（会造成循环 import）。故把「状态 +
/// Provider + 组件躲避开关」放在本文件，双方各自 import。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 彩蛋的全局视觉状态（缩放、左右镜像、颜色反转、内容位移）。
///
/// 用 Riverpod 承载；只在根部 [EasterEggVisualHost] 消费，因此这些属性可以
/// 放心依赖 `ProviderScope`（根 UI 一定在 ProviderScope 之下）。
class EasterEggVisual {
  const EasterEggVisual({
    this.zoom = 1.0,
    this.mirror = false,
    this.invert = false,
    this.contentShift = Offset.zero,
  });

  /// 整体缩放倍数（#3 放大至 800% 时为 8.0）。
  final double zoom;

  /// 左右镜像（#7；视觉翻转但命中测试不变）。
  final bool mirror;

  /// 颜色反转（#10）。
  final bool invert;

  /// 内容位移（#8 在 Wayland 下的「滚动」回退）。
  final Offset contentShift;

  static const EasterEggVisual idle = EasterEggVisual();

  EasterEggVisual copyWith({
    double? zoom,
    bool? mirror,
    bool? invert,
    Offset? contentShift,
  }) {
    return EasterEggVisual(
      zoom: zoom ?? this.zoom,
      mirror: mirror ?? this.mirror,
      invert: invert ?? this.invert,
      contentShift: contentShift ?? this.contentShift,
    );
  }
}

final easterEggVisualProvider =
    NotifierProvider<EasterEggVisualNotifier, EasterEggVisual>(
      EasterEggVisualNotifier.new,
    );

class EasterEggVisualNotifier extends Notifier<EasterEggVisual> {
  @override
  EasterEggVisual build() => EasterEggVisual.idle;

  void setZoom(double zoom) => state = state.copyWith(zoom: zoom);
  void setMirror(bool mirror) => state = state.copyWith(mirror: mirror);
  void setInvert(bool invert) => state = state.copyWith(invert: invert);
  void setContentShift(Offset shift) =>
      state = state.copyWith(contentShift: shift);
}

/// #6「所有组件躲避鼠标」的全局开关。
///
/// 用裸 [ValueNotifier] 而非 Riverpod：组件躲避的包装（MouseDodge）会挂到
/// 通用组件上，那些组件可能在无 `ProviderScope` 的场景（如某些 widget 测试）
/// 被渲染，用 ValueNotifier 不会有 `No ProviderScope found` 风险。
final ValueNotifier<bool> easterEggDodge = ValueNotifier<bool>(false);

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放进度条：默认简化细条，悬停展开完整 Slider；buffering 时叠加
/// 「缓冲流动」动效。
///
/// 交互：简化细条状态即可直接点按/水平拖动 seek（鼠标与触摸通用，映射
/// 几何与完整 Slider 一致）；鼠标进入细条后再切换为完整 [Slider]
/// （可拖动 seek，对齐常见桌面播放器「悬停展开」）。触摸没有 hover 事件、
/// 够不到悬停展开的 Slider，因此 seek 走细条直拖路径；直拖期间保持细条
/// 不切回 Slider，避免手势识别器中途被销毁。
/// 缓冲态：轨道位置叠一层 Material 的 LinearProgressIndicator（自带动画，
/// 主色片段往返流动，透明背景）；此时播放进度样式降为半透明，避免
/// 实心进度条盖住流动动画。交互不拦截（IgnorePointer），缓冲中仍可拖动。
///
/// 轨道对齐：简化条/缓冲层/完整 Slider 共用同一轨道矩形
/// （[SliderThemeData.trackShape] 的几何），保证悬停切换时轨道位置
/// 不跳变；不硬编码留白，避免与实际 Slider 轨道错位。
///
/// 布局注意：外层 SizedBox(height: 48) 锁定高度——Slider 须作为**非定位**
/// 子元素决定 Stack 尺寸；若全部子元素都是 Positioned，Stack 会取
/// constraints.biggest 撑满可用区域（如 Column 剩余高度），把播放页
/// 主体/控制区挤出屏幕。
library;

import 'package:flutter/material.dart';

part 'playback_slider/playback_slider_state.dart';

class PlaybackSlider extends StatefulWidget {
  const PlaybackSlider({
    super.key,
    required this.value,
    required this.max,
    required this.buffering,
    this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double max;

  /// 缓冲中：轨道叠加流动指示条（进度样式自动降透明）。
  final bool buffering;

  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<PlaybackSlider> createState() => _PlaybackSliderState();
}

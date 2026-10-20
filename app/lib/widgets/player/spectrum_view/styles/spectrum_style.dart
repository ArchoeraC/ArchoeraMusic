// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱渲染样式契约与只读绘制上下文。
///
/// 样式按模块拆分，通过注册表接入；新增样式不再修改
/// `spectrum_view_painter.dart` 的渲染分支。
library;

import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

/// 一帧频谱绘制所需的只读快照。
class SpectrumPaintContext {
  const SpectrumPaintContext({
    required this.stereo,
    required this.usableLen,
    required this.barWidth,
    required this.radius,
    required this.color,
  });

  /// 双声道拼接后的频谱（左声道倒序 + 右声道正序）。
  final Float64List stereo;

  /// [stereo] 中有效 bin 数。
  final int usableLen;

  /// 单根 bar 宽度（px）；波形样式复用为 stroke 宽度基准。
  final double barWidth;

  /// bar 圆角（px）。
  final double radius;

  /// 绘制颜色（含整体不透明度）。
  final Color color;
}

/// 一种频谱可视化样式。
abstract class SpectrumStyleRenderer {
  const SpectrumStyleRenderer();

  /// 偏好里的稳定 id（须登记到 `spectrumStyles`）。
  String get id;

  /// 在 [canvas] 上绘制一帧频谱。
  void paint(Canvas canvas, Size size, SpectrumPaintContext c);
}

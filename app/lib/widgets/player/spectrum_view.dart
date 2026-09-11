// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../common/anim.dart';

part 'spectrum_view/spectrum_view_state.dart';
part 'spectrum_view/spectrum_view_painter.dart';

/// 频谱可视化样式（独立渲染效果，复用同一 FFT 数据缓冲，资源开销等同）。
enum SpectrumStyle {
  /// 经典条形：双声道镜像、底部对齐、圆角柱（原版默认）。
  bars,

  /// 波形线：镜像对称的频谱包络曲线，形似声波。
  wave,

  /// 单向上波形：包络曲线只向基线一侧（上）延伸，无镜像。
  waveUp;

  /// 偏好存储值（player.spectrumStyle）。
  String get storageKey => name;

  /// 从偏好字符串解析（非法值回退 bars）。
  static SpectrumStyle fromStorage(String? value) => SpectrumStyle.values
      .firstWhere((e) => e.name == value, orElse: () => SpectrumStyle.bars);
}

/// 频谱可视化（复刻 Web 端 BottomSpectrum.vue，架构文档 §10.1）。
///
/// 链路：引擎直写 stream.pcm → PcmAnalyzer 按播放位置拉块 → FFI FFT →
/// PlaybackState.fft（128 bins [0,1]）→ 此处插值渲染。
///
/// 渲染语义（与 Vue 版逐项对齐）：
///  - 帧间时间插值（50ms 推送 → ~16ms 重绘，消除 20Hz 阶梯）
///  - 上行快 / 下行慢（ATTACK 0.4 / DECAY 0.88）
///  - 双声道拼接：左声道倒序 + 右声道正序（SKIP_LOW 起，镜像对称）
///  - 每个 bar 覆盖一段 bin 并左右各扩 1 邻居做空间平滑
///  - bar 圆角 + 底部对齐
class SpectrumView extends ConsumerStatefulWidget {
  const SpectrumView({
    super.key,
    this.height = 80,
    this.barWidth,
    this.radius = 2,
    this.color,
    this.opacity = 0.65,
    this.enabled,
    this.style,
  });

  /// 画布高度（逻辑像素）。
  final double height;

  /// 单根 bar 宽度（px）；null 时跟随设置（player.spectrumBarWidth）。
  final double? barWidth;

  /// bar 圆角（px）。
  final double radius;

  /// bar 颜色；默认跟随主题 primary。
  final Color? color;

  /// 整体不透明度（对齐原版 BottomSpectrum：播放器内 0.65 / 迷你条 0.15，
  /// 300ms 过渡）。
  final double opacity;

  /// 独立启用开关（null = 跟随全局「频谱」设置；播放条迷你频谱传
  /// `player.barSpectrum` 与该全局开关解耦）。
  final bool? enabled;

  /// 频谱样式；null 时跟随设置（player.spectrumStyle）。
  final SpectrumStyle? style;

  @override
  ConsumerState<SpectrumView> createState() => _SpectrumViewState();
}

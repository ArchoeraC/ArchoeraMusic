// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词区上下渐隐。
///
/// 渐变设计（对齐 SPlayer 的 `mask-image` 语义）：
/// ```
///   0        100%
///   顶部 10% 淡入 → 中部完全不透明 → 底部 25% 淡出
/// ```
/// 顶部只用 10% 完成淡入、底部 25% 淡出，中间大段保持完全不透明；比
/// 「上下各 25% 线性渐变」更干净，不会让歌词整体发灰。
///
/// 实现有两种（[LyricsEdgeFadeMode]，环境变量 `ARCHOERA_LYRICS_FADE` 选择）：
/// 物理墙逐行 alpha（默认，零离屏层）或外层 [ShaderMask]（dstIn，回退对比用）。
///
/// ⚠ 不要再用「RepaintBoundary + dstOut 叠加」：2026-11-03 曾尝试免每帧
/// 离屏层（软件光栅下逐像素等价、测试通过），但真机上 dstOut 未被边界隔离，
/// 把歌词列下层的页面背景擦成了深色块——已回退。
library;

import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

/// 歌词区上下渐隐的实现方式（见 [lyricsEdgeFadeMode]）。
enum LyricsEdgeFadeMode {
  /// 外层 `ShaderMask`（dstIn）——任意子树都正确，但每帧一次**面积级离屏层**
  /// （全屏时面积大，成本明显）。全屏卡顿时可用来回退对比。
  shader,

  /// **默认**：逐行 alpha：把渐隐直接乘进每行绘制时的透明度，**零离屏层**。
  ///
  /// 逐行取「行中心」处的渐隐值，因此是阶梯式淡出（不是逐像素渐变）；
  /// 与 `ShaderMask` 逐像素实测最大差 9/255（`test/lyrics_edge_fade_test.dart`），
  /// 观感差异集中在最上/最下 1~2 行且不可辨。仅物理歌词墙支持
  /// （`AmllPhysicsWall.edgeFade`）。
  wall,

  /// 不做渐隐（诊断用，观感会露出硬边）。
  off,
}

/// 未指定 `ARCHOERA_LYRICS_FADE` 时的默认实现。
const LyricsEdgeFadeMode defaultLyricsEdgeFadeMode = LyricsEdgeFadeMode.wall;

/// 解析设置值 / 环境变量 `ARCHOERA_LYRICS_FADE`（`shader` | `wall` | `off`）。
///
/// 设置页「性能 / 渲染 → 歌词边缘渐隐」存的是同一套字符串；环境变量只用于
/// 现场 A/B（不改设置、不重编译即可对比帧时间与观感）。
LyricsEdgeFadeMode lyricsEdgeFadeModeFrom(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'wall':
    case 'inline':
    case 'perline':
      return LyricsEdgeFadeMode.wall;
    case 'shader':
    case 'mask':
      return LyricsEdgeFadeMode.shader;
    case 'off':
    case 'none':
    case '0':
      return LyricsEdgeFadeMode.off;
    default:
      return defaultLyricsEdgeFadeMode;
  }
}

/// 进程级环境变量覆盖（诊断用，优先级高于设置页偏好）；未设置时为 null。
final LyricsEdgeFadeMode? lyricsEdgeFadeEnvOverride = _parseEdgeFadeEnv(
  Platform.environment['ARCHOERA_LYRICS_FADE'],
);

LyricsEdgeFadeMode? _parseEdgeFadeEnv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return lyricsEdgeFadeModeFrom(raw);
}

/// 生效实现：环境变量 > 设置页偏好（`render.lyricsEdgeFade`）> 默认。
///
/// [pref] 是设置页「性能 / 渲染 → 歌词边缘渐隐」的值（`wall` / `shader` /
/// `off`）；空或非法值走 [defaultLyricsEdgeFadeMode]。
LyricsEdgeFadeMode resolveLyricsEdgeFadeMode(String? pref) =>
    lyricsEdgeFadeEnvOverride ?? lyricsEdgeFadeModeFrom(pref);

/// 渐隐曲线在归一化位置 `t`（0 = 顶部，1 = 底部）处的保留量。
///
/// 与 [LyricsEdgeFade] 的渐变停点完全一致：顶部 10% 淡入、底部 25% 淡出、
/// 中段完全不透明。纯函数，便于单测与逐行模式复用。
double lyricsEdgeFadeAt(double t) {
  const stops = [0.0, 0.05, 0.10, 0.75, 0.85, 1.0];
  const alphas = [0.0, 0.6, 1.0, 1.0, 0.6, 0.0];
  final x = t.clamp(0.0, 1.0);
  for (var i = 1; i < stops.length; i++) {
    if (x <= stops[i]) {
      final span = stops[i] - stops[i - 1];
      if (span <= 0) return alphas[i];
      final f = (x - stops[i - 1]) / span;
      return alphas[i - 1] + (alphas[i] - alphas[i - 1]) * f;
    }
  }
  return 0;
}

/// 歌词区上下渐隐（见库注释）。
class LyricsEdgeFade extends StatelessWidget {
  const LyricsEdgeFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0x00FFFFFF),
          Color(0x99FFFFFF), // 60%
          Color(0xFFFFFFFF),
          Color(0xFFFFFFFF),
          Color(0x99FFFFFF), // 60%
          Color(0x00FFFFFF),
        ],
        stops: [0, 0.05, 0.10, 0.75, 0.85, 1.0],
      ).createShader(rect),
      child: child,
    );
  }
}

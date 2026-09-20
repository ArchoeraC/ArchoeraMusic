// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 间奏（长空隙）识别与三点动画（对齐 AMLL interlude-dots）。
///
/// - 两行之间「上一行真实唱完 → 下一行开始」的空隙达到
///   [kMinInterludeGapMs]（7s）即视为间奏；
/// - 间奏期间不再高亮任何歌词行，改为在空隙处播放三点依次点亮 + 呼吸
///   缩放 + 两段式退场的动画。
///
/// 纯 Dart（无 Flutter 依赖），动画曲线来自 `curves.dart`，可单测。
library;

import 'dart:math' as math;

import '../../../services/lyrics/lyric_line.dart';
import 'curves.dart';

/// 判定为间奏的最小空隙（毫秒，对齐 AMLL `MIN_INTERLUDE_GAP`）。
const int kMinInterludeGapMs = 7000;

/// 一段间奏（长空隙）。
class LyricInterlude {
  const LyricInterlude({
    required this.startMs,
    required this.endMs,
    required this.anchorIndex,
  });

  /// 空隙起点（上一行真实唱完的时间）。
  final int startMs;

  /// 空隙终点（下一行起始时间）。
  final int endMs;

  /// 空隙前最后一行的索引（-1 = 位于首行之前，如超长前奏）。
  final int anchorIndex;
}

/// 识别全部间奏。
///
/// 结束时间取「逐字片段的真实结束时间」优先（YRC/KRC/QRC 有字级时间轴），
/// 否则退回 [LyricGroup.endMs]（普通 LRC 的下一行起始，此时两行之间不存在
/// 可识别的空隙——与 AMLL 一致）。
List<LyricInterlude> computeInterludes(List<LyricGroup> groups) {
  final out = <LyricInterlude>[];
  if (groups.isEmpty) return out;
  var maxEnd = 0;
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    final start = g.original.timeMs;
    if (start - maxEnd >= kMinInterludeGapMs) {
      out.add(
        LyricInterlude(
          startMs: maxEnd,
          endMs: start,
          anchorIndex: i - 1,
        ),
      );
    }
    final end = _realEnd(g);
    if (end > maxEnd) maxEnd = end;
  }
  return out;
}

int _realEnd(LyricGroup g) {
  final start = g.original.timeMs;
  var end = g.endMs ?? start;
  if (end < start) end = start;
  final frags = g.fragments;
  if (frags != null) {
    for (final f in frags) {
      final d = f.durationMs ?? 0;
      if (d <= 0) continue;
      final e = start + f.startMs + d;
      if (e > end) end = e;
    }
  }
  return end;
}

/// 间奏三点的当帧状态。
class InterludeDotsState {
  const InterludeDotsState({
    required this.visible,
    required this.opacity,
    required this.scale,
    required this.dots,
  });

  final bool visible;

  /// 整个三点元素的透明度。
  final double opacity;

  /// 呼吸缩放。
  final double scale;

  /// 每个点的亮度（0~1，已含 0.2 基线）。
  final List<double> dots;

  static const InterludeDotsState hidden = InterludeDotsState(
    visible: false,
    opacity: 0,
    scale: 1,
    dots: [0, 0, 0],
  );
}

// 动画常量（对齐 AMLL interlude-dots）。
const int _enterFadeMs = 180;
const int _exitTotalMs = 1000;
const int _exitPhase1Ms = 750;
const int _exitFadeMs = 250;
const int _dotEnterFadeMs = 750;
const int _dotEnterStaggerMs = 80;
const int _dotEnterTotalMs = (_dotEnterFadeMs) + 2 * _dotEnterStaggerMs;
const int _breatheBasePeriodMs = 4000;
const double _exitMaxScale = 1.25;
const double _exitMinScale = 0.4;
const double _breatheMaxScale = 1.25;
const double _dotInactiveAlpha = 0.2;
const double _dotActiveAlpha = 0.9;

double _enterFadeEasing(double t) => cubicBezier(t, 0.59, 0.02, 0.07, 1);
double _lightingEasing(double t) => cubicBezier(t, 0.56, 0.01, 0.45, 1);
double _exitFadeEasing(double t) => cubicBezier(t, 0.43, 0.08, 0.83, 0.31);

/// 呼吸进度（AMLL 用一组正弦叠加以获得非匀速的“呼吸”手感）。
double breathingProgress(double t) {
  final angle = 4 * math.pi * t;
  final s = math.sin(angle);
  final c = math.cos(angle);
  return t - 0.084 * s + 0.008 * (1 - c) + 0.0046 * s * (c - s);
}

/// 解析间奏三点的当帧状态。
///
/// [nowMs] 位于 [startMs, endMs) 之外时返回 [InterludeDotsState.hidden]。
InterludeDotsState resolveInterludeDots({
  required int startMs,
  required int endMs,
  required int nowMs,
}) {
  final total = endMs - startMs;
  if (total < kMinInterludeGapMs) return InterludeDotsState.hidden;
  final elapsed = nowMs - startMs;
  if (elapsed < 0 || elapsed >= total) return InterludeDotsState.hidden;

  final body = total - _exitTotalMs;
  // 身体段太短（放不下入场 + 三点点亮）就不显示，避免一闪而过。
  if (body < _dotEnterTotalMs) return InterludeDotsState.hidden;

  final inExit = elapsed >= body;
  final internal = inExit ? body : elapsed;
  final exitElapsed = elapsed - body;

  // 整体透明度：入场淡入 + 退场淡出。
  var opacity = _enterFadeEasing((internal / _enterFadeMs).clamp(0.0, 1.0));
  if (inExit) {
    final fadeT = ((exitElapsed - (_exitTotalMs - _exitFadeMs)) / _exitFadeMs)
        .clamp(0.0, 1.0);
    opacity *= 1 - _exitFadeEasing(fadeT);
  }

  // 缩放：呼吸（入场后）或退场的两段式（先胀后缩）。
  double scale = 1;
  if (inExit) {
    if (exitElapsed < _exitPhase1Ms) {
      scale = 1 + (_exitMaxScale - 1) * (exitElapsed / _exitPhase1Ms);
    } else {
      final t = ((exitElapsed - _exitPhase1Ms) /
              (_exitTotalMs - _exitPhase1Ms))
          .clamp(0.0, 1.0);
      scale = _exitMaxScale - (_exitMaxScale - _exitMinScale) * t;
    }
  } else {
    final cycles = math.max(1, (body / _breatheBasePeriodMs).floor());
    final period = body / cycles;
    final p = breathingProgress((elapsed % period) / period);
    scale = p <= 0.5
        ? 1 + (p / 0.5) * (_breatheMaxScale - 1)
        : _breatheMaxScale - ((p - 0.5) / 0.5) * (_breatheMaxScale - 1);
  }

  // 三个点依次点亮：第 3 点在最长的尾段完成。
  final segmentMs = (body + _dotEnterFadeMs) / 3;
  final dot3DurationMs = math.max(1.0, body - segmentMs * 2);
  final dots = <double>[
    _dotAt(elapsed, 0, 0.0, segmentMs, 1.0),
    _dotAt(elapsed, 1, segmentMs, segmentMs, 1.0),
    _dotAt(elapsed, 2, segmentMs * 2, dot3DurationMs, 1.0),
  ];
  if (inExit) {
    // 退场时第 3 点补齐（对齐 AMLL：退场段继续点亮第 3 点）。
    final t = (exitElapsed / _exitPhase1Ms).clamp(0.0, 1.0);
    final frac = _lightingEasing(t);
    dots[2] =
        _dotInactiveAlpha + (_dotActiveAlpha - _dotInactiveAlpha) * frac;
    for (var i = 0; i < 3; i++) {
      dots[i] = math.max(
        dots[i],
        _dotInactiveAlpha +
            (_dotActiveAlpha - _dotInactiveAlpha) * (i == 2 ? frac : 1),
      );
    }
  }

  return InterludeDotsState(
    visible: true,
    opacity: opacity.clamp(0.0, 1.0),
    scale: scale,
    dots: dots,
  );
}

/// 第 [index] 个点的亮度：点亮进度 × 错峰入场透明度。
double _dotAt(
  int elapsed,
  int index,
  double startDelay,
  double duration,
  double target,
) {
  if (duration <= 0) duration = 1;
  final enter = ((elapsed - startDelay) / duration).clamp(0.0, 1.0);
  final frac = _lightingEasing(enter) * target;
  final a = _dotInactiveAlpha + (_dotActiveAlpha - _dotInactiveAlpha) * frac;
  // 逐点错峰淡入（每点滞后 80ms、750ms 淡入）
  final enterAlpha = _pow2(
    ((elapsed - index * _dotEnterStaggerMs) / _dotEnterFadeMs).clamp(0.0, 1.0),
  );
  return a * enterAlpha;
}

double _pow2(double x) => x * x;

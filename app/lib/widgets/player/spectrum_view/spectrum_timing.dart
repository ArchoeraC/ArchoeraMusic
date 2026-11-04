// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱渲染的时间学（纯函数，便于单测）。
///
/// 数据帧由引擎位置事件驱动，实际间隔随档位变化（前台 50ms / 节能 300ms /
/// 失焦 1000ms）。插值进度与攻/放系数必须按「实测间隔」和「帧时长」归一化，
/// 否则会出现前段插值、后段停住，或高刷屏衰减过快。
library;

import 'dart:math' as math;

/// 60fps 的帧时长（ms），攻/放系数的归一化基准。
const double spectrumFrameMs = 1000 / 60;

/// 默认数据帧间隔（ms）。
const double spectrumDefaultIntervalMs = 50;

/// 可接受的最小/最大帧间隔（ms）。
const double spectrumMinIntervalMs = 16;
const double spectrumMaxIntervalMs = 2000;

/// 更新帧间隔估计。
///
/// [configuredMs] 是生产端下发的目标间隔（[FftFrame.intervalMs]），作为
/// 锚点；[measuredMs] 是渲染端实际观测到的到达间隔，仅用于吸收小幅投递
/// 抖动。档位切换（当前估计与目标差距 >50%）或实测明显偏离目标（>1.5× /
/// <0.67×，掉帧/异常投递）时直接跟随目标，避免插值窗口被单帧拖坏。
double updateSpectrumInterval(
  double current,
  int measuredMs, {
  double configuredMs = spectrumDefaultIntervalMs,
}) {
  final target = configuredMs
      .clamp(spectrumMinIntervalMs, spectrumMaxIntervalMs)
      .toDouble();
  if (measuredMs <= 0 || measuredMs > spectrumMaxIntervalMs) return target;
  if (current <= 0) return target;
  if ((current - target).abs() > target * 0.5) return target;
  final measured = measuredMs.toDouble();
  if (measured > target * 1.5 || measured < target * 0.67) return target;
  return current + (measured - current) * 0.5;
}

/// 帧间插值进度 [0,1]：按实测间隔把上一帧平滑过渡到当前帧。
double spectrumInterpolationProgress(
  int nowMs,
  int lastUpdateMs,
  double intervalMs,
) {
  if (intervalMs <= 0) return 1;
  return ((nowMs - lastUpdateMs) / intervalMs).clamp(0.0, 1.0);
}

/// 上行（attack）系数：以 60fps 的 [attack] 为基准，按 [dtMs] 归一化。
///
/// 高刷屏下每帧的 dt 更小，系数随之变小；掉帧/降档时 dt 变大，系数随之
/// 变大——观感与刷新率、重绘步长解耦。
double spectrumAttackFactor(double dtMs, {double attack = 0.4}) {
  if (dtMs <= 0) return 0;
  final steps = (dtMs / spectrumFrameMs).clamp(0.25, 4.0);
  return (1 - math.pow(1 - attack, steps)).toDouble().clamp(0.0, 1.0);
}

/// 下行（decay）系数：以 60fps 的 [decay] 为基准，按 [dtMs] 归一化。
double spectrumDecayFactor(double dtMs, {double decay = 0.88}) {
  if (dtMs <= 0) return 1;
  final steps = (dtMs / spectrumFrameMs).clamp(0.25, 4.0);
  return math.pow(decay, steps).toDouble().clamp(0.0, 1.0);
}

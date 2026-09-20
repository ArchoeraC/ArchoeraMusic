// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词引擎用到的缓动曲线（对齐 AMLL 的手搓 `cubic-bezier` 常量）。
///
/// 纯 Dart，无 Flutter 依赖，可单测。
library;

/// 三次贝塞尔缓动：给定控制点 (x1,y1)/(x2,y2)，返回 y(x)。
///
/// 与 CSS `cubic-bezier(x1,y1,x2,y2)` 同义（P0=(0,0)、P3=(1,1)）。
double cubicBezier(double x, double x1, double y1, double x2, double y2) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  // 以牛顿迭代求 t 使 Bx(t) == x，退化时用二分兜底。
  var t = x;
  for (var i = 0; i < 12; i++) {
    final err = _bx(t, x1, x2) - x;
    if (err.abs() < 1e-5) break;
    final d = _bxd(t, x1, x2);
    if (d.abs() < 1e-6) break;
    t = (t - err / d).clamp(0.0, 1.0);
  }
  return _by(t, y1, y2);
}

double _bx(double t, double x1, double x2) =>
    3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t;

double _bxd(double t, double x1, double x2) =>
    3 * (1 - t) * (1 - t) * x1 +
    6 * (1 - t) * t * (x2 - x1) +
    3 * t * t * (1 - x2);

double _by(double t, double y1, double y2) =>
    3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t;

/// 强调动画缓动（对齐 AMLL `empEasing`）。
///
/// 形状是 **0 → 1 → 0 的脉冲**：x=0 与 x=1 处为 0，x=0.5 处为峰值 1
/// （前半段 `bezIn`、后半段 `1 - bezOut`）。强调的辉光/缩放/位移因此是
/// 「亮起又收回」的一次脉动，而不是常驻高亮。
double empathEasing(double x) {
  const mid = 0.5;
  if (x < mid) return cubicBezier(x / mid, 0.2, 0.4, 0.58, 1.0);
  return 1 - cubicBezier((x - mid) / (1 - mid), 0.3, 0.0, 0.58, 1.0);
}

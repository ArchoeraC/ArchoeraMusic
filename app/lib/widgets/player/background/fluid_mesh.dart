// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体背景的**控制点网格**：上游 AMLL `MeshGradientRenderer` 的 5 组预设、
/// 随机控制点生成（`cp-generate`）、双三次 Hermite 求值与「一次性位移贴图烘焙」。
///
/// 上游每首歌新建一个 `BHPMesh`（随机 preset + subdiv=50），在 WebGL 顶点阶段
/// 做 Hermite 形变。本实现把该形变**前向栅格化**进一张 RG 位移贴图（texel 的
/// 位置 = 未 aspect 校正的 NDC `pos`，颜色 = 纹理坐标 `v_uv`），片元着色器
/// （`shaders/fluid.frag`）只做逆 aspect → 查表 → 旋转/缩放。
///
/// 这样每首歌只烘焙一次；窗口缩放不需重烘焙（aspect 在片元里补偿）。
library;

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 位移贴图默认分辨率（正方形，边长像素）。
const int kFluidWarpResolution = 256;

/// 网格细分级别（对齐上游 `resetSubdivition(50)`）。
const int kFluidSubdiv = 50;

/// 单个控制点（位置 + u/v 切线，切线已含角度与缩放）。
class FluidControlPoint {
  const FluidControlPoint({
    required this.x,
    required this.y,
    required this.ux,
    required this.uy,
    required this.vx,
    required this.vy,
  });

  final double x;
  final double y;
  final double ux;
  final double uy;
  final double vx;
  final double vy;
}

/// 控制点预设（上游 `ControlPointConf` 语义：角度为度、缩放为倍数）。
class FluidControlPointPreset {
  FluidControlPointPreset(this.width, this.height, this.conf);

  final int width;
  final int height;
  final List<FluidControlPointConf> conf;
}

/// 预设里的单条控制点配置。
class FluidControlPointConf {
  FluidControlPointConf(
    this.cx,
    this.cy,
    this.x,
    this.y, [
    this.ur = 0,
    this.vr = 0,
    this.up = 1,
    this.vp = 1,
  ]);

  final int cx;
  final int cy;
  final double x;
  final double y;

  /// u/v 切线角度（度）。
  final double ur;
  final double vr;

  /// u/v 切线缩放倍数。
  final double up;
  final double vp;
}

FluidControlPointConf _p(
  int cx,
  int cy,
  double x,
  double y, [
  double ur = 0,
  double vr = 0,
  double up = 1,
  double vp = 1,
]) => FluidControlPointConf(cx, cy, x, y, ur, vr, up, vp);

/// 上游 `CONTROL_POINT_PRESETS`（逐一照搬，勿改数值）。
final List<FluidControlPointPreset> kFluidControlPointPresets = [
  FluidControlPointPreset(5, 5, [
    _p(0, 0, -1, -1, 0, 0, 1, 1),
    _p(1, 0, -0.5, -1, 0, 0, 1, 1),
    _p(2, 0, 0, -1, 0, 0, 1, 1),
    _p(3, 0, 0.5, -1, 0, 0, 1, 1),
    _p(4, 0, 1, -1, 0, 0, 1, 1),
    _p(0, 1, -1, -0.5, 0, 0, 1, 1),
    _p(1, 1, -0.5, -0.5, 0, 0, 1, 1),
    _p(2, 1, -0.0052029684413368305, -0.6131420587090777, 0, 0, 1, 1),
    _p(3, 1, 0.5884227308309977, -0.3990805107556692, 0, 0, 1, 1),
    _p(4, 1, 1, -0.5, 0, 0, 1, 1),
    _p(0, 2, -1, 0, 0, 0, 1, 1),
    _p(1, 2, -0.4210024670505933, -0.11895058380429502, 0, 0, 1, 1),
    _p(2, 2, -0.1019613423315412, -0.023812118047224606, 0, -47, 0.629, 0.849),
    _p(3, 2, 0.40275125660925437, -0.06345314544600389, 0, 0, 1, 1),
    _p(4, 2, 1, 0, 0, 0, 1, 1),
    _p(0, 3, -1, 0.5, 0, 0, 1, 1),
    _p(1, 3, 0.06801958477287173, 0.5205913248960121, -31, -45, 1, 1),
    _p(2, 3, 0.21446469120128908, 0.29331610114301043, 6, -56, 0.566, 1.321),
    _p(3, 3, 0.5, 0.5, 0, 0, 1, 1),
    _p(4, 3, 1, 0.5, 0, 0, 1, 1),
    _p(0, 4, -1, 1, 0, 0, 1, 1),
    _p(1, 4, -0.31378372841550195, 1, 0, 0, 1, 1),
    _p(2, 4, 0.26153633255328046, 1, 0, 0, 1, 1),
    _p(3, 4, 0.5, 1, 0, 0, 1, 1),
    _p(4, 4, 1, 1, 0, 0, 1, 1),
  ]),
  FluidControlPointPreset(4, 4, [
    _p(0, 0, -1, -1, 0, 0, 1, 1),
    _p(1, 0, -0.33333333333333337, -1, 0, 0, 1, 1),
    _p(2, 0, 0.33333333333333326, -1, 0, 0, 1, 1),
    _p(3, 0, 1, -1, 0, 0, 1, 1),
    _p(0, 1, -1, -0.04495399932657351, 0, 0, 1, 1),
    _p(1, 1, -0.24056117520129328, -0.22465999020104, 0, 0, 1, 1),
    _p(2, 1, 0.334758885767489, -0.00531297192779423, 0, 0, 1, 1),
    _p(3, 1, 0.9989920470678106, -0.3382976020775408, 8, 0, 0.566, 1.792),
    _p(0, 2, -1, 0.33333333333333326, 0, 0, 1, 1),
    _p(1, 2, -0.3425497314639411, -0.000027501607956947893, 0, 0, 1, 1),
    _p(2, 2, 0.3321437945812673, 0.1981776353859399, 0, 0, 1, 1),
    _p(3, 2, 1, 0.0766118180296832, 0, 0, 1, 1),
    _p(0, 3, -1, 1, 0, 0, 1, 1),
    _p(1, 3, -0.33333333333333337, 1, 0, 0, 1, 1),
    _p(2, 3, 0.33333333333333326, 1, 0, 0, 1, 1),
    _p(3, 3, 1, 1, 0, 0, 1, 1),
  ]),
  FluidControlPointPreset(4, 4, [
    _p(0, 0, -1, -1, 0, 0, 1, 2.075),
    _p(1, 0, -0.33333333333333337, -1, 0, 0, 1, 1),
    _p(2, 0, 0.33333333333333326, -1, 0, 0, 1, 1),
    _p(3, 0, 1, -1, 0, 0, 1, 1),
    _p(0, 1, -1, -0.4545779491139603, 0, 0, 1, 1),
    _p(1, 1, -0.33333333333333337, -0.33333333333333337, 0, 0, 1, 1),
    _p(2, 1, 0.0889403142626457, -0.6025711180694033, -32, 45, 1, 1),
    _p(3, 1, 1, -0.33333333333333337, 0, 0, 1, 1),
    _p(0, 2, -1, -0.07402408608567845, 1, 0, 1, 0.094),
    _p(1, 2, -0.2719422694359541, 0.09775369930903222, 25, -18, 1.321, 0),
    _p(2, 2, 0.19877414408395877, 0.4307383294587789, 48, -40, 0.755, 0.975),
    _p(3, 2, 1, 0.33333333333333326, -37, 0, 1, 1),
    _p(0, 3, -1, 1, 0, 0, 1, 1),
    _p(1, 3, -0.33333333333333337, 1, 0, 0, 1, 1),
    _p(2, 3, 0.5125850864305672, 1, -20, -18, 0, 1.604),
    _p(3, 3, 1, 1, 0, 0, 1, 1),
  ]),
  FluidControlPointPreset(5, 5, [
    _p(0, 0, -1, -1, 0, 0, 1, 1),
    _p(1, 0, -0.4501953125, -1, 0, 55, 1, 2.075),
    _p(2, 0, 0.1953125, -1, 0, 0, 1, 1),
    _p(3, 0, 0.4580078125, -1, 0, -25, 1, 1),
    _p(4, 0, 1, -1, 0, 0, 1, 1),
    _p(0, 1, -1, -0.2514475377525607, -16, 0, 2.327, 0.943),
    _p(1, 1, -0.55859375, -0.6609325945787148, 47, 0, 2.358, 0.377),
    _p(2, 1, 0.232421875, -0.5244375756366635, -66, -25, 1.855, 1.164),
    _p(3, 1, 0.685546875, -0.3753706470552125, 0, 0, 1, 1),
    _p(4, 1, 1, -0.6699125300354287, 0, 0, 1, 1),
    _p(0, 2, -1, 0.035910396862284255, 0, 0, 1, 1),
    _p(1, 2, -0.4921875, 0.005378616309457018, 90, 23, 1, 1.981),
    _p(2, 2, 0.021484375, -0.1365043639066228, 0, 42, 1, 1),
    _p(3, 2, 0.4765625, 0.05925822904974043, -30, 0, 1.95, 0.44),
    _p(4, 2, 1, 0.251428847823418, 0, 0, 1, 1),
    _p(0, 3, -1, 0.6968336464764276, -68, 0, 1, 0.786),
    _p(1, 3, -0.6904296875, 0.5890744209958608, -68, 0, 1, 1),
    _p(2, 3, 0.1845703125, 0.3879238667654693, 61, 0, 1, 1),
    _p(3, 3, 0.60546875, 0.4633553246018661, -47, -59, 0.849, 1.73),
    _p(4, 3, 1, 0.6214021886400309, -33, 0, 0.377, 1.604),
    _p(0, 4, -1, 1, 0, 0, 1, 1),
    _p(1, 4, -0.5, 1, 0, -73, 1, 1),
    _p(2, 4, -0.3271484375, 1, 0, -24, 0.314, 2.704),
    _p(3, 4, 0.5, 1, 0, 0, 1, 1),
    _p(4, 4, 1, 1, 0, 0, 1, 1),
  ]),
  FluidControlPointPreset(5, 5, [
    _p(0, 0, -1, -1),
    _p(1, 0, -0.6393, -1, 0, 0, 1, 2.3884),
    _p(2, 0, 0, -1),
    _p(3, 0, 0.5, -1),
    _p(4, 0, 1, -1),
    _p(0, 1, -1, -0.2301),
    _p(1, 1, -0.6934, -0.331, 0, -0.7188, 1, 1.063),
    _p(2, 1, -0.0082, -0.6814, -0.2583, 0, 1.0964, 1),
    _p(3, 1, 0.5836, -0.531, 0.7029, 0, 1.5466, 1),
    _p(4, 1, 1, -0.6407),
    _p(0, 2, -1, 0.2973, 0, 0, 1.8352, 1),
    _p(1, 2, -0.4082, 0.0602),
    _p(2, 2, -0.1803, -0.3646, -0.2998, 0, 1.1513, 1),
    _p(3, 2, 0.477, -0.1027, 0.8903, -0.1882, 1.0807, 0.8551),
    _p(4, 2, 1, -0.2973),
    _p(0, 3, -1, 0.7628, 0, 0, 2.3868, 1),
    _p(1, 3, -0.2525, 0.4814, -0.8406, -1.6199, 1.4093, 1.2215),
    _p(2, 3, 0.3607, 0.2814, -1.0713, -0.0529, 1.0025, 0.7611),
    _p(3, 3, 0.4885, 0.623, 0, 0.8184, 1, 1.2876),
    _p(4, 3, 1, 0.5),
    _p(0, 4, -1, 1),
    _p(1, 4, -0.4033, 1),
    _p(2, 4, 0.2672, 1),
    _p(3, 4, 0.5967, 1),
    _p(4, 4, 1, 1),
  ]),
];

double _clamp01(double x) => x.clamp(0.0, 1.0).toDouble();

double _randomRange(math.Random r, double min, double max) =>
    r.nextDouble() * (max - min) + min;

double _fract(double x) => x - x.floorToDouble();

double _noise(double x, double y) =>
    _fract(math.sin(x * 12.9898 + y * 78.233) * 43758.5453);

double _smoothNoise(double x, double y) {
  final x0 = x.floorToDouble();
  final y0 = y.floorToDouble();
  final x1 = x0 + 1;
  final y1 = y0 + 1;
  final xf = x - x0;
  final yf = y - y0;
  final u = xf * xf * (3 - 2 * xf);
  final v = yf * yf * (3 - 2 * yf);
  final n00 = _noise(x0, y0);
  final n10 = _noise(x1, y0);
  final n01 = _noise(x0, y1);
  final n11 = _noise(x1, y1);
  final nx0 = n00 * (1 - u) + n10 * u;
  final nx1 = n01 * (1 - u) + n11 * u;
  return nx0 * (1 - v) + nx1 * v;
}

List<double> _noiseGradient(double x, double y, [double epsilon = 0.001]) {
  final n1 = _smoothNoise(x + epsilon, y);
  final n2 = _smoothNoise(x - epsilon, y);
  final n3 = _smoothNoise(x, y + epsilon);
  final n4 = _smoothNoise(x, y - epsilon);
  final dx = (n1 - n2) / (2 * epsilon);
  final dy = (n3 - n4) / (2 * epsilon);
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) return [0.0, 0.0];
  return [dx / len, dy / len];
}

double _smoothstep(double edge0, double edge1, double x) {
  final t = _clamp01((x - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
}

void _smoothifyControlPoints(
  List<FluidControlPointConf> conf,
  int w,
  int h, {
  int iterations = 2,
  double factor = 0.5,
  double factorIterationModifier = 0.1,
}) {
  var grid = List.generate(
    h,
    (j) => List.generate(w, (i) => conf[j * w + i]),
  );
  var f = factor;
  const kernel = [1, 2, 1, 2, 4, 2, 1, 2, 1];
  const kernelSum = 16.0;

  for (var iter = 0; iter < iterations; iter++) {
    final newGrid = List.generate(
      h,
      (j) => List.generate(w, (i) => grid[j][i]),
    );
    for (var j = 0; j < h; j++) {
      for (var i = 0; i < w; i++) {
        if (i == 0 || i == w - 1 || j == 0 || j == h - 1) continue;
        var sumX = 0.0, sumY = 0.0;
        var sumUR = 0.0, sumVR = 0.0, sumUP = 0.0, sumVP = 0.0;
        for (var dj = -1; dj <= 1; dj++) {
          for (var di = -1; di <= 1; di++) {
            final weight = kernel[(dj + 1) * 3 + (di + 1)];
            final nb = grid[j + dj][i + di];
            sumX += nb.x * weight;
            sumY += nb.y * weight;
            sumUR += nb.ur * weight;
            sumVR += nb.vr * weight;
            sumUP += nb.up * weight;
            sumVP += nb.vp * weight;
          }
        }
        final cur = grid[j][i];
        newGrid[j][i] = _p(
          i,
          j,
          cur.x * (1 - f) + (sumX / kernelSum) * f,
          cur.y * (1 - f) + (sumY / kernelSum) * f,
          cur.ur * (1 - f) + (sumUR / kernelSum) * f,
          cur.vr * (1 - f) + (sumVR / kernelSum) * f,
          cur.up * (1 - f) + (sumUP / kernelSum) * f,
          cur.vp * (1 - f) + (sumVP / kernelSum) * f,
        );
      }
    }
    grid = newGrid;
    f = _clamp01(f + factorIterationModifier);
  }

  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      conf[j * w + i] = grid[j][i];
    }
  }
}

/// 随机控制点生成（对齐上游 `generateControlPoints`）。
FluidControlPointPreset generateFluidControlPoints(
  int width,
  int height, {
  math.Random? random,
}) {
  final r = random ?? math.Random();
  final variationFraction = _randomRange(r, 0.4, 0.6);
  final normalOffset = _randomRange(r, 0.3, 0.6);
  const blendFactor = 0.8;
  final smoothIters = _randomRange(r, 3, 5).floor();
  final smoothFactor = _randomRange(r, 0.2, 0.3);
  final smoothModifier = _randomRange(r, -0.1, -0.05);

  final w = width;
  final h = height;
  final conf = <FluidControlPointConf>[];
  final dx = w == 1 ? 0.0 : 2 / (w - 1);
  final dy = h == 1 ? 0.0 : 2 / (h - 1);

  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      final baseX = (w == 1 ? 0.0 : i / (w - 1)) * 2 - 1;
      final baseY = (h == 1 ? 0.0 : j / (h - 1)) * 2 - 1;
      final isBorder = i == 0 || i == w - 1 || j == 0 || j == h - 1;
      final pertX = isBorder
          ? 0.0
          : _randomRange(r, -variationFraction * dx, variationFraction * dx);
      final pertY = isBorder
          ? 0.0
          : _randomRange(r, -variationFraction * dy, variationFraction * dy);
      var x = baseX + pertX;
      var y = baseY + pertY;
      final ur = isBorder ? 0.0 : _randomRange(r, -60, 60);
      final vr = isBorder ? 0.0 : _randomRange(r, -60, 60);
      final up = isBorder ? 1.0 : _randomRange(r, 0.8, 1.2);
      final vp = isBorder ? 1.0 : _randomRange(r, 0.8, 1.2);

      if (!isBorder) {
        final uNorm = (baseX + 1) / 2;
        final vNorm = (baseY + 1) / 2;
        final grad = _noiseGradient(uNorm, vNorm, 0.001);
        var offsetX = grad[0] * normalOffset;
        var offsetY = grad[1] * normalOffset;
        final distToBorder = math.min(
          math.min(uNorm, 1 - uNorm),
          math.min(vNorm, 1 - vNorm),
        );
        final weight = _smoothstep(0, 1.0, distToBorder);
        offsetX *= weight;
        offsetY *= weight;
        x = x * (1 - blendFactor) + (x + offsetX) * blendFactor;
        y = y * (1 - blendFactor) + (y + offsetY) * blendFactor;
      }
      conf.add(_p(i, j, x, y, ur, vr, up, vp));
    }
  }

  _smoothifyControlPoints(
    conf,
    w,
    h,
    iterations: smoothIters,
    factor: smoothFactor,
    factorIterationModifier: smoothModifier,
  );
  return FluidControlPointPreset(w, h, conf);
}

/// 随机挑选一个预设（对齐上游：20% 概率随机生成 6×6，否则从 5 组预设里选）。
FluidControlPointPreset pickFluidControlPoints({math.Random? random}) {
  final r = random ?? math.Random();
  if (r.nextDouble() > 0.8) return generateFluidControlPoints(6, 6, random: r);
  return kFluidControlPointPresets[r.nextInt(kFluidControlPointPresets.length)];
}

/// 由预设构建控制点网格（应用角度 → 切线、缩放 → 切线模长）。
List<FluidControlPoint> buildFluidControlPoints(FluidControlPointPreset preset) {
  final w = preset.width;
  final h = preset.height;
  final uPower = w > 1 ? 2 / (w - 1) : 0.0;
  final vPower = h > 1 ? 2 / (h - 1) : 0.0;
  final points = List<FluidControlPoint>.filled(w * h, _zero);
  for (final cp in preset.conf) {
    final uRot = cp.ur * math.pi / 180;
    final vRot = cp.vr * math.pi / 180;
    final uScale = uPower * cp.up;
    final vScale = vPower * cp.vp;
    points[cp.cy * w + cp.cx] = FluidControlPoint(
      x: cp.x,
      y: cp.y,
      ux: math.cos(uRot) * uScale,
      uy: math.sin(uRot) * uScale,
      vx: -math.sin(vRot) * vScale,
      vy: math.cos(vRot) * vScale,
    );
  }
  return points;
}

const FluidControlPoint _zero = FluidControlPoint(
  x: 0,
  y: 0,
  ux: 0,
  uy: 0,
  vx: 0,
  vy: 0,
);

/// 位移贴图的**几何数据**（烘焙前的 CPU 侧结果，便于单测）。
class FluidWarpMesh {
  FluidWarpMesh({
    required this.resolution,
    required this.positions,
    required this.colors,
    required this.indices,
  });

  final int resolution;

  /// 画布坐标（[0,resolution]²）——烘焙图的顶点位置。
  final Float32List positions;

  /// ARGB：R = v_uv.x、G = v_uv.y、B = 0、A = 255。
  final Int32List colors;

  final Uint16List indices;
}

// ── gl-matrix 风格 4×4（列主序存储）逐行照搬，保证与上游逐位一致 ─────────────
// 存储约定：m[col * 4 + row]。

/// 上游 `BHPMesh` 的 Hermite 基矩阵 H（`Mat4.fromValues(...)` 列主序）。
final Float64List _kH = Float64List.fromList([
  2, -2, 1, 1, //
  -3, 3, -2, -1, //
  0, 0, 1, 0, //
  1, 0, 0, 0, //
]);

/// `H` 的转置（上游 `H_T`）。
final Float64List _kHT = _mat4Transpose(_kH);

Float64List _mat4Transpose(Float64List m) {
  final o = Float64List(16);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      o[c * 4 + r] = m[r * 4 + c];
    }
  }
  return o;
}

/// `out = a * b`（gl-matrix `Mat4.mul`）。
Float64List _mat4Mul(Float64List a, Float64List b) {
  final o = Float64List(16);
  for (var c = 0; c < 4; c++) {
    for (var r = 0; r < 4; r++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[k * 4 + r] * b[c * 4 + k];
      }
      o[c * 4 + r] = s;
    }
  }
  return o;
}

/// `out = m * a`（gl-matrix `Vec4.transformMat4`）。
void _vec4Transform(Float64List out, Float64List a, Float64List m) {
  for (var r = 0; r < 4; r++) {
    out[r] =
        m[r] * a[0] +
        m[4 + r] * a[1] +
        m[8 + r] * a[2] +
        m[12 + r] * a[3];
  }
}

/// 上游 `meshCoefficients`：把控制点位置/切线铺成几何矩阵 M（列主序数组）。
Float64List _meshCoefficients(
  FluidControlPoint p00,
  FluidControlPoint p01,
  FluidControlPoint p10,
  FluidControlPoint p11,
  int axis, // 0 = x, 1 = y
) {
  double l(FluidControlPoint p) => axis == 0 ? p.x : p.y;
  double u(FluidControlPoint p) => axis == 0 ? p.ux : p.uy;
  double v(FluidControlPoint p) => axis == 0 ? p.vx : p.vy;
  final o = Float64List(16);
  o[0] = l(p00);
  o[1] = l(p01);
  o[2] = v(p00);
  o[3] = v(p01);
  o[4] = l(p10);
  o[5] = l(p11);
  o[6] = v(p10);
  o[7] = v(p11);
  o[8] = u(p00);
  o[9] = u(p01);
  o[10] = 0;
  o[11] = 0;
  o[12] = u(p10);
  o[13] = u(p11);
  o[14] = 0;
  o[15] = 0;
  return o;
}

/// 上游 `precomputeMatrix`：`H_T · Mᵀ · H`。
Float64List _precomputeMatrix(Float64List m) =>
    _mat4Mul(_kHT, _mat4Mul(_mat4Transpose(m), _kH));

/// 由控制点网格构建**位移贴图几何**（前向栅格化：位置 = 未 aspect 校正的
/// NDC `pos`，颜色 = 纹理坐标 `v_uv`）。
///
/// 缓冲区布局对齐上游 `Mesh.resize`/`updateMesh`（列 = `cy*subdiv+u`、
/// 行 = `cx*subdiv+v`），因此三角形绘制顺序与折叠覆盖结果一致。
FluidWarpMesh buildFluidWarpMesh(
  FluidControlPointPreset preset, {
  int resolution = kFluidWarpResolution,
  int subdiv = kFluidSubdiv,
}) {
  final cp = buildFluidControlPoints(preset);
  final w = preset.width;
  final h = preset.height;
  final vertexWidth = (w - 1) * subdiv;
  final vertexHeight = (h - 1) * subdiv;
  final vertexCount = vertexWidth * vertexHeight;
  final positions = Float32List(vertexCount * 2);
  final colors = Int32List(vertexCount);
  final indices = Uint16List((vertexWidth - 1) * (vertexHeight - 1) * 6);

  final subDivM1 = subdiv - 1;
  final invTH = 1 / (subDivM1 * (h - 1));
  final invTW = 1 / (subDivM1 * (w - 1));
  // 每个细分索引的幂次向量 [n³, n², n, 1]（对齐上游 normPowers）。
  final normPowers = List<Float64List>.generate(subdiv, (i) {
    final n = i / subDivM1;
    return Float64List.fromList([n * n * n, n * n, n, 1]);
  });

  final res = resolution.toDouble();
  final tUx = Float64List(4);
  final tUy = Float64List(4);

  for (var cx = 0; cx < w - 1; cx++) {
    for (var cy = 0; cy < h - 1; cy++) {
      final p00 = cp[cy * w + cx];
      final p01 = cp[(cy + 1) * w + cx];
      final p10 = cp[cy * w + cx + 1];
      final p11 = cp[(cy + 1) * w + cx + 1];

      final xAcc = _precomputeMatrix(
        _meshCoefficients(p00, p01, p10, p11, 0),
      );
      final yAcc = _precomputeMatrix(
        _meshCoefficients(p00, p01, p10, p11, 1),
      );

      final sX = cx / (w - 1);
      final sY = cy / (h - 1);

      for (var u = 0; u < subdiv; u++) {
        final pu = normPowers[u];
        _vec4Transform(tUx, pu, xAcc);
        _vec4Transform(tUy, pu, yAcc);
        final col = cy * subdiv + u;
        for (var v = 0; v < subdiv; v++) {
          final pv = normPowers[v];
          final px =
              pv[0] * tUx[0] + pv[1] * tUx[1] + pv[2] * tUx[2] + pv[3] * tUx[3];
          final py =
              pv[0] * tUy[0] + pv[1] * tUy[1] + pv[2] * tUy[2] + pv[3] * tUy[3];
          final row = cx * subdiv + v;
          final idx = col + row * vertexWidth;
          positions[2 * idx] = (px * 0.5 + 0.5) * res;
          positions[2 * idx + 1] = (0.5 - py * 0.5) * res;

          final uvX = (sX + v * invTH).clamp(0.0, 1.0);
          final uvY = (1 - sY - u * invTW).clamp(0.0, 1.0);
          final r = (uvX * 255).round().clamp(0, 255);
          final g = (uvY * 255).round().clamp(0, 255);
          colors[idx] = (0xFF << 24) | (r << 16) | (g << 8);
        }
      }
    }
  }

  var k = 0;
  for (var y = 0; y < vertexHeight - 1; y++) {
    for (var x = 0; x < vertexWidth - 1; x++) {
      final a = y * vertexWidth + x;
      final b = a + 1;
      final c = a + vertexWidth;
      final d = c + 1;
      indices[k++] = a;
      indices[k++] = b;
      indices[k++] = c;
      indices[k++] = b;
      indices[k++] = d;
      indices[k++] = c;
    }
  }

  return FluidWarpMesh(
    resolution: resolution,
    positions: positions,
    colors: colors,
    indices: indices,
  );
}

/// 烘焙位移贴图（`drawVertices` + `toImageSync`）。
///
/// 用 `BlendMode.dst`：按 `Canvas.drawVertices` 文档，dst = 只取顶点色（忽略
/// paint）。关闭抗锯齿避免边缘混色。测试环境（`FLUTTER_TEST`）无法光栅化
/// `Picture.toImageSync`，返回 null，调用方回退直铺。
ui.Image? bakeFluidWarpImage(FluidWarpMesh mesh) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final vertices = ui.Vertices.raw(
    ui.VertexMode.triangles,
    mesh.positions,
    colors: mesh.colors,
    indices: mesh.indices,
  );
  canvas.drawVertices(
    vertices,
    ui.BlendMode.dst,
    ui.Paint()..isAntiAlias = false,
  );
  final pic = recorder.endRecording();
  try {
    return pic.toImageSync(mesh.resolution, mesh.resolution);
  } finally {
    pic.dispose();
  }
}

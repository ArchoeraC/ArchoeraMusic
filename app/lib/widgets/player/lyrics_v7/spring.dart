// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词 v7 一维弹簧引擎（移植自 AMLL
/// `amll-dev/applemusic-like-lyrics`，MIT）。
///
/// 基于阻尼振荡器的闭式解：无需逐帧积分，把帧间隔（秒）喂给 [Spring1D.update]
/// 即可直接求值当前位置。按阻尼比 ζ = damping / (2·√(stiffness·mass)) 分支：
/// - ζ ≥ 1（或 [SpringParams.soft]）：临界/过阻尼，单调趋近目标、无振荡；
/// - ζ < 1：欠阻尼，先冲过目标、衰减振荡后稳定。
///
/// [Spring1D.setTarget] 支持延迟队列：delayMs 未耗尽前 [Spring1D.update]
/// 保持原值不动，到期后再从当前位姿向新目标过渡；
/// [Spring1D.hardSet] 跳过动画、立即到位。
library;

import 'dart:math' as math;

/// 弹簧物理参数。
///
/// 默认 mass 0.9 / damping 15 / stiffness 90（与上游 solveSpring 一致），
/// 阻尼比 ζ ≈ 0.83，属带轻微过冲的欠阻尼过渡。
class SpringParams {
  const SpringParams({
    this.mass = 0.9,
    this.damping = 15.0,
    this.stiffness = 90.0,
    this.soft = false,
  });

  /// 质量：模拟弹簧末端物体质量，越大越"迟钝"（加速慢、惯性大、周期长）。
  final double mass;

  /// 阻尼系数：≥ 2·√(stiffness·mass) 时进入临界/过阻尼分支。
  final double damping;

  /// 刚度：回弹力强度，越大回到目标越快、振荡频率越高。
  final double stiffness;

  /// 强制走临界/过阻尼分支（忽略 damping 数值，纯指数衰减无振荡）。
  final bool soft;
}

/// 位置关于时间（秒）的函数。
typedef _Solver = double Function(double t);

/// 一维弹簧：当前位置/速度/目标均以 double 维护，无任何 UI 依赖。
class Spring1D {
  Spring1D({
    double initialPosition = 0,
    this.params = const SpringParams(),
  }) {
    current = initialPosition;
    targetPosition = initialPosition;
    velocity = 0;
    _pos = _constantOf(initialPosition);
    _vel = _constantOf(0);
    _acc = _constantOf(0);
  }

  /// 弹簧参数。在 [setTarget]/[hardSet] 重建求解器时读取，运行时替换后
  /// 需重新触发一次目标设置才生效。
  SpringParams params;

  /// 当前位置。
  double current = 0;

  /// 当前速度。
  double velocity = 0;

  /// 目标位置。
  double targetPosition = 0;

  /// 排队目标生效前的剩余延迟（毫秒）；无排队目标时为 0。
  double delayMs = 0;

  /// 本次运动的求解器时钟（秒），自上次重建起累计。
  double _time = 0;

  /// 排队中的目标位置；null 表示无延迟队列。
  double? _pending;

  bool _settled = true;
  _Solver _pos = _constantOf(0);
  _Solver _vel = _constantOf(0);
  _Solver _acc = _constantOf(0);

  /// 稳定判定阈值：位置/速度/加速度均小于它即视为到达。
  static const double _arrivalEps = 0.01;

  /// 设置目标位置。带 [delayMs]（毫秒）时先排队：延迟未过期间保持原值，
  /// 到期后从当前位置、速度向新目标过渡；不带延迟则立即重建求解器。
  void setTarget(double to, {double delayMs = 0}) {
    if (delayMs > 0) {
      _pending = to;
      this.delayMs = delayMs;
      _settled = false;
      return;
    }
    _pending = null;
    this.delayMs = 0;
    _restart(to);
  }

  /// 立即设置位置（跳过动画），并清除所有排队中的延迟目标。
  void hardSet(double v) {
    current = v;
    velocity = 0;
    targetPosition = v;
    _pending = null;
    delayMs = 0;
    _time = 0;
    _pos = _constantOf(v);
    _vel = _constantOf(0);
    _acc = _constantOf(0);
    _settled = true;
  }

  /// 推进弹簧状态。[elapsedSec] 为距上次调用经过的秒数（帧间隔）。
  ///
  /// 延迟队列未到期时，弹簧继续按当前目标求值（与上游 Spring 一致：延迟
  /// 只推迟“新目标生效”，不冻结动画）；到期后从当前位姿向新目标过渡。
  /// 到达稳定后会把 [current] 精确吸附到 [targetPosition] 并置 [velocity] 0。
  double update(double elapsedSec) {
    if (_settled) return current;
    if (_pending != null) {
      delayMs -= elapsedSec * 1000;
      if (delayMs <= 0) {
        final to = _pending!;
        _pending = null;
        delayMs = 0;
        _restart(to);
      }
    }
    _time += elapsedSec;
    current = _pos(_time);
    velocity = _vel(_time);
    if (_pending == null && _atRest()) {
      current = targetPosition;
      velocity = 0;
      _settled = true;
    }
    return current;
  }

  /// 是否已到达稳定状态：无排队目标且位置/速度/加速度均小于容差。
  bool arrived() {
    if (_settled) return true;
    if (_pending != null) return false;
    if (_atRest()) {
      current = targetPosition;
      velocity = 0;
      _settled = true;
      return true;
    }
    return false;
  }

  bool _atRest() {
    final x = _pos(_time);
    final v = _vel(_time);
    final a = _acc(_time);
    return (targetPosition - x).abs() < _arrivalEps &&
        v.abs() < _arrivalEps &&
        a.abs() < _arrivalEps;
  }

  /// 从当前位姿与速度重建求解器，使弹簧向 [to] 过渡。
  void _restart(double to) {
    final v = _vel(_time);
    targetPosition = to;
    _time = 0;
    _pos = _solveSpring(from: current, velocity: v, to: to, p: params);
    _vel = _derivative(_pos);
    _acc = _derivative(_vel);
    velocity = v;
    _settled = false;
  }
}

/// 常数函数。
_Solver _constantOf(double value) =>
    (double _) => value;

/// 数值导数（中心差分，步长 0.001s，与上游一致）。
_Solver _derivative(_Solver f) =>
    (double x) => (f(x + 0.001) - f(x - 0.001)) * 500;

/// 求解弹簧运动方程：给定起始位姿、初始速度与目标，返回
/// 「距本次运动起点的时间」→ 位置 的函数。
///
/// 欠阻尼分支公式与上游一致：disp = to - from，
/// wd = √(4·m·k − d²)，R = (d·disp − 2·m·v0) / wd，
/// x(t) = to − (cos(t·wd/2m)·disp + sin(t·wd/2m)·R)·e^(−t·d/2m)。
_Solver _solveSpring({
  required double from,
  required double velocity,
  required double to,
  required SpringParams p,
}) {
  final displacement = to - from;
  final m = p.mass;
  final k = p.stiffness;
  final d = p.damping;

  // 临界/过阻尼或强制 soft：纯指数衰减，无振荡。
  if (p.soft || d >= 2.0 * math.sqrt(k * m)) {
    final angularFreq = -math.sqrt(k / m);
    final residual = -angularFreq * displacement - velocity;
    return (double t) =>
        to - (displacement + t * residual) * math.exp(t * angularFreq);
  }

  // 欠阻尼：衰减振荡。
  final dampedFreq = math.sqrt(4.0 * m * k - d * d);
  final residual = (d * displacement - 2.0 * m * velocity) / dampedFreq;
  final halfDampedFreqPerMass = (0.5 * dampedFreq) / m;
  final halfDampingPerMass = (-0.5 * d) / m;
  return (double t) =>
      to -
      (math.cos(t * halfDampedFreqPerMass) * displacement +
              math.sin(t * halfDampedFreqPerMass) * residual) *
          math.exp(t * halfDampingPerMass);
}

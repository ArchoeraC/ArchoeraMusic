// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';

/// 用户帧率上限（FPS）→ 最小帧间隔。
///
/// 语义与 [PowerSavingFrameBinding.setFrameInterval] 一致：间隔内合并帧请求，
/// 到期才派发下一帧。约定：
/// - `fps <= 0` → [Duration.zero]（不限制）；
/// - [displayRefreshRate] 已知且目标帧率不低于它 → 不节流（超过刷新率的
///   目标没有意义，再快也只能跟着 vsync 出帧）；
/// - 否则提前 4%（至少 0.2ms、至多 1ms）到期：定时器若正好与 vsync 同刻，
///   会偶发白丢一整帧（表现为「突然掉到一半帧率」）；4% 的代价是实际帧率
///   可能比目标高 2~4%，仍低于「每帧都出」的满帧。
Duration frameIntervalForFps(int fps, {double displayRefreshRate = 0}) {
  if (fps <= 0) return Duration.zero;
  if (displayRefreshRate > 0 && fps >= displayRefreshRate - 0.5) {
    return Duration.zero;
  }
  final targetUs = 1000000 / fps;
  final slackUs = (targetUs * 0.04).clamp(200.0, 1000.0);
  final micros = (targetUs - slackUs).round();
  return Duration(microseconds: micros < 1000 ? 1000 : micros);
}

/// 合并「节能档位」与「用户帧率上限」：取更严格（间隔更长 = 帧率更低）者。
///
/// [Duration.zero] 表示不限制，因此任一为零时直接取另一个。
Duration effectiveFrameInterval(Duration powerInterval, Duration userInterval) {
  if (powerInterval == Duration.zero) return userInterval;
  if (userInterval == Duration.zero) return powerInterval;
  return powerInterval > userInterval ? powerInterval : userInterval;
}

/// 全局帧节流 Binding（节能模式的渲染层）。
///
/// Flutter 公开 API 无法直接设置帧率（`SchedulerBinding.framesEnabled` 只有
/// getter，由生命周期驱动），因此通过覆写 [scheduleFrame] 把节能期间的帧
/// 请求按「最小帧间隔」合并：间隔内多次请求只保留一次，间隔到期才真正
/// 派发一帧——动画 Ticker / 脏标记 / 事件触发的帧请求全部被合并，达到
/// 帧率上限的效果。
///
/// 事件驱动（Timer 合并，非轮询）；`scheduleForcedFrame`（窗口缩放、系统
/// 事件）不经过 [scheduleFrame]，仍即时渲染，不会被节流吞掉。
///
/// 另有 [setRenderingEnabled]：窗口最小化/隐藏到托盘时**直接停止出帧**
/// （0 帧，而非降帧），恢复可见时补一帧。
class PowerSavingFrameBinding extends WidgetsFlutterBinding {
  /// 本 binding 单例（构造函数继承框架逻辑，会写入全局 `_instance`）。
  static PowerSavingFrameBinding? _powerSavingInstance;

  /// 应用唯一入口：替代 [WidgetsFlutterBinding.ensureInitialized]。
  ///
  /// 新版 Flutter 的 `WidgetsBinding.instance` 是非空 getter（未初始化即
  /// 抛异常），无法像框架内部那样直接判空 `_instance`，因此用自身静态
  /// 标志保证单例。
  static PowerSavingFrameBinding ensureInitialized() {
    return _powerSavingInstance ??= PowerSavingFrameBinding();
  }

  /// 当前最小帧间隔；`Duration.zero` = 不限制（满帧）。
  Duration _minFrameInterval = Duration.zero;

  /// 是否允许出帧。`false` = 直接停止渲染（窗口最小化/隐藏到托盘时），
  /// 所有 [scheduleFrame] 请求被丢弃，直到重新可见。
  bool _renderingEnabled = true;

  /// 上次真正派发帧的时刻（节流基准）。
  DateTime _lastThrottledFrame = DateTime.fromMillisecondsSinceEpoch(0);

  /// 待派发帧的合并定时器（间隔到期时补一帧）。
  Timer? _pendingFrameTimer;

  /// 是否处于节流状态。
  bool get isThrottled => _minFrameInterval > Duration.zero;

  /// 当前是否允许出帧（false = 渲染已停止）。
  bool get renderingEnabled => _renderingEnabled;

  /// 停止 / 恢复渲染。
  ///
  /// 最小化 / 隐藏到托盘时窗口不可见，直接停帧比降帧更彻底（0 帧，动画
  /// Ticker 因无帧回调而自然静止）；恢复时立即补一帧，避免 UI 停在旧帧。
  /// 注意：**只影响渲染**，音频引擎照常播放。
  void setRenderingEnabled(bool enabled) {
    if (_renderingEnabled == enabled) return;
    _renderingEnabled = enabled;
    _pendingFrameTimer?.cancel();
    _pendingFrameTimer = null;
    if (enabled) {
      // 恢复：立即补一帧（同时走一遍帧间隔节流逻辑）。
      scheduleFrame();
    }
  }

  /// 设置最小帧间隔（如 5 FPS = 200ms）。[Duration.zero] 恢复满帧。
  ///
  /// 变更后**总是补一次帧请求**：取消 pending 定时器会让本轮帧请求落空，而
  /// Ticker 要等一帧结束才会再次 `scheduleTick`——不补就会一直停到下一次
  /// 输入事件（用户拖动帧率滑块这类「非零间隔之间切换」最容易撞上）。
  void setFrameInterval(Duration interval) {
    if (interval < Duration.zero) {
      interval = Duration.zero;
    }
    if (_minFrameInterval == interval) {
      return;
    }
    _minFrameInterval = interval;
    _pendingFrameTimer?.cancel();
    _pendingFrameTimer = null;
    scheduleFrame();
  }

  @override
  void scheduleFrame() {
    // 渲染已停止（最小化 / 托盘）：丢弃所有帧请求，不向引擎要帧。
    if (!_renderingEnabled) return;
    final interval = _minFrameInterval;
    if (interval == Duration.zero) {
      super.scheduleFrame();
      return;
    }
    final now = DateTime.now();
    final deadline = _lastThrottledFrame.add(interval);
    if (now.isBefore(deadline)) {
      // 距上次渲染未满间隔：合并请求，间隔到期后补一帧
      _pendingFrameTimer ??= Timer(deadline.difference(now), () {
        _pendingFrameTimer = null;
        _lastThrottledFrame = DateTime.now();
        super.scheduleFrame();
      });
      return;
    }
    _lastThrottledFrame = now;
    super.scheduleFrame();
  }
}

import 'dart:async';

import 'package:flutter/widgets.dart';

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

  /// 上次真正派发帧的时刻（节流基准）。
  DateTime _lastThrottledFrame = DateTime.fromMillisecondsSinceEpoch(0);

  /// 待派发帧的合并定时器（间隔到期时补一帧）。
  Timer? _pendingFrameTimer;

  /// 是否处于节流状态。
  bool get isThrottled => _minFrameInterval > Duration.zero;

  /// 设置最小帧间隔（如 5 FPS = 200ms）。[Duration.zero] 恢复满帧，
  /// 并立即补一帧，避免 UI 停留在节流前的最后一帧。
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
    if (interval == Duration.zero) {
      scheduleFrame();
    }
  }

  @override
  void scheduleFrame() {
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

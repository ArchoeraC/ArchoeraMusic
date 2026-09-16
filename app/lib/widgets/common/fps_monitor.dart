// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';

part 'fps_monitor/fps_monitor_overlay.dart';

/// Dev 模式性能监控浮层（借鉴 Mineradio app-memory 的系统监控思路）。
///
/// 使用 [SchedulerBinding.addTimingsCallback] 被动采样每帧耗时——不自持
/// Ticker、不额外请求帧，对应用渲染零开销叠加。右上角显示：等效 FPS /
/// 平均帧耗时 / 进程常驻内存；FPS 按高低着色（绿/黄/红）直观反映卡顿。
/// 点击小窗可在「完整信息 ↔ 圆点」间切换（收起后停止采集，零开销）。
///
/// 可见性双重门控（设置-开发者分类内独立开关）：
///  1. 开发者模式开启（[AppPrefs.developerMode]）；
///  2. 组件开关开启（[AppPrefs.devFpsMonitor]，默认关）。
/// 关闭开发者模式时组件开关随之复位，实现全量关闭。
class FpsMonitorHost extends ConsumerWidget {
  const FpsMonitorHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    final show = prefs.developerMode && prefs.devFpsMonitor;
    return show ? const _FpsOverlay() : const SizedBox.shrink();
  }
}

class _FpsOverlay extends StatefulWidget {
  const _FpsOverlay();

  @override
  State<_FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<_FpsOverlay> {
  /// 统计窗口：每秒汇总一次。
  static const _windowMs = 1000;

  Timer? _timer;
  double _fps = 0;
  double _frameMs = 0;
  int _rssMb = 0;
  bool _visible = true;

  /// 本窗口内的帧数（`addTimingsCallback` 批次长度之和）。
  int _frameCount = 0;

  /// 本窗口内各帧总耗时（用于平均帧时间）。
  Duration _frameSum = Duration.zero;

  /// 是否空闲（本窗口没有实际渲染帧）。
  bool _idle = true;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(
      const Duration(milliseconds: _windowMs),
      (_) => _tick(),
    );
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_visible) return;
    _frameCount += timings.length;
    for (final t in timings) {
      _frameSum += t.totalSpan;
    }
  }

  void _tick() {
    if (!mounted) return;
    if (!_visible) {
      // 收起态不采集（_onTimings 已提前返回）：只更新内存，保留上次 FPS/空闲态
      // 供圆点着色。
      setState(() => _rssMb = ProcessInfo.currentRss ~/ (1024 * 1024));
      return;
    }
    final count = _frameCount;
    final sum = _frameSum;
    _frameCount = 0;
    _frameSum = Duration.zero;
    setState(() {
      // 减去本监控自身每秒 setState 触发的那一帧；空闲时即为 0 → 显示 idle。
      final fps = count > 0 ? count - 1 : 0;
      _idle = fps == 0;
      if (!_idle) {
        _fps = fps.toDouble();
        _frameMs = count > 0 ? sum.inMicroseconds / count / 1000 : 0;
      }
      // 进程常驻内存（dart:io，桌面平台可用）
      _rssMb = ProcessInfo.currentRss ~/ (1024 * 1024);
    });
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _timer?.cancel();
    super.dispose();
  }

  void _toggleVisible() {
    setState(() => _visible = !_visible);
  }

  @override
  Widget build(BuildContext context) => _buildFpsOverlay(context);
}

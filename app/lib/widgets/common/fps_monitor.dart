import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';

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
  /// 统计窗口：每秒汇总一次帧耗时样本。
  static const _windowMs = 1000;

  /// 本窗口内各帧的总耗时（build+layout+paint）。
  final List<Duration> _frames = [];

  Timer? _timer;
  double _fps = 0;
  double _frameMs = 0;
  int _rssMb = 0;
  bool _visible = true;

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
    _frames.addAll(timings.map((t) => t.totalSpan));
  }

  void _tick() {
    if (!mounted) return;
    final frames = _frames;
    _frames.clear();
    if (frames.isNotEmpty) {
      final total = frames.fold<Duration>(Duration.zero, (a, b) => a + b);
      final avgMs = total.inMicroseconds / frames.length / 1000;
      setState(() {
        _frameMs = avgMs;
        _fps = 1000 / avgMs;
      });
    }
    // 进程常驻内存（dart:io，桌面平台可用）
    setState(() => _rssMb = ProcessInfo.currentRss ~/ (1024 * 1024));
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _timer?.cancel();
    super.dispose();
  }

  Color _fpsColor() {
    if (_fps >= 55) return const Color(0xFF4CAF50); // 绿：流畅
    if (_fps >= 30) return const Color(0xFFFFC107); // 黄：可感知卡顿
    return const Color(0xFFF44336); // 红：明显卡顿
  }

  @override
  Widget build(BuildContext context) {
    final color = _fpsColor();
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _visible = !_visible),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: _visible
              ? Text(
                  'FPS ${_fps.toStringAsFixed(0)} · '
                  '${_frameMs.toStringAsFixed(1)}ms · ${_rssMb}MB',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                )
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ),
    );
  }
}

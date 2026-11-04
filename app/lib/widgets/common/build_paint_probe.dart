// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// build / paint 计数探针（渲染专项 P0 基建）。
///
/// 行为借鉴外部合成器渲染调研的「零构建回归」方法论
/// （`docs/rendering-reference-research.md` D1，自研实现）：
/// 对被测子树分别统计 widget build 与向父图层重绘的次数，
/// 用 headless 测试断言「连续 N 帧动画 0 build / paint 有界」，
/// 验证的是**被消除的工作量**，不依赖真机帧时间。
///
/// 计数语义：
/// - `builds`：本探针 widget 的 [State.build] 执行次数。父级重建或本子树
///   配置变化都会计入；注意 build ≠ paint，两者必须分开解读。
/// - `paints`：本探针的渲染对象 `paint()` 执行次数，即该子树**向所属图层**
///   重绘的次数。子树内部若自带 `RepaintBoundary`/合成层，其内部重绘不会
///   重复计入本探针；反之整帧合成（父图层重绘）会计入。
///
/// 零成本：仅两个 int 自增与静态 Map 写入，无计时器、不请求帧；
/// 生产环境不挂载即无任何开销。
class BuildPaintProbe extends StatefulWidget {
  const BuildPaintProbe({super.key, required this.label, required this.child});

  /// 计数归属标签（同一标签可多处挂载，计数合并）。
  final String label;

  final Widget child;

  /// 指定标签的累计 build 次数。
  static int buildsOf(String label) => _counters[label]?.builds ?? 0;

  /// 指定标签的累计 paint 次数。
  static int paintsOf(String label) => _counters[label]?.paints ?? 0;

  /// 全部标签的只读快照。
  static Map<String, ({int builds, int paints})> snapshot() => {
    for (final entry in _counters.entries)
      entry.key: (builds: entry.value.builds, paints: entry.value.paints),
  };

  /// 清零全部计数（测试排布用）。
  static void resetAll() {
    for (final c in _counters.values) {
      c.builds = 0;
      c.paints = 0;
    }
  }

  static final Map<String, _ProbeCounter> _counters = {};

  @override
  State<BuildPaintProbe> createState() => _BuildPaintProbeState();
}

class _ProbeCounter {
  int builds = 0;
  int paints = 0;
}

class _BuildPaintProbeState extends State<BuildPaintProbe> {
  _ProbeCounter? _counter;

  @override
  void dispose() {
    if (_counter != null && _counter!.builds == 0 && _counter!.paints == 0) {
      // 从未真正计数的空挂载直接回收，避免注册表随挂载点无限增长。
      BuildPaintProbe._counters.remove(widget.label);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    (_counter ??= BuildPaintProbe._counters
        .putIfAbsent(widget.label, _ProbeCounter.new)).builds += 1;
    return _PaintCounterRenderWidget(
      counter: _counter!,
      child: widget.child,
    );
  }
}

class _PaintCounterRenderWidget extends SingleChildRenderObjectWidget {
  const _PaintCounterRenderWidget({
    required this.counter,
    super.child,
  });

  final _ProbeCounter counter;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintCounter(counter);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPaintCounter).counter = counter;
  }
}

class _RenderPaintCounter extends RenderProxyBox {
  _RenderPaintCounter(this._counter);

  _ProbeCounter _counter;

  set counter(_ProbeCounter value) {
    if (identical(value, _counter)) return;
    _counter = value;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _counter.paints += 1;
    super.paint(context, offset);
  }
}

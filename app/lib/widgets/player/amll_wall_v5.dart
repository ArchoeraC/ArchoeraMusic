/// AMLL 歌词渲染模块 v6 —— 每行独立 Y 弹簧（级联）+ 可变行高。
///
/// 设计（自研，不复用 DOM 库）：
///  - 行高：每行 = 主行实测高 +（带翻译时）翻译小字高，前序累计得自然中心；
///  - 目标：激活行中心对齐 align*H，其余行按其自然中心相对定位；
///  - 换行：以 [kLineSwitchMs]（300ms）为单行时长，按“距激活行距离”给
///    每行一个小的级联延时（近邻 0ms、远处递增），形成非“整墙整体平移”
///    的波浪过渡（每行各自到达）；seek/切歌等跨屏跳转直接定位。
///  - 字体/字号/颜色透传应用设置；逐字渐变扫亮；可拖拽回弹；隐藏滚动逻辑由绘制裁剪承担。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/lyrics/lyric_line.dart';

/// 单行换行动画时长（毫秒）。用户明确要求保留 300ms 的换行节奏。
const int kLineSwitchMs = 300;

/// 级联延时步长（毫秒/距离），制造逐行到位的手感。
const int kCascadeStepMs = 28;

const Map<String, (double, double, double)> amllSpringPresets = {
  'default': (1.0, 10.0, 100.0),
  'smooth': (1.0, 15.0, 90.0),
  'responsive': (1.0, 18.0, 260.0),
  'jello': (1.0, 8.0, 120.0),
  'heavy': (2.0, 25.0, 100.0),
};

class _Ctx {
  List<LyricGroup> groups = const [];
  int positionMs = 0;
  int active = -1;
  double w = 0;
  double h = 0;
  double fontSize = 18;
  String? fontFamily;
  double inactiveAlpha = 0.45;
  double align = 0.5;
  bool wordSweep = true;
  bool hidePassed = false;
  bool showTranslation = true;
  Color played = const Color(0xFF4DA3FF);
  Color unplayed = const Color(0xFF9AA1B5);

  List<double> heights = const [];
  List<double> centers = const [];
  /// 每行当前屏幕中心（含拖拽偏移由 painter 统一加）。
  List<double> y = const [];
  double drag = 0;
  double gap = 8;
}

class AmllWall extends StatefulWidget {
  const AmllWall({
    super.key,
    required this.groups,
    required this.positionMs,
    required this.onSeek,
    this.fontSize = 18,
    this.fontFamily,
    this.playedColor = const Color(0xFF4DA3FF),
    this.unplayedColor = const Color(0xFF9AA1B5),
    this.showTranslation = true,
    this.alignFraction = 0.5,
    this.inactiveAlpha = 0.45,
    this.wordSweep = true,
    this.hidePassed = false,
    this.springPreset = 'default',
    this.animate = true,
  });

  final List<LyricGroup> groups;
  final int positionMs;
  final ValueChanged<int> onSeek;
  final double fontSize;
  final String? fontFamily;
  final Color playedColor;
  final Color unplayedColor;
  final bool showTranslation;
  final double alignFraction;
  final double inactiveAlpha;
  final bool wordSweep;
  final bool hidePassed;
  final String springPreset;
  final bool animate;

  @override
  State<AmllWall> createState() => _AmllWallState();
}

class _AmllWallState extends State<AmllWall> with SingleTickerProviderStateMixin {
  final _Ctx _c = _Ctx();
  late final _Repaint _repaint = _Repaint();
  late final AnimationController _anim;

  List<double> _from = const [];
  List<double> _to = const [];
  bool _ever = false;
  bool _dragging = false;
  double _dragStart = 0;

  bool _metricsDirty = true;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: kLineSwitchMs + 120),
    )..addListener(_animTick);
    _c.groups = widget.groups;
    _syncStyle();
  }

  @override
  void dispose() {
    _anim.dispose();
    _repaint.dispose();
    super.dispose();
  }

  int get _activeIdx {
    final g = _c.groups;
    if (g.isEmpty) return -1;
    var res = -1;
    final pos = widget.positionMs;
    for (var i = 0; i < g.length; i++) {
      if (pos < g[i].original.timeMs) break;
      final end = g[i].endMs;
      if (i == g.length - 1 || end == null || pos < end) res = i;
    }
    return res;
  }

  @override
  void didUpdateWidget(AmllWall old) {
    super.didUpdateWidget(old);
    _c.groups = widget.groups;
    _c.positionMs = widget.positionMs;
    _syncStyle();
    _metricsDirty = true;
    _repaint.notify();
  }

  /// 将 widget 样式设置同步进绘制上下文（字号/颜色/透明度/锚点等）。
  void _syncStyle() {
    _c.fontSize = widget.fontSize;
    _c.fontFamily = widget.fontFamily;
    _c.played = widget.playedColor;
    _c.unplayed = widget.unplayedColor;
    _c.inactiveAlpha = widget.inactiveAlpha;
    _c.align = widget.alignFraction;
    _c.wordSweep = widget.wordSweep;
    _c.hidePassed = widget.hidePassed;
    _c.showTranslation = widget.showTranslation;
  }

  double _textH(String text, double fs, FontWeight w) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: widget.fontFamily,
          fontSize: fs,
          fontWeight: w,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(40, _c.w - 24));
    return tp.height + fs * 0.26;
  }

  void _rebuildMetrics() {
    final groups = widget.groups;
    final fs = widget.fontSize;
    final heights = <double>[];
    for (final g in groups) {
      var hh = _textH(g.original.text, fs, FontWeight.w500);
      if (widget.showTranslation && (g.translation?.isNotEmpty ?? false)) {
        hh += 4 + _textH(g.translation!, fs * 0.5, FontWeight.w400);
      }
      heights.add(hh);
    }
    _c.heights = heights;
    _c.gap = math.max(4, fs * 0.35);
    final centers = <double>[];
    var acc = heights.isEmpty ? 0.0 : heights[0] / 2;
    for (var i = 0; i < heights.length; i++) {
      centers.add(acc);
      if (i + 1 < heights.length) {
        acc += heights[i] / 2 + _c.gap + heights[i + 1] / 2;
      }
    }
    _c.centers = centers;
    if (_c.y.length != groups.length) {
      _c.y = List<double>.filled(groups.length, centers.isEmpty ? 0 : centers[0]);
    }
    _metricsDirty = false;
    _place(snap: true);
  }

  double _targetFor(int i, int active) {
    final centers = _c.centers;
    if (centers.isEmpty) return 0;
    final h = _c.h > 0 ? _c.h : 400.0;
    final anchor = active < 0 ? 0 : math.min(active, centers.length - 1);
    return centers[i] - (centers[anchor] - h * _c.align);
  }

  void _place({bool snap = false}) {
    if (_dragging) return;
    final n = _c.y.length;
    if (n == 0) return;
    final active = _activeIdx;
    _c.active = active;
    final to = [for (var i = 0; i < n; i++) _targetFor(i, active)];
    if (snap || !_ever || !widget.animate || _bigJump(to, active)) {
      _c.y = to;
      _ever = true;
      _anim.stop();
      _repaint.notify();
      return;
    }
    _ever = true;
    _from = List.of(_c.y);
    _to = to;
    if (_anim.isAnimating) _anim.stop();
    _anim.forward(from: 0);
    _repaint.notify();
  }

  bool _bigJump(List<double> to, int active) {
    if (_c.h <= 0 || to.isEmpty) return false;
    final delta = (to[math.max(0, active)] - _c.y[math.max(0, active)]).abs();
    return delta > _c.h * 0.6;
  }

  void _animTick() {
    final n = _from.length;
    if (n == 0) return;
    final totalMs = kLineSwitchMs + 120;
    final now = _anim.value * totalMs;
    final active = _c.active;
    final ys = <double>[];
    for (var i = 0; i < n; i++) {
      final d = (i - active).abs().toDouble();
      final delayMs = d <= 1 ? 0.0 : (d - 1) * kCascadeStepMs;
      final lt = _easeOut(((now - delayMs) / kLineSwitchMs).clamp(0.0, 1.0));
      ys.add(_from[i] + (_to[i] - _from[i]) * lt);
    }
    _c.y = ys;
    _repaint.notify();
  }

  double _easeOut(double x) => 1 - math.pow(1 - x, 3).toDouble();

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final rawW = constraints.maxWidth;
        final rawH = constraints.maxHeight;
        final w = (rawW.isFinite && rawW > 0) ? rawW : 400.0;
        final h = (rawH.isFinite && rawH > 0) ? rawH : 400.0;
        if (w != _c.w || h != _c.h || _metricsDirty) {
          _c.w = w;
          _c.h = h;
          _rebuildMetrics();
        }
        _c.positionMs = widget.positionMs;
        _syncStyle();
        _c.active = _activeIdx;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _seekAt(d.localPosition.dy),
          onVerticalDragStart: (d) {
            _dragging = true;
            _dragStart = _c.drag;
            _anim.stop();
          },
          onVerticalDragUpdate: (d) {
            final delta = d.primaryDelta ?? d.delta.dy;
            _c.drag = (_dragStart - delta).clamp(-4000.0, 4000.0);
            _repaint.notify();
          },
          onVerticalDragEnd: (_) {
            _dragging = false;
            _c.drag = 0;
            _place();
          },
          onVerticalDragCancel: () {
            _dragging = false;
            _c.drag = 0;
            _place();
          },
          child: CustomPaint(
            size: Size(w, h),
            painter: _Painter(_c, _repaint),
          ),
        );
      },
    );
  }

  void _seekAt(double y) {
    final n = _c.y.length;
    if (n == 0) return;
    var best = 0;
    var bd = double.infinity;
    for (var i = 0; i < n; i++) {
      final d = (y - (_c.y[i] + _c.drag)).abs();
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    widget.onSeek(_c.groups[best].original.timeMs);
  }
}

class _Painter extends CustomPainter {
  _Painter(this.c, Listenable repaint) : super(repaint: repaint);
  final _Ctx c;

  @override
  void paint(Canvas canvas, Size size) {
    final n = c.y.length;
    if (n == 0) return;
    final viewH = c.h > 0 ? c.h : size.height;
    for (var i = 0; i < n; i++) {
      final cy = c.y[i] + c.drag;
      final half = c.heights[i] / 2;
      if (cy + half < 0 || cy - half > viewH) continue;
      final g = c.groups[i];
      final isActive = i == c.active;
      if (c.hidePassed && c.active >= 0 && i < c.active) continue;
      final d = (i - c.active).abs().toDouble();
      final alpha = isActive
          ? 1.0
          : math.max(
              c.inactiveAlpha,
              1 - (math.max(0.0, d - 1) * 0.35),
            ).clamp(0.0, 1.0);
      _drawLine(canvas, size, g, i, cy, alpha, isActive);
    }
  }

  void _drawLine(
    Canvas canvas,
    Size size,
    LyricGroup g,
    int index,
    double centerY,
    double alpha,
    bool isActive,
  ) {
    final fs = c.fontSize;
    final scale = isActive ? 1.08 : 0.97;
    final main = _painterFor(g, isActive, fs);
    main.layout(maxWidth: math.max(40, c.w - 24));
    if (alpha < 0.999) {
      canvas.saveLayer(
        Rect.fromCenter(
          center: Offset(c.w / 2, centerY),
          width: main.width + 40,
          height: c.heights[index] + 20,
        ),
        Paint()..color = Color.fromRGBO(0, 0, 0, alpha),
      );
    }
    canvas.save();
    canvas.translate(c.w / 2, centerY);
    canvas.scale(scale);
    canvas.translate(-main.width / 2, -main.height / 2);
    main.paint(canvas, Offset.zero);
    canvas.restore();
    if (alpha < 0.999) canvas.restore();

    final tr = g.translation;
    if (c.showTranslation && (tr?.isNotEmpty ?? false)) {
      final sub = TextPainter(
        text: TextSpan(
          text: tr,
          style: TextStyle(
            fontFamily: c.fontFamily,
            fontSize: fs * 0.5,
            color: isActive
                ? c.played.withValues(alpha: 0.8)
                : c.unplayed.withValues(alpha: alpha),
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(40, c.w - 24));
      sub.paint(
        canvas,
        Offset(
          c.w / 2 - sub.width / 2,
          centerY + c.heights[index] / 2 - sub.height - 2,
        ),
      );
    }
  }

  TextPainter _painterFor(LyricGroup g, bool isActive, double fs) {
    if (isActive && c.wordSweep) {
      final frags = g.fragments;
      if (frags != null && frags.isNotEmpty) {
        return TextPainter(
          text: TextSpan(
            style: TextStyle(
              fontFamily: c.fontFamily,
              fontSize: fs,
              fontWeight: FontWeight.w600,
            ),
            children: [
              for (final f in frags)
                TextSpan(
                  text: f.text,
                  style: TextStyle(color: _fragColor(f, g.original.timeMs)),
                ),
            ],
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        );
      }
    }
    final color = isActive
        ? (c.positionMs >= g.original.timeMs ? c.played : c.unplayed)
        : c.unplayed;
    return TextPainter(
      text: TextSpan(
        text: g.original.text,
        style: TextStyle(
          fontFamily: c.fontFamily,
          fontSize: fs,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
  }

  Color _fragColor(LyricFragment f, int lineStart) {
    final abs = lineStart + f.startMs;
    final dur = (f.durationMs != null && f.durationMs! > 0)
        ? f.durationMs!
        : 500;
    if (c.positionMs < abs) return c.played.withValues(alpha: 0.4);
    if (c.positionMs >= abs + dur) return c.played;
    return Color.lerp(
      c.played.withValues(alpha: 0.4),
      c.played,
      (c.positionMs - abs) / dur,
    )!;
  }

  @override
  bool shouldRepaint(_Painter old) => false;
}

/// repaint 通知器。
class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

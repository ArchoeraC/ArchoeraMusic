// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_physics_wall.dart';

class _AmllPhysicsWallState extends State<AmllPhysicsWall>
    with SingleTickerProviderStateMixin {
  final _PaintCtx _c = _PaintCtx();
  late final Ticker _ticker;
  late final Spring1D _shift;
  final _Repaint _repaint = _Repaint();
  int _lastUs = 0;
  List<Spring1D> _y = const [];
  bool _metricsDirty = true;
  int _prevActive = -2;
  bool _ever = false;
  int? _lastPosMs;
  bool _seekSnap = false;
  double _user = 0; // 用户浏览偏移（并入行弹簧目标，停滚后回弹）
  double _touchStartUser = 0;
  Timer? _userReset;
  bool _dragging = false;
  SpringParams get _params =>
      kSpringPresets[widget.springPreset] ?? kSpringPresets['default']!;

  double get _userExtent {
    if (_c.centers.isEmpty) return 4000;
    return _c.centers.last + _c.h;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _shift = Spring1D();
    _syncStyle();
  }

  @override
  void dispose() {
    _userReset?.cancel();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

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

  @override
  void didUpdateWidget(AmllPhysicsWall old) {
    super.didUpdateWidget(old);
    _syncStyle();
    final groupsChanged = old.groups != widget.groups;
    _c.groups = widget.groups;
    _c.positionMs = widget.positionMs;
    if (groupsChanged) {
      _seekSnap = true;
      _prevActive = -2;
      _metricsDirty = true;
    } else {
      final last = _lastPosMs ?? widget.positionMs;
      final delta = widget.positionMs - last;
      if (delta > 2000 || delta < -100) _seekSnap = true;
    }
    _lastPosMs = widget.positionMs;
    if (old.fontSize != widget.fontSize ||
        old.fontFamily != widget.fontFamily) {
      _metricsDirty = true;
    }
    _maybeRetarget();
    _repaint.notify();
  }

  int get _activeIdx {
    final g = _c.groups;
    if (g.isEmpty) return -1;
    final pos = widget.positionMs;
    var res = -1;
    for (var i = 0; i < g.length; i++) {
      if (pos < g[i].original.timeMs) break;
      final end = g[i].endMs;
      if (i == g.length - 1 || end == null || pos < end) res = i;
    }
    return res;
  }

  void _rebuildMetrics() {
    final groups = widget.groups;
    final w = _c.w;
    if (w <= 0) return;
    final heights = computeLineHeights(
      groups,
      fontSize: widget.fontSize,
      fontFamily: widget.fontFamily,
      maxWidth: math.max(40, w - 24),
      showTranslation: widget.showTranslation,
    );
    final centers = computeCenters(
      heights,
      gapPx: math.max(4, widget.fontSize * 0.42),
    ); // 行间 0.42×
    _c.heights = heights;
    _c.centers = centers;
    if (_y.length != groups.length) {
      _y = [
        for (final _ in groups)
          Spring1D(initialPosition: centers.isEmpty ? 0 : centers.first),
      ];
    }
    _c.y = [for (final s in _y) s.current];
    _c.scale = List<double>.filled(groups.length, 1);
    _metricsDirty = false;
  }

  double _targetFor(int i, int anchor) {
    final centers = _c.centers;
    if (centers.isEmpty) return 0;
    final h = _c.h > 0 ? _c.h : 400.0;
    return centers[i] - (centers[anchor] - h * _c.align);
  }

  void _maybeRetarget({bool force = false}) {
    if (_dragging) return;
    final seekSnap = _seekSnap;
    _seekSnap = false;
    final active = _activeIdx;
    _c.active = active;
    final anchor = active < 0
        ? 0
        : math.min(active, math.max(0, _c.centers.length - 1));
    final oldAnchor = (_prevActive >= 0 && _prevActive < _c.centers.length)
        ? _prevActive
        : anchor;
    final changed = active != _prevActive;
    _prevActive = active;
    if (_c.centers.isEmpty) return;
    if (!changed && !force) return;
    final far = seekSnap || _bigChange(anchor);
    final snap = far || !_ever || !widget.animate;
    final first = !_ever;
    _ever = true;
    // 远跳：每行先落到“新布局最终位置”，再由统一平移弹簧把整墙从旧位置
    // 平滑过渡到新位置（避免超长距离下逐行级联产生的“炸动画”）。
    final farShift = _c.centers[anchor] - _c.centers[oldAnchor];
    if (snap) {
      if (far && !first && widget.animate && oldAnchor != anchor) {
        _shift.hardSet(farShift);
        _shift.setTarget(0);
        _shift.params = _params;
      } else {
        _shift.hardSet(0);
      }
    } else {
      _shift.hardSet(0);
    }
    for (var i = 0; i < _y.length; i++) {
      final target = _targetFor(i, anchor);
      final spring = _y[i];
      spring.params = _params;
      if (snap) {
        spring.hardSet(target);
      } else {
        final d = (i - anchor).abs().toDouble();
        final delay = d <= 1 ? 0.0 : (d - 1) * kCascadeStepMs;
        spring.setTarget(target, delayMs: delay);
      }
      _c.y[i] = spring.current;
    }
    if (!snap || !_shift.arrived()) _ensureTicker();
    _repaint.notify();
  }

  /// 把用户浏览偏移并入各行弹簧目标（跟随手指/滚轮，无级联延迟）。
  void _pushUserTargets() {
    if (_c.centers.isEmpty) return;
    final active = _activeIdx;
    final anchor = active < 0
        ? 0
        : math.min(active, math.max(0, _c.centers.length - 1));
    for (var i = 0; i < _y.length; i++) {
      final spring = _y[i];
      spring.params = _params;
      spring.setTarget(_targetFor(i, anchor) + _user);
      _c.y[i] = spring.current;
    }
    _ensureTicker();
    _repaint.notify();
  }

  /// 手动浏览：重置 5s 无操作后回弹到当前行（对齐上游）。
  void _beginUserScroll() {
    _dragging = true;
    _userReset?.cancel();
  }

  void _armUserReset() {
    _userReset?.cancel();
    _userReset = Timer(const Duration(milliseconds: 5000), () {
      if (!mounted) return;
      _user = 0;
      _dragging = false;
      _pushUserTargets();
    });
  }

  bool _bigChange(int anchor) {
    if (_c.h <= 0 || _y.isEmpty) return false;
    final cur = _y[math.min(anchor, _y.length - 1)].current;
    final tgt = _targetFor(math.min(anchor, _y.length - 1), anchor);
    return (cur - tgt).abs() > _c.h * 0.6;
  }

  void _ensureTicker() {
    if (!_ticker.isActive) {
      _lastUs = 0;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    if (!mounted) return;
    final us = elapsed.inMicroseconds;
    if (_lastUs == 0) {
      _lastUs = us;
      return;
    }
    var dt = (us - _lastUs) / 1000000.0;
    _lastUs = us;
    if (dt < 0.0005 || dt > 0.05) return;
    var moving = false;
    for (var i = 0; i < _y.length; i++) {
      final s = _y[i];
      if (!s.arrived()) {
        _c.y[i] = s.update(dt);
        moving = true;
      }
    }
    if (!_shift.arrived()) {
      _c.shift = _shift.update(dt);
      moving = true;
    }
    if (!moving) {
      _c.shift = 0;
      _ticker.stop();
    }
    _repaint.notify();
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    if (groups.isEmpty) {
      return Center(
        child: Icon(
          Icons.lyrics_outlined,
          size: 64,
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
        ),
      );
    }
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
          _prevActive = -2;
          _maybeRetarget(force: true);
        }
        _c.positionMs = widget.positionMs;
        _syncStyle();
        _maybeRetarget();

        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              _beginUserScroll();
              _user = (_user - e.scrollDelta.dy).clamp(
                -_userExtent,
                _userExtent,
              );
              _pushUserTargets();
              _armUserReset();
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _seekAt(d.localPosition.dy),
            onVerticalDragStart: (d) {
              _beginUserScroll();
              _touchStartUser = _user;
              _armUserReset();
            },
            onVerticalDragUpdate: (d) {
              final delta = d.primaryDelta ?? d.delta.dy;
              _user = (_touchStartUser + delta).clamp(
                -_userExtent,
                _userExtent,
              );
              _pushUserTargets();
              _armUserReset();
            },
            onVerticalDragEnd: (_) {
              _armUserReset();
            },
            onVerticalDragCancel: () {
              _armUserReset();
            },
            child: CustomPaint(
              size: Size(w, h),
              painter: _Painter(_c, _repaint),
            ),
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
      final d = (y - (_c.y[i] + _c.shift)).abs();
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    // 点击即退出“用户浏览态”：清偏移/停 5s 回弹定时器，
    // 让随后的位置推进（seek）正常驱动动效与高亮。
    _userReset?.cancel();
    _user = 0;
    _dragging = false;
    _pushUserTargets();
    widget.onSeek(_c.groups[best].original.timeMs);
  }
}

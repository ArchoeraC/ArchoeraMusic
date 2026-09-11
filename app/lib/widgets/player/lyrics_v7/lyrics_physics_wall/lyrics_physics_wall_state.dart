// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_physics_wall.dart';

class _AmllPhysicsWallState extends State<AmllPhysicsWall>
    with SingleTickerProviderStateMixin {
  final _PaintCtx _c = _PaintCtx();
  late final Ticker _ticker;
  final _Repaint _repaint = _Repaint();
  int _lastUs = 0;
  List<Spring1D> _y = const [];
  bool _metricsDirty = true;

  /// 当前布局锚点（激活行；无行覆盖时保持上一个锚点）。
  int _anchorIdx = -1;
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
      _anchorIdx = -1;
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

  /// 播放位置严格覆盖的行索引（`start <= pos < end`）。
  ///
  /// 无行覆盖（前奏 / 行间空隙 / 末尾）时返回 -1，交由布局锚点单独处理：
  /// 普通推进保持上一锚点，仅 seek 越界才定位到最近边界行。
  int get _activeIdx {
    final g = _c.groups;
    if (g.isEmpty) return -1;
    final pos = widget.positionMs;
    var res = -1;
    for (var i = 0; i < g.length; i++) {
      if (pos < g[i].original.timeMs) break;
      final end = g[i].endMs;
      if (end == null || pos < end) res = i;
    }
    return res;
  }

  /// 解析布局锚点：激活行优先；无行覆盖时保持上一个锚点，仅 seek 越界
  /// 才定位到最近边界行（对齐 AMLL/SPlayer 的 handleSeek 行为）。
  int _resolveAnchor(int active, bool seekSnap) {
    final n = _c.centers.length;
    if (n == 0) return -1;
    if (active >= 0) return math.min(active, n - 1);
    if (!seekSnap && _anchorIdx >= 0 && _anchorIdx < n) return _anchorIdx;
    return math.min(_futureIndex(widget.positionMs), n - 1);
  }

  /// 第一个起始时间 >= pos 的行；pos 在全部歌词之后则取末行。
  int _futureIndex(int pos) {
    final g = widget.groups;
    for (var i = 0; i < g.length; i++) {
      if (g[i].original.timeMs >= pos) return i;
    }
    return g.isEmpty ? 0 : g.length - 1;
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
    _c.active = active; // 高亮：严格覆盖播放位置
    if (_c.centers.isEmpty) {
      _repaint.notify();
      return;
    }
    final anchor = _resolveAnchor(active, seekSnap);
    if (anchor < 0) {
      _repaint.notify();
      return;
    }
    final oldAnchor = (_anchorIdx >= 0 && _anchorIdx < _c.centers.length)
        ? _anchorIdx
        : anchor;
    final changed = anchor != _anchorIdx || !_ever;
    _anchorIdx = anchor;
    if (!changed && !force) {
      _repaint.notify();
      return;
    }
    // 锚点位移超过一屏视作跨屏跳转：所有行同步位移（无级联），
    // 保证行距不塌陷、不产生“炸动画”或重叠伪影。仅首次/尺寸重排/
    // 关闭动画时直接瞬移。
    final shift = (_c.centers[anchor] - _c.centers[oldAnchor]).abs();
    final snap = force || !_ever || !widget.animate;
    final noCascade = oldAnchor != anchor && shift > _c.h;
    _ever = true;
    final n = _y.length;
    final targets = [for (var i = 0; i < n; i++) _targetFor(i, anchor)];
    if (snap) {
      for (var i = 0; i < n; i++) {
        final spring = _y[i];
        spring.params = _params;
        spring.hardSet(targets[i]);
        _c.y[i] = spring.current;
      }
      _repaint.notify();
      return;
    }
    // 级联延迟自“进入视口顶部的第一行”向下累积（对齐 AMLL
    // calculateLayout）：上方行先动、下方行按 1.05 衰减依次跟进。
    // 若按“距激活行距离”给延迟，快速换行时上方行会滞后堆叠。
    var moving = false;
    var cascadeDelay = 0.0;
    var baseDelay = noCascade ? 0.0 : kCascadeStepMs;
    for (var i = 0; i < n; i++) {
      final spring = _y[i];
      spring.params = _params;
      spring.setTarget(targets[i], delayMs: cascadeDelay);
      _c.y[i] = spring.current;
      if (!spring.arrived()) moving = true;
      if (i + 1 < n) {
        final nextTop = targets[i + 1] - _c.heights[i + 1] / 2;
        if (nextTop >= 0) {
          cascadeDelay += baseDelay;
          if (i >= anchor) baseDelay /= 1.05;
        }
      }
    }
    if (moving) _ensureTicker();
    _repaint.notify();
  }

  /// 把用户浏览偏移并入各行弹簧目标（跟随手指/滚轮，无级联延迟）。
  void _pushUserTargets() {
    if (_c.centers.isEmpty || _y.isEmpty) return;
    final anchor = (_anchorIdx >= 0 && _anchorIdx < _c.centers.length)
        ? _anchorIdx
        : 0;
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
    if (!moving) {
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
          EtaIcons.fileMusicOutline,
          size: 64,
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
        ),
      );
    }
    // 首帧同步：_c.groups 平时由 didUpdateWidget 维护，但首次挂载时
    // LayoutBuilder/_rebuildMetrics 已按 widget.groups 算好 _c.y/_c.heights，
    // 若不同步这里，painter 会在 _c.groups 仍为空时按 _c.y.length 索引越界。
    _c.groups = groups;
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
          _anchorIdx = -1;
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

  // ---- 测试探针（仅用于回归测试，不参与运行逻辑）----

  /// 当前布局锚点索引。
  @visibleForTesting
  int debugAnchor() => _anchorIdx;

  /// 当前高亮行索引（无覆盖为 -1）。
  @visibleForTesting
  int debugActive() => _c.active;

  /// 每行当前屏幕中心。
  @visibleForTesting
  List<double> debugY() => List.of(_c.y);

  /// 每行自然中心。
  @visibleForTesting
  List<double> debugCenters() => List.of(_c.centers);

  /// 每行高度。
  @visibleForTesting
  List<double> debugHeights() => List.of(_c.heights);

  void _seekAt(double y) {
    final n = _c.y.length;
    if (n == 0) return;
    var best = 0;
    var bd = double.infinity;
    for (var i = 0; i < n; i++) {
      final d = (y - _c.y[i]).abs();
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

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
  List<double> _scale = const [];
  List<double> _fade = const [];
  List<double> _blur = const [];
  bool _metricsDirty = true;

  /// 已识别出的间奏（长空隙）与每段间奏三点的自然纵坐标。
  List<LyricInterlude> _interludes = const [];
  List<double> _interludeDotY = const [];

  /// 播放时钟：把 ~20Hz 的位置事件插值到 vsync。
  final LyricClock _clock = LyricClock();

  /// 当前布局锚点（激活行；无行覆盖时保持上一个锚点）。
  int _anchorIdx = -1;
  bool _ever = false;
  int? _lastPosMs;
  bool _seekSnap = false;
  double _user = 0; // 用户浏览偏移（并入行弹簧目标，停滚后回弹）
  Timer? _userReset;
  bool _dragging = false;

  /// 新歌 / 首次布局时让整墙从下方飞入（对齐 AMLL RebuildView 的
  /// `resetPosition`：行初始位置放在视口下方，再由弹簧归位）。
  bool _flyIn = true;

  /// 行纵向弹簧参数（由 [resolvePosYSpringPolicy] 或用户预设决定；
  /// 用户浏览时沿用上一次播放期的取值，对齐 AMLL 只在行/间奏变化时更新）。
  SpringParams _posYParams = resolvePosYSpringPolicy();

  /// 是否使用 AMLL 自适应弹簧策略（预设为 `default` 时）。
  bool get _usePolicy => widget.springPreset == kDefaultSpringPreset;

  /// 解算当前应使用的行弹簧参数。
  SpringParams _resolveSpringParams({
    required bool seeking,
    required bool interludeActive,
  }) {
    if (!_usePolicy) {
      return kSpringPresets[widget.springPreset] ?? kSpringPresets['smooth']!;
    }
    final groups = widget.groups;
    final anchor = _anchorIdx;
    int? interval;
    if (anchor > 0 && anchor < groups.length) {
      interval =
          groups[anchor].original.timeMs - groups[anchor - 1].original.timeMs;
    }
    final pos = _clock.valueMs;
    var endOfSong = false;
    if (groups.isNotEmpty) {
      final last = groups.last;
      final lastEnd = last.endMs ?? last.original.timeMs + 4000;
      endOfSong = pos >= lastEnd;
    }
    return resolvePosYSpringPolicy(
      seeking: seeking,
      interludeActive: interludeActive,
      intervalMs: interval,
      endOfSong: endOfSong,
    );
  }

  /// 是否按 vsync 推进时钟（播放中且允许动画）。
  bool get _wantsClock =>
      widget.playing && widget.animate && widget.groups.isNotEmpty;

  double get _userExtent {
    if (_c.centers.isEmpty) return 4000;
    return _c.centers.last + _c.h;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _clock.reset(widget.positionMs, playing: _wantsClock);
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
    _c.showRomanization = widget.showRomanization;
    _c.fontWeight = widget.fontWeight;
    _c.enableScale = widget.enableScale;
    _c.enableBlur = widget.enableBlur;
    _c.wordFadeWidth = widget.wordFadeWidth;
  }

  @override
  void didUpdateWidget(AmllPhysicsWall old) {
    super.didUpdateWidget(old);
    _syncStyle();
    _clock.anchor(widget.positionMs, playing: _wantsClock);
    final groupsChanged = old.groups != widget.groups;
    _c.groups = widget.groups;
    _c.positionMs = _clock.valueMs;
    if (groupsChanged) {
      _seekSnap = true;
      _anchorIdx = -1;
      _metricsDirty = true;
      _flyIn = true; // 新歌整墙从下方飞入（对齐 AMLL RebuildView）
      _resetVisuals();
    } else {
      final last = _lastPosMs ?? widget.positionMs;
      final delta = widget.positionMs - last;
      if (delta > 2000 || delta < -100) _seekSnap = true;
    }
    _lastPosMs = widget.positionMs;
    if (old.fontSize != widget.fontSize ||
        old.fontFamily != widget.fontFamily ||
        old.showTranslation != widget.showTranslation ||
        old.showRomanization != widget.showRomanization ||
        old.fontWeight != widget.fontWeight) {
      _metricsDirty = true;
    }
    // 位置事件驱动的换行：走级联（对齐 AMLL PlaybackTick）；seek 不带级联。
    _maybeRetarget(stagger: !_seekSnap);
    _ensureTicker();
    _repaint.notify();
  }

  /// 切歌时把视觉过渡态复位（否则新歌首行会带着上一首的淡入/缩放）。
  void _resetVisuals() {
    for (var i = 0; i < _fade.length; i++) {
      _fade[i] = 0;
    }
    for (var i = 0; i < _scale.length; i++) {
      _scale[i] = 1;
    }
    for (var i = 0; i < _blur.length; i++) {
      _blur[i] = 0;
    }
  }

  /// 播放位置严格覆盖的行索引（`start <= pos < end`）。
  ///
  /// 无行覆盖（前奏 / 行间空隙 / 末尾）时返回 -1，交由布局锚点单独处理：
  /// 普通推进保持上一锚点，仅 seek 越界才定位到最近边界行。
  int get _activeIdx {
    final g = _c.groups;
    if (g.isEmpty) return -1;
    final pos = _clock.valueMs;
    var res = -1;
    for (var i = 0; i < g.length; i++) {
      if (pos < g[i].original.timeMs) break;
      final end = g[i].endMs;
      if (end == null || pos < end) res = i;
    }
    return res;
  }

  /// 播放位置是否落在某段间奏内；返回间奏下标，否则 -1。
  int _interludeIndexAt(int pos) {
    for (var i = 0; i < _interludes.length; i++) {
      final it = _interludes[i];
      if (pos >= it.startMs && pos < it.endMs) return i;
    }
    return -1;
  }

  /// 解析布局锚点：间奏 → 空隙前一行；激活行优先；无行覆盖时保持上一个
  /// 锚点，仅 seek 越界才定位到最近边界行（对齐 AMLL/SPlayer 的 handleSeek）。
  int _resolveAnchor(int active, bool seekSnap, int interludeIdx) {
    final n = _c.centers.length;
    if (n == 0) return -1;
    if (interludeIdx >= 0) {
      final ai = _interludes[interludeIdx].anchorIndex;
      return math.min(math.max(0, ai), n - 1);
    }
    if (active >= 0) return math.min(active, n - 1);
    if (!seekSnap && _anchorIdx >= 0 && _anchorIdx < n) return _anchorIdx;
    return math.min(_futureIndex(_clock.valueMs), n - 1);
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
    // 切歌 / 字号 / 字体 / 宽度变化 → 段落缓存整体失效。
    _c.cache.clear();
    _c.fragCache.clear();
    final heights = computeLineHeights(
      groups,
      fontSize: widget.fontSize,
      fontFamily: widget.fontFamily,
      maxWidth: math.max(40, w - 24),
      showTranslation: widget.showTranslation,
      showRomanization: widget.showRomanization,
      fontWeight: widget.fontWeight,
    );
    final centers = computeCenters(
      heights,
      gapPx: widget.fontSize * kLyricLineGapEm,
      isBg: [for (final g in groups) g.isBG],
    ); // 行间 0.8×（AMLL wrapper 上下 .4em 内边距）
    // 间奏预留：空隙之后的行整体下移「三点 + 上下留白」的高度，空隙本身
    // 成为三点的位置（对齐 AMLL 给 anchor 之后的行加 interludeTotalHeight）。
    _interludes = computeInterludes(groups);
    final dotSize = widget.fontSize * 0.3;
    final dotMargin = widget.fontSize * 0.4;
    final interludeExtra = dotSize + dotMargin * 2;
    if (_interludes.isEmpty) {
      _interludeDotY = const [];
    } else {
      for (final it in _interludes) {
        for (var i = it.anchorIndex + 1; i < centers.length; i++) {
          centers[i] += interludeExtra;
        }
      }
      _interludeDotY = [
        for (final it in _interludes)
          it.anchorIndex < 0
              ? (centers.isEmpty
                    ? 0.0
                    : centers.first -
                          heights.first / 2 -
                          dotMargin -
                          dotSize / 2)
              : centers[it.anchorIndex] +
                    heights[it.anchorIndex] / 2 +
                    dotMargin +
                    dotSize / 2,
      ];
    }
    _c.heights = heights;
    _c.centers = centers;
    final n = groups.length;
    if (_y.length != n) {
      _y = [
        for (final _ in groups)
          Spring1D(initialPosition: centers.isEmpty ? 0 : centers.first),
      ];
      _scale = List<double>.filled(n, 1);
      _fade = List<double>.filled(n, 0);
      _blur = List<double>.filled(n, 0);
    }
    _c.y = [for (final s in _y) s.current];
    _c.scale = _scale;
    _c.fade = _fade;
    _c.blur = _blur;
    // 新歌 / 首次布局：整墙从视口下方飞入（对齐 AMLL RebuildView 的
    // `resetPosition`）。已挂载过且只是尺寸/字号变化时保留当前位置，
    // 由弹簧平滑过渡到新布局。
    if (_flyIn) {
      final from = (_c.h > 0 ? _c.h : 400.0) * 1.5;
      for (var i = 0; i < _y.length; i++) {
        _y[i].hardSet(centers.isEmpty ? from : centers[i] + from);
        _c.y[i] = _y[i].current;
      }
      _flyIn = false;
    }
    _metricsDirty = false;
  }

  double _targetFor(int i, int anchor) {
    final centers = _c.centers;
    if (centers.isEmpty) return 0;
    final h = _c.h > 0 ? _c.h : 400.0;
    return centers[i] - (centers[anchor] - h * _c.align);
  }

  /// 重新计算各行弹簧目标。
  ///
  /// [stagger] 是否启用级联延迟——仅「播放推进换行」用（对齐 AMLL
  /// `LayoutReason.PlaybackTick` 之外的场景都 `disableStagger`）。
  /// [force] 目标未变也重新下发（尺寸/字号变化后用）。
  /// [snapNow] 直接瞬移（触摸拖拽跟随、性能模式）。
  void _maybeRetarget({
    bool force = false,
    bool stagger = false,
    bool snapNow = false,
  }) {
    if (_dragging) return;
    final seekSnap = _seekSnap;
    _seekSnap = false;
    final pos = _clock.valueMs;
    final interludeIdx = _interludeIndexAt(pos);
    // 间奏期间不点亮任何行（对齐 AMLL：间奏会清空高亮集合），改为三点动画。
    final active = interludeIdx >= 0 ? -1 : _activeIdx;
    _c.active = active; // 高亮：严格覆盖播放位置
    _c.dots = interludeIdx < 0
        ? InterludeDotsState.hidden
        : resolveInterludeDots(
            startMs: _interludes[interludeIdx].startMs,
            endMs: _interludes[interludeIdx].endMs,
            nowMs: pos,
          );
    _c.dotsNaturalY = interludeIdx < 0 ? 0 : _interludeDotY[interludeIdx];
    if (_c.centers.isEmpty) {
      _repaint.notify();
      return;
    }
    final anchor = _resolveAnchor(active, seekSnap, interludeIdx);
    if (anchor < 0) {
      _repaint.notify();
      return;
    }
    _c.anchor = anchor;
    final oldAnchor = (_anchorIdx >= 0 && _anchorIdx < _c.centers.length)
        ? _anchorIdx
        : anchor;
    final changed = anchor != _anchorIdx || !_ever;
    _anchorIdx = anchor;
    if (!changed && !force) {
      _repaint.notify();
      return;
    }
    // 弹簧参数：按 AMLL 策略（Seek/间奏慢速、正常播放按行间隔自适应）。
    _posYParams = _resolveSpringParams(
      seeking: seekSnap,
      interludeActive: interludeIdx >= 0,
    );
    // 锚点位移超过一屏视作跨屏跳转：所有行同步位移（无级联），
    // 保证行距不塌陷、不产生“炸动画”或重叠伪影。仅触摸拖拽/性能模式瞬移。
    final shift = (_c.centers[anchor] - _c.centers[oldAnchor]).abs();
    final snap = snapNow || !widget.animate;
    final noCascade = !stagger || (oldAnchor != anchor && shift > _c.h);
    _ever = true;
    final n = _y.length;
    final targets = [for (var i = 0; i < n; i++) _targetFor(i, anchor)];
    if (snap) {
      for (var i = 0; i < n; i++) {
        final spring = _y[i];
        spring.params = _posYParams;
        spring.hardSet(targets[i]);
        _c.y[i] = spring.current;
      }
      _repaint.notify();
      return;
    }
    // 级联延迟（对齐 AMLL calculateLayout）：自「底部仍在视口内」的第一行
    // 向下累积 50ms，锚点及其之后按 1.05 衰减；上方行先动、越往下越晚，
    // 形成整墙一起「推上去」的观感。若按“距激活行距离”给延迟，快速换行时
    // 上方行会滞后堆叠。
    var moving = false;
    var cascadeDelay = 0.0;
    var baseDelay = noCascade ? 0.0 : kCascadeStepMs;
    for (var i = 0; i < n; i++) {
      final spring = _y[i];
      spring.params = _posYParams;
      spring.setTarget(targets[i], delayMs: cascadeDelay);
      _c.y[i] = spring.current;
      if (!spring.arrived()) moving = true;
      if (targets[i] + _c.heights[i] >= 0) {
        cascadeDelay += baseDelay;
        if (i >= anchor) baseDelay /= 1.05;
      }
    }
    if (moving) _ensureTicker();
    _repaint.notify();
  }

  /// 把用户浏览偏移并入各行弹簧目标（无级联延迟）。
  ///
  /// [snap] 触摸拖拽时直接跟手（对齐 AMLL `ContinuousScroll` 的 `snapPosY`）；
  /// 滚轮走弹簧（`DiscreteScroll`）。
  void _pushUserTargets({bool snap = false}) {
    if (_c.centers.isEmpty || _y.isEmpty) return;
    final anchor = (_anchorIdx >= 0 && _anchorIdx < _c.centers.length)
        ? _anchorIdx
        : 0;
    for (var i = 0; i < _y.length; i++) {
      final spring = _y[i];
      spring.params = _posYParams;
      final to = _targetFor(i, anchor) + _user;
      if (snap) {
        spring.hardSet(to);
      } else {
        spring.setTarget(to);
      }
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
    if (_ticker.isActive) return;
    _lastUs = 0;
    _ticker.start();
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
    if (dt <= 0) return;
    // 对齐 AMLL MAX_FRAME_DELTA：页面挂起后首帧 delta 过大，直接钳制，
    // 避免动画以秒级时长过冲。
    if (dt > 0.1) dt = 0.1;
    if (dt < 0.0005) return;

    var moving = false;

    if (_clock.isRunning) {
      _clock.tick(dt);
      _c.positionMs = _clock.valueMs;
      // 时钟推进换行 → 级联（对齐 AMLL PlaybackTick）。
      _maybeRetarget(stagger: true);
      moving = true;
    }

    for (var i = 0; i < _y.length; i++) {
      final s = _y[i];
      if (!s.arrived()) {
        _c.y[i] = s.update(dt);
        moving = true;
      }
    }
    if (_animateVisuals(dt)) moving = true;

    if (!moving) _ticker.stop();
    _repaint.notify();
  }

  /// 平滑「点亮 / 熄灭 / 缩放 / 失焦」过渡态。
  ///
  /// 用指数趋近而不是给每行再挂弹簧：行数可达数百，弹簧对象与逐帧求解
  /// 成本不划算，且这几项都是纯装饰量，指数平滑足够。
  bool _animateVisuals(double dt) {
    final n = _fade.length;
    if (n == 0) return false;
    if (!widget.animate) {
      // 性能模式：直接吸附到目标，不做过渡。
      final anchor = _anchorIdx;
      var changed = false;
      for (var i = 0; i < n; i++) {
        final ft = i == _c.active ? 1.0 : 0.0;
        final st = widget.enableScale ? 1.0 - (1.0 - ft) * 0.03 : 1.0;
        final d = anchor < 0 ? 0.0 : (i - anchor).abs().toDouble();
        final bt = (!widget.enableBlur || d == 0)
            ? 0.0
            : math.min(kMaxBlurPx, d);
        if (_fade[i] != ft || _scale[i] != st || _blur[i] != bt) changed = true;
        _fade[i] = ft;
        _scale[i] = st;
        _blur[i] = bt;
      }
      return changed;
    }
    final anchor = _anchorIdx;
    var moving = false;
    for (var i = 0; i < n; i++) {
      final active = i == _c.active;
      final ft = active ? 1.0 : 0.0;
      var f = _fade[i];
      if (f != ft) {
        final tau = ft > f ? kActivateTauIn : kActivateTauOut;
        f += (ft - f) * (1 - math.exp(-dt / tau));
        if ((ft - f).abs() < 0.002) f = ft;
        _fade[i] = f;
        moving = true;
      }
      final st = widget.enableScale ? 1.0 - (1.0 - f) * 0.03 : 1.0;
      if ((_scale[i] - st).abs() > 1e-4) moving = true;
      _scale[i] = st;
      final d = anchor < 0 ? 0.0 : (i - anchor).abs().toDouble();
      final bt = (!widget.enableBlur || d == 0) ? 0.0 : math.min(kMaxBlurPx, d);
      var b = _blur[i];
      if ((b - bt).abs() > 0.01) {
        b += (bt - b) * (1 - math.exp(-dt / 0.1));
        if ((bt - b).abs() < 0.01) b = bt;
        _blur[i] = b;
        moving = true;
      } else if (b != bt) {
        _blur[i] = bt;
      }
    }
    return moving;
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
        _c.positionMs = _clock.valueMs;
        _syncStyle();
        _maybeRetarget();
        _ensureTicker();

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
              // 触摸按下即与目标对齐，避免第一帧跳变。
              _pushUserTargets(snap: true);
              _armUserReset();
            },
            onVerticalDragUpdate: (d) {
              // 累积每次移动的增量（primaryDelta 是「相对上一帧」的增量），
              // 不能用起点 + 单次增量，否则多事件拖拽几乎不动。
              // 触摸拖拽直接跟手（对齐 AMLL ContinuousScroll 的 snapPosY）。
              final delta = d.primaryDelta ?? d.delta.dy;
              _user = (_user + delta).clamp(-_userExtent, _userExtent);
              _pushUserTargets(snap: true);
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

  /// 插值后的渲染位置（毫秒）。
  @visibleForTesting
  int debugClockMs() => _clock.valueMs;

  /// 每行当前屏幕中心。
  @visibleForTesting
  List<double> debugY() => List.of(_c.y);

  /// 每行自然中心。
  @visibleForTesting
  List<double> debugCenters() => List.of(_c.centers);

  /// 每行高度。
  @visibleForTesting
  List<double> debugHeights() => List.of(_c.heights);

  /// 每行激活外观权重（0 = 未激活外观，1 = 激活外观）。
  @visibleForTesting
  List<double> debugFade() => List.of(_fade);

  /// 每行当前缩放。
  @visibleForTesting
  List<double> debugScale() => List.of(_scale);

  /// 每行当前失焦半径（px）。
  @visibleForTesting
  List<double> debugBlur() => List.of(_blur);

  /// 当前段落缓存条目数（应随可见窗口有界，不随歌长增长）。
  @visibleForTesting
  int debugCacheEntries() => _c.cache.entryCount;

  /// 当前逐字渲染缓存条目数（有界）。
  @visibleForTesting
  int debugFragCacheEntries() => _c.fragCache.entryCount;

  /// 间奏三点是否可见。
  @visibleForTesting
  bool debugDotsVisible() => _c.dots.visible;

  /// 间奏三点的当帧亮度（3 个）。
  @visibleForTesting
  List<double> debugDots() => List.of(_c.dots.dots);

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

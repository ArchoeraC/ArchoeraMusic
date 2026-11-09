// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_view.dart';

extension _LyricsViewBuild on _LyricsViewState {
  Widget _buildLyricsView(BuildContext context) {
    if (widget.groups.isEmpty) return const _EmptyLyrics();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 800.0;
        final viewH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 600.0;
        // 留一点水平内边距，长行换行时不贴边。
        final maxWidth = math.max(40.0, viewW - 24);
        final index = lyricIndexAt(widget.groups, widget.positionMs);
        // 用环境默认字体（含主题字体/回退链）实测，保证换行点与渲染一致。
        final baseStyle = DefaultTextStyle.of(context).style;
        final textScaler = MediaQuery.textScalerOf(context);

        // 「基础布局键」不含当前行索引：只有它变化时才需要重新排版 / 吸附；
        // 单纯换行（索引变化）走线性滚动，不重新量完整首歌。
        final baseKey = (
          groups: widget.groups,
          width: maxWidth,
          fontSize: widget.fontSize,
          lineHeight: widget.lineHeight,
          showTranslation: widget.showTranslation,
          showRomanization: widget.showRomanization,
          fontWeight: widget.fontWeight,
          currentFontSize: widget.currentFontSize,
          inactiveFontWeight: widget.inactiveFontWeight,
          textAlign: widget.textAlign,
          baseStyle: baseStyle,
          textScaler: textScaler,
        );
        final layout = _layoutFor(
          baseKey,
          index,
          maxWidth,
          baseStyle,
          textScaler,
        );
        final target = _targetFor(index, layout, viewH);
        final maxScroll = _maxScrollFor(layout, viewH);
        _target = target;

        final layoutChanged = baseKey != _lastBaseKey;
        final indexChanged = index != _lastFollowIndex;
        final followChanged = layoutChanged || indexChanged || !_didInitialSnap;
        // 无论是否在手动浏览都更新跟踪键：否则浏览结束后会把「浏览期间
        // 已经发生的换行/布局变化」当成新变化，再做一次多余的吸附。
        _lastBaseKey = baseKey;
        _lastFollowIndex = index;
        if (!_userScrolling && followChanged) {
          // 纯换行才做线性滚动；换歌 / 改字号 / 改宽度直接吸附，避免长距离
          // 慢速滑动把用户晾在半路。
          final animate = _didInitialSnap && !layoutChanged;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _animateTo(target.clamp(0.0, maxScroll), animate: animate);
            _didInitialSnap = true;
          });
        }

        final pad = math.max(0.0, viewH / 2 - widget.lineHeight / 2);
        return Listener(
          // 触控板 / 鼠标滚轮：手动浏览歌词。
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _userScrollBy(event.scrollDelta.dy, maxScroll);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (_) => _beginUserScroll(),
            onVerticalDragUpdate: (details) =>
                _userScrollBy(-details.delta.dy, maxScroll),
            onVerticalDragEnd: (_) => _endUserScroll(),
            onVerticalDragCancel: _endUserScroll,
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _scroll,
                builder: (context, _) {
                  final scroll = _scroll.value;
                  final first = _firstVisible(layout, scroll, pad, viewH);
                  final last = _lastVisible(layout, scroll, pad, viewH);
                  _lastWindowSize = last < first ? 0 : last - first + 1;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (var i = first; i <= last; i++)
                        _positionedLine(
                          context,
                          i,
                          index,
                          layout,
                          scroll,
                          pad,
                          viewH,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _positionedLine(
    BuildContext context,
    int i,
    int index,
    _LyricsLayout layout,
    double scroll,
    double pad,
    double viewH,
  ) {
    final group = widget.groups[i];
    final top = pad + layout.tops[i] - scroll;
    final center = top + layout.heights[i] / 2;
    // 上下渐隐：直接乘进行颜色，零离屏层。
    final edge = widget.fadeEdges && viewH > 0
        ? lyricsEdgeFadeAt(center / viewH)
        : 1.0;
    // 离视口中心越近越「亮」；滚动过程中连续变化，换行不跳变。
    // 聚焦半径同时受行高约束：4K 全屏下不会把半个屏幕的行都点亮。
    final focusRadius = math.max(
      120.0,
      math.min(viewH * 0.42, widget.lineHeight * 4.5),
    );
    final focus = viewH <= 0
        ? 0.0
        : (1 - ((center - viewH / 2).abs() / focusRadius)).clamp(0.0, 1.0);
    final isCurrent = i == index;
    final endMs =
        group.endMs ??
        (i + 1 < widget.groups.length
            ? widget.groups[i + 1].original.timeMs
            : group.original.timeMs + 4000);
    _builtLines += 1;
    return Positioned(
      key: ValueKey<int>(i),
      top: top,
      left: 0,
      right: 0,
      child: _Line(
        group: group,
        isCurrent: isCurrent,
        positionMs: widget.positionMs,
        endMs: endMs,
        focus: focus,
        edgeAlpha: edge,
        fontSize: widget.fontSize,
        lineHeight: widget.lineHeight,
        playedColor: widget.playedColor,
        unplayedColor: widget.unplayedColor,
        showTranslation: widget.showTranslation,
        showRomanization: widget.showRomanization,
        fontWeight: widget.fontWeight,
        currentFontSize: widget.currentFontSize,
        inactiveFontWeight: widget.inactiveFontWeight,
        inactiveScale: widget.inactiveScale,
        unplayedAlpha: widget.unplayedAlpha,
        textAlign: widget.textAlign,
        onTap: widget.onSeek == null
            ? null
            : () => widget.onSeek!(group.original.timeMs),
      ),
    );
  }

  /// 目标行居中所需的滚动偏移。
  double _targetFor(int index, _LyricsLayout layout, double viewH) {
    final i = index < 0 ? 0 : index;
    if (i >= layout.heights.length) return _maxScrollFor(layout, viewH);
    final center = layout.tops[i] + layout.heights[i] / 2;
    final target = center - widget.lineHeight / 2;
    return math.max(0.0, target).clamp(0.0, _maxScrollFor(layout, viewH));
  }

  double _maxScrollFor(_LyricsLayout layout, double viewH) {
    final pad = math.max(0.0, viewH / 2 - widget.lineHeight / 2);
    return math.max(0.0, layout.total + pad * 2 - viewH);
  }

  /// 线性滚动到目标：恒定速度（约 0.34 px/ms），不做 ease-in/out。
  /// 特大幅度跳转（seek / 拖进度条）直接吸附，避免慢速滑过整首歌。
  void _animateTo(double target, {required bool animate}) {
    if (!animate || _userScrolling) {
      _scroll.value = target;
      return;
    }
    final distance = (target - _scroll.value).abs();
    if (distance < 0.5) return;
    if (distance > 600) {
      _scroll.value = target;
      return;
    }
    final ms = (distance / 0.34).round().clamp(90, 420);
    _scroll.animateTo(
      target,
      duration: Duration(milliseconds: ms),
      curve: appMotionLinear,
    );
  }

  void _beginUserScroll() {
    _userScrolling = true;
    _resumeTimer?.cancel();
    _scroll.stop();
  }

  void _userScrollBy(double delta, double maxScroll) {
    _beginUserScroll();
    _scroll.value = (_scroll.value + delta).clamp(0.0, maxScroll);
  }

  void _endUserScroll() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _userScrolling = false;
      _animateTo(_target, animate: true);
    });
  }

  int _firstVisible(
    _LyricsLayout layout,
    double scroll,
    double pad,
    double viewH,
  ) {
    final overscan = math.min(viewH * 0.75, 600.0);
    final top = scroll - pad - overscan; // 视口上方多留一屏（大屏封顶 600px）。
    var lo = 0;
    var hi = layout.tops.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (layout.tops[mid] + layout.heights[mid] < top) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return math.max(0, lo - 1);
  }

  int _lastVisible(
    _LyricsLayout layout,
    double scroll,
    double pad,
    double viewH,
  ) {
    final overscan = math.min(viewH * 0.75, 600.0);
    final bottom = scroll - pad + viewH + overscan; // 视口下方多留一屏。
    var lo = 0;
    var hi = layout.tops.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (layout.tops[mid] <= bottom) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return math.min(layout.tops.length - 1, lo);
  }

  _LyricsLayout _layoutFor(
    Object baseKey,
    int index,
    double maxWidth,
    TextStyle baseStyle,
    TextScaler textScaler,
  ) {
    final key = (base: baseKey, index: index);
    final cached = _layout;
    if (cached != null && key == _layoutKey) return cached;

    final n = widget.groups.length;
    final heights = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      heights[i] = _rowHeight(
        widget.groups[i],
        i == index,
        maxWidth,
        baseStyle,
        textScaler,
      );
    }
    final tops = List<double>.filled(n, 0);
    var acc = 0.0;
    for (var i = 0; i < n; i++) {
      tops[i] = acc;
      acc += heights[i];
    }
    final layout = _LyricsLayout(heights: heights, tops: tops, total: acc);
    _layoutKey = key;
    _layout = layout;
    return layout;
  }

  /// 单行渲染高度：先查有界缓存（同文本 / 样式 / 宽度 / 文本缩放下高度
  /// 不变），未命中再实测。缓存仅存放结果，不改变任何布局语义。
  double _rowHeight(
    LyricGroup g,
    bool isCurrent,
    double maxWidth,
    TextStyle base,
    TextScaler textScaler,
  ) {
    final key = _LyricsRowHeightKey(
      text: g.original.text,
      // 仅当前行使用翻译/音译；其余行归一为 null 以提升命中率。
      translation: isCurrent ? g.translation : null,
      romaji: isCurrent ? g.romaji : null,
      isCurrent: isCurrent,
      fontSize: widget.fontSize,
      lineHeight: widget.lineHeight,
      maxWidth: maxWidth,
      showTranslation: widget.showTranslation,
      showRomanization: widget.showRomanization,
      fontWeight: widget.fontWeight,
      currentFontSize: widget.currentFontSize,
      inactiveFontWeight: widget.inactiveFontWeight,
      textAlign: widget.textAlign,
      baseStyle: base,
      textScaler: textScaler,
    );
    final cached = _rowHeightCache.remove(key);
    if (cached != null) {
      _rowHeightCache[key] = cached; // 命中 → 移到末尾（最近使用）。
      return cached;
    }
    final height = _measureRowHeight(g, isCurrent, maxWidth, base, textScaler);
    if (_rowHeightCache.length >= _kLyricsRowHeightCacheMax) {
      _rowHeightCache.remove(_rowHeightCache.keys.first); // 淘汰最旧一项。
    }
    _rowHeightCache[key] = height;
    return height;
  }

  /// 实测单行渲染高度：主行 +（当前行）音译 / 翻译小字 + 竖直内边距，
  /// 且不小于设置行高 [LyricsView.lineHeight]。与 [_Line] 的布局结构保持
  /// 一致，保证滚动定位精确。
  double _measureRowHeight(
    LyricGroup g,
    bool isCurrent,
    double maxWidth,
    TextStyle base,
    TextScaler textScaler,
  ) {
    _measuredLines += 1;
    final fs = isCurrent
        ? (widget.currentFontSize ?? widget.fontSize + 3)
        : widget.fontSize;
    final main = _layoutPainter(
      TextSpan(
        text: g.original.text,
        style: base.copyWith(
          fontSize: fs,
          fontWeight: isCurrent ? widget.fontWeight : widget.inactiveFontWeight,
        ),
      ),
      maxWidth,
      textScaler,
      widget.textAlign,
    );
    var h = main.height;
    final subFs = math.max(9.0, widget.fontSize * kTranslationFontScale);
    final gap = math.max(2.0, widget.fontSize * kMainTranslationGapEm);
    if (isCurrent &&
        widget.showRomanization &&
        (g.romaji?.isNotEmpty ?? false)) {
      final sub = _layoutPainter(
        TextSpan(
          text: g.romaji!,
          style: base.copyWith(fontSize: subFs, height: 1.2),
        ),
        maxWidth,
        textScaler,
        widget.textAlign,
      );
      h += gap + sub.height;
    }
    if (isCurrent &&
        widget.showTranslation &&
        (g.translation?.isNotEmpty ?? false)) {
      final sub = _layoutPainter(
        TextSpan(
          text: g.translation!,
          style: base.copyWith(fontSize: subFs, height: 1.2),
        ),
        maxWidth,
        textScaler,
        widget.textAlign,
      );
      h += gap + sub.height;
    }
    return math.max(widget.lineHeight, h + 4); // + Container 竖直内边距
  }

  TextPainter _layoutPainter(
    TextSpan span,
    double maxWidth,
    TextScaler textScaler,
    TextAlign align,
  ) {
    return TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textAlign: align,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
  }
}

/// 计算后的整首歌词布局：每行高度、累计 top（相对内容起点）、总高度。
@immutable
class _LyricsLayout {
  const _LyricsLayout({
    required this.heights,
    required this.tops,
    required this.total,
  });

  final List<double> heights;
  final List<double> tops;
  final double total;
}

/// [_rowHeight] 缓存容量上限（简单有界，避免歌词行数很大时无界增长）。
const int _kLyricsRowHeightCacheMax = 256;

/// [_rowHeight] 的缓存键：仅包含会影响实测高度的输入（文本 / 翻译 /
/// 是否当前行 / 字号 / 行高 / 可用宽度 / 是否显示翻译 / 默认字体样式 /
/// 文本缩放 / 对齐）。任一输入变化即键失配，等价于失效重算。
@immutable
class _LyricsRowHeightKey {
  const _LyricsRowHeightKey({
    required this.text,
    required this.translation,
    required this.romaji,
    required this.isCurrent,
    required this.fontSize,
    required this.lineHeight,
    required this.maxWidth,
    required this.showTranslation,
    required this.showRomanization,
    required this.fontWeight,
    required this.currentFontSize,
    required this.inactiveFontWeight,
    required this.textAlign,
    required this.baseStyle,
    required this.textScaler,
  });

  final String text;
  final String? translation;
  final String? romaji;
  final bool isCurrent;
  final double fontSize;
  final double lineHeight;
  final double maxWidth;
  final bool showTranslation;
  final bool showRomanization;
  final FontWeight fontWeight;
  final double? currentFontSize;
  final FontWeight inactiveFontWeight;
  final TextAlign textAlign;
  final TextStyle baseStyle;
  final TextScaler textScaler;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _LyricsRowHeightKey &&
        other.text == text &&
        other.translation == translation &&
        other.romaji == romaji &&
        other.isCurrent == isCurrent &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.maxWidth == maxWidth &&
        other.showTranslation == showTranslation &&
        other.showRomanization == showRomanization &&
        other.fontWeight == fontWeight &&
        other.currentFontSize == currentFontSize &&
        other.inactiveFontWeight == inactiveFontWeight &&
        other.textAlign == textAlign &&
        other.baseStyle == baseStyle &&
        other.textScaler == textScaler;
  }

  @override
  int get hashCode => Object.hash(
    text,
    translation,
    romaji,
    isCurrent,
    fontSize,
    lineHeight,
    maxWidth,
    showTranslation,
    showRomanization,
    fontWeight,
    currentFontSize,
    inactiveFontWeight,
    textAlign,
    baseStyle,
    textScaler,
  );
}

/// 单行渲染（当前行的连续扫亮 / 翻译 / 音译 / 进度指示）。
class _Line extends StatelessWidget {
  const _Line({
    required this.group,
    required this.isCurrent,
    required this.positionMs,
    required this.endMs,
    required this.focus,
    required this.edgeAlpha,
    required this.fontSize,
    required this.lineHeight,
    this.playedColor,
    this.unplayedColor,
    this.showTranslation = true,
    this.showRomanization = false,
    this.fontWeight = FontWeight.w600,
    this.currentFontSize,
    this.inactiveFontWeight = FontWeight.w400,
    this.inactiveScale = 1.0,
    this.unplayedAlpha = 0.55,
    this.textAlign = TextAlign.center,
    this.onTap,
  });

  final LyricGroup group;
  final bool isCurrent;
  final int positionMs;
  final int endMs;
  final double focus;
  final double edgeAlpha;
  final double fontSize;
  final double lineHeight;
  final Color? playedColor;
  final Color? unplayedColor;
  final bool showTranslation;
  final bool showRomanization;
  final FontWeight fontWeight;
  final double? currentFontSize;
  final FontWeight inactiveFontWeight;
  final double inactiveScale;
  final double unplayedAlpha;
  final TextAlign textAlign;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = DefaultTextStyle.of(context).style;
    final played = playedColor ?? scheme.primary;
    final unplayed = unplayedColor ?? scheme.onSurfaceVariant;
    final styleFs = isCurrent ? (currentFontSize ?? fontSize + 3) : fontSize;
    final weight = isCurrent ? fontWeight : inactiveFontWeight;
    // 非当前行最多只「借」到 45% 已唱色，避免中间行抢焦点。
    final mix = isCurrent ? 1.0 : focus * 0.45;
    final mainColor = Color.lerp(unplayed, played, mix)!.withValues(
      alpha:
          (isCurrent ? 1.0 : unplayedAlpha + (1 - unplayedAlpha) * focus) *
          edgeAlpha,
    );
    final mainStyle = base.copyWith(
      fontSize: styleFs,
      fontWeight: weight,
      color: mainColor,
      shadows: isCurrent && edgeAlpha > 0.35
          ? [
              Shadow(
                color: played.withValues(alpha: 0.24 * edgeAlpha),
                blurRadius: 14,
              ),
            ]
          : null,
    );

    final original = (isCurrent && (group.fragments?.isNotEmpty ?? false))
        ? Text.rich(
            _karaokeSpan(group, played, unplayed, edgeAlpha),
            textAlign: textAlign,
            style: mainStyle,
          )
        : Text(group.original.text, textAlign: textAlign, style: mainStyle);

    final subFs = math.max(9.0, fontSize * kTranslationFontScale);
    final gap = math.max(2.0, fontSize * kMainTranslationGapEm);
    final translation =
        (isCurrent && showTranslation && group.translation != null)
        ? Text(
            group.translation!,
            textAlign: textAlign,
            style: TextStyle(
              fontSize: subFs,
              height: 1.2,
              color: played.withValues(alpha: 0.75 * edgeAlpha),
            ),
          )
        : null;
    final romanization = (isCurrent && showRomanization && group.romaji != null)
        ? Text(
            group.romaji!,
            textAlign: textAlign,
            style: TextStyle(
              fontSize: subFs,
              height: 1.2,
              color: played.withValues(alpha: 0.6 * edgeAlpha),
            ),
          )
        : null;

    final cross = textAlign == TextAlign.left
        ? CrossAxisAlignment.start
        : textAlign == TextAlign.right
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.center;
    final align = textAlign == TextAlign.left
        ? Alignment.centerLeft
        : textAlign == TextAlign.right
        ? Alignment.centerRight
        : Alignment.center;

    final scale = isCurrent ? 1.0 : inactiveScale + (1 - inactiveScale) * focus;

    Widget? progressBar;
    if (isCurrent && endMs > group.original.timeMs) {
      final p =
          ((positionMs - group.original.timeMs) /
                  (endMs - group.original.timeMs))
              .clamp(0.0, 1.0);
      if (p > 0.001) {
        progressBar = Container(
          width: 44 * p,
          height: 2,
          decoration: BoxDecoration(
            color: played.withValues(alpha: 0.45 * edgeAlpha),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }
    }

    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          alignment: align,
          // 固定行高改为最小行高：长行换行后可自然增高，不再截断。
          constraints: BoxConstraints(minHeight: lineHeight),
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Transform.scale(
            scale: scale,
            alignment: align,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: cross,
                  children: [
                    original,
                    if (romanization != null) ...[
                      SizedBox(height: gap),
                      romanization,
                    ],
                    if (translation != null) ...[
                      SizedBox(height: gap),
                      translation,
                    ],
                  ],
                ),
                if (progressBar != null)
                  Positioned(bottom: 0, child: progressBar),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 连续扫亮：每个片段按自身时长从「未唱」插值到「已唱」，而不是
  /// 「唱到就整字换色」。长音字会平滑地亮过去。
  TextSpan _karaokeSpan(
    LyricGroup group,
    Color played,
    Color unplayed,
    double edgeAlpha,
  ) {
    final frags = group.fragments!;
    final children = <InlineSpan>[];
    for (var i = 0; i < frags.length; i++) {
      final f = frags[i];
      final start = group.original.timeMs + f.startMs;
      var dur = f.durationMs ?? 0;
      if (dur <= 0) {
        dur = i + 1 < frags.length
            ? math.max(1, frags[i + 1].startMs - f.startMs)
            : math.max(1, endMs - start);
      }
      final t = ((positionMs - start) / dur).clamp(0.0, 1.0).toDouble();
      final mix = 0.28 + 0.72 * t;
      final c = Color.lerp(
        unplayed,
        played,
        mix,
      )!.withValues(alpha: (0.55 + 0.45 * t) * edgeAlpha);
      children.add(
        TextSpan(
          text: f.text,
          style: TextStyle(color: c),
        ),
      );
    }
    return TextSpan(children: children);
  }
}

class _EmptyLyrics extends StatelessWidget {
  const _EmptyLyrics();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            EtaIcons.fileMusicOutline,
            size: 42,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            context.l10n.commonNoLyrics,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

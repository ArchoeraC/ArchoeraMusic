// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_view.dart';

extension _LyricsViewBuild on _LyricsViewState {
  Widget _buildLyricsView(BuildContext context) {
    if (widget.groups.isEmpty) return const _EmptyLyrics();

    return LayoutBuilder(
      builder: (context, constraints) {
        final index = lyricIndexAt(widget.groups, widget.positionMs);
        // 滚动目标提前于高亮行：开唱前先把下一行滚到中心（`lyric-dom`
        // 的 `applyScrollPreroll` 同思路，这里只做 500ms 提前量，不动数据）。
        final scrollIndex = lyricScrollIndexAt(
          widget.groups,
          widget.positionMs,
        );
        // 歌词行没有水平内边距，Text 的实际可用宽度就是视口宽度。
        // （旧实现按 -24 测量行高，与渲染宽度不一致，长行会多算行数。）
        final viewWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 800.0;
        final maxWidth = math.max(40.0, viewWidth);
        // 用环境默认字体（含主题字体/回退链）实测，保证换行点与渲染一致。
        final baseStyle = DefaultTextStyle.of(context).style;
        final textScaler = MediaQuery.textScalerOf(context);
        final balanceWidth = maxWidth;
        // 行内容 / 宽度 / 字号字重 / 字体变化时才重新平衡；当前行翻转不参与，
        // 避免每次换行都重新排版整首歌词。
        // 用「当前行样式」平衡：这样换行点在行成为当前行（轻微放大）后不变。
        final balanceStyle = baseStyle.copyWith(
          fontSize:
              widget.currentFontSize ?? widget.fontSize * kActiveLineFontScale,
          fontWeight: widget.fontWeight,
        );
        final balanceKey = (
          groups: widget.groups,
          width: balanceWidth,
          style: balanceStyle,
          textScaler: textScaler,
        );
        if (_balanceKey != balanceKey) {
          _balanceKey = balanceKey;
          _balanced = [
            for (final group in widget.groups)
              balanceLyricLine(
                group,
                maxWidth: balanceWidth,
                style: balanceStyle,
                textScaler: textScaler,
              ),
          ];
          _lineCache.clear();
        }
        final balanced = _balanced!;
        // 行高列表按需重算：位置 tick（~20Hz）不改变行高，只有「当前行翻转 /
        // 滚动目标变化 / 分组 / 宽度 / 样式 / 点击可用性」变化时才重算。
        final heightsKey = (
          groups: widget.groups,
          balanced: balanced,
          width: maxWidth,
          fontSize: widget.fontSize,
          lineHeight: widget.lineHeight,
          showTranslation: widget.showTranslation,
          showRomanization: widget.showRomanization,
          fontWeight: widget.fontWeight,
          currentFontSize: widget.currentFontSize,
          inactiveFontWeight: widget.inactiveFontWeight,
          baseStyle: baseStyle,
          textScaler: textScaler,
          index: index,
          scrollIndex: scrollIndex,
          hasSeek: widget.onSeek != null,
        );
        if (_heightsKey != heightsKey) {
          _heightsKey = heightsKey;
          _heights = <double>[
            for (var i = 0; i < widget.groups.length; i++)
              _rowHeight(
                widget.groups[i],
                balanced[i],
                // 滚动目标行按「即将成为当前行」的样式度量（轻微放大 / 译文），
                // 提前滚动后开唱时正好居中，不会因行高变大而偏移。
                i == index || i == scrollIndex,
                maxWidth,
                baseStyle,
                textScaler,
              ),
          ];
          // 当前行翻转 / 配置变化：非当前行的缓存实例一律作废。
          _lineCache.clear();
        }
        final heights = _heights!;
        // 目标偏移始终更新：用户手动浏览期间也跟随播放进度移动，
        // 3 秒后恢复跟随时直接滚到最新位置。
        final anchor = scrollIndex < 0 ? 0 : scrollIndex;
        final followOffset = _offsetFor(anchor, heights, constraints.maxHeight);
        _followOffset = followOffset;
        final targetChanged = scrollIndex != _scrollIndex;
        _scrollIndex = scrollIndex;
        if (!_userScrolling && targetChanged) {
          _scrollToOffset(followOffset);
        }
        final half = constraints.maxHeight / 2;
        final pad = half - widget.lineHeight / 2;
        final list = NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // 滚轮弹簧 / 拖拽都会更新用户滚动方向；程序化 animateTo 不会。
            if (notification is UserScrollNotification) {
              if (notification.direction == ScrollDirection.idle) {
                _endUserScroll();
              } else {
                _beginUserScroll();
              }
            } else if (notification is ScrollEndNotification) {
              _endUserScroll();
            }
            return false;
          },
          child: ScrollConfiguration(
            behavior: const _NoScrollbarBehavior(),
            child: ListView.builder(
              controller: _controller,
              padding: EdgeInsets.symmetric(vertical: pad < 0 ? 0 : pad),
              itemCount: widget.groups.length,
              // 不设固定 itemExtent：长行换行后行高可变（对齐 AMLL）。
              itemBuilder: (context, i) {
                // 非当前行：命中缓存则返回同一实例——Element 对 identical
                // widget 直接短路，位置 tick（~20Hz）不再重建/重绘这些行。
                if (i != index) {
                  final cached = _lineCache[i];
                  if (cached != null) return cached;
                }
                final group = widget.groups[i];
                final line = _Line(
                  group: group,
                  line: balanced[i],
                  isCurrent: i == index,
                  positionMs: widget.positionMs,
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
                );
                if (i != index) _lineCache[i] = line;
                return line;
              },
            ),
          ),
        );
        if (!widget.fadeEdges) return list;
        // 与 SPlayer `.lyric-area` 相同的 10% / 25% 非线性渐隐。
        return LyricsEdgeFade(child: list);
      },
    );
  }

  /// 单行渲染高度：先查有界缓存（同文本 / 样式 / 宽度 / 文本缩放下高度
  /// 不变），未命中再实测。缓存仅存放结果，不改变任何布局语义。
  double _rowHeight(
    LyricGroup g,
    BalancedLyric line,
    bool isCurrent,
    double maxWidth,
    TextStyle base,
    TextScaler textScaler,
  ) {
    final key = _LyricsRowHeightKey(
      text: line.text,
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
      baseStyle: base,
      textScaler: textScaler,
    );
    final cached = _rowHeightCache.remove(key);
    if (cached != null) {
      _rowHeightCache[key] = cached; // 命中 → 移到末尾（最近使用）。
      return cached;
    }
    final height = _measureRowHeight(
      g,
      line,
      isCurrent,
      maxWidth,
      base,
      textScaler,
    );
    if (_rowHeightCache.length >= _kLyricsRowHeightCacheMax) {
      _rowHeightCache.remove(_rowHeightCache.keys.first); // 淘汰最旧一项。
    }
    _rowHeightCache[key] = height;
    return height;
  }

  /// 实测单行渲染高度：主行（当前行放大加粗）+（当前行）翻译小字 + 竖直
  /// 内边距，且不小于设置行高 [LyricsView.lineHeight]。与 [_Line] 的布局结构
  /// 保持一致，保证滚动定位精确。
  double _measureRowHeight(
    LyricGroup g,
    BalancedLyric line,
    bool isCurrent,
    double maxWidth,
    TextStyle base,
    TextScaler textScaler,
  ) {
    final fs = isCurrent
        ? (widget.currentFontSize ?? widget.fontSize * kActiveLineFontScale)
        : widget.fontSize;
    final main = TextPainter(
      text: TextSpan(
        text: line.text,
        style: base.copyWith(
          fontSize: fs,
          fontWeight: isCurrent ? widget.fontWeight : widget.inactiveFontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: widget.textAlign,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    var h = main.height;
    main.dispose();
    if (isCurrent &&
        widget.showTranslation &&
        (g.translation?.isNotEmpty ?? false)) {
      final sub = TextPainter(
        text: TextSpan(
          text: g.translation!,
          style: base.copyWith(
            fontSize: math.max(9.0, widget.fontSize * kTranslationFontScale),
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        textScaler: textScaler,
      )..layout(maxWidth: maxWidth);
      h += math.max(2, widget.fontSize * kMainTranslationGapEm) + sub.height;
      sub.dispose();
    }
    if (isCurrent &&
        widget.showRomanization &&
        (g.romaji?.isNotEmpty ?? false)) {
      final sub = TextPainter(
        text: TextSpan(
          text: g.romaji!,
          style: base.copyWith(
            fontSize: math.max(9.0, widget.fontSize * kTranslationFontScale),
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        textScaler: textScaler,
      )..layout(maxWidth: maxWidth);
      h += math.max(2, widget.fontSize * kMainTranslationGapEm) + sub.height;
      sub.dispose();
    }
    return math.max(widget.lineHeight, h + 4); // + Container 竖直内边距
  }

  /// 目标行居中所需的滚动偏移（含 ListView 顶部对称留白）。
  double _offsetFor(int index, List<double> heights, double viewH) {
    var acc = 0.0;
    for (var i = 0; i < index && i < heights.length; i++) {
      acc += heights[i];
    }
    final pad = math.max(0.0, viewH / 2 - widget.lineHeight / 2);
    final center =
        pad + acc + (index < heights.length ? heights[index] / 2 : 0.0);
    return math.max(0.0, center - viewH / 2);
  }
}

/// 当前行字号相对非当前行的倍率。
///
/// 旧实现固定 `+3px`：默认 18px 时放大 16.7%，大字号时又几乎不变，
/// 视觉重量偏重且不随字号收敛。改为固定 5% 的轻微放大，配合主色与
/// 非当前行透明度层级，已经足够区分当前行。
const double kActiveLineFontScale = 1.05;

/// 滚动预滚提前量（毫秒）：下一行开始前多久启动滚动。
///
/// 对齐 `lyric-dom` 的 `advanceNoOverlap`（600ms），但本引擎的滚动动画
/// 只有 280ms，500ms 已足够让当前行在开唱时就位，且不会在很短的换行
/// 间隔里连续触发。
const int kLyricsScrollPrerollMs = 500;

/// 逐字扫亮的预滚上限（毫秒）：在字/词开始前就开始染色，
/// 让相邻字的高亮边缘衔接而不是硬切（对齐 `lyric-kit` 的 `sweep`）。
const int kLyricWordSweepPreRollMs = 80;

/// 由播放位置求「滚动目标行」：当前行之后 500ms 内将要开始的行。
///
/// 与 [lyricIndexAt]（高亮行）分离：高亮严格按时间，滚动提前。
/// 无歌词返回 -1；首句之前锚定第 0 行。
int lyricScrollIndexAt(List<LyricGroup> groups, int positionMs) {
  if (groups.isEmpty) return -1;
  final current = lyricIndexAt(groups, positionMs);
  if (current < 0) return 0;
  for (var i = current + 1; i < groups.length; i++) {
    final start = groups[i].original.timeMs;
    // 同时间的背景行 / 重复行不推进滚动目标。
    if (start <= positionMs) continue;
    return start - positionMs <= kLyricsScrollPrerollMs ? i : current;
  }
  return current;
}

/// 逐字扫亮进度（0~1）：按片段时长连续插值，带 80ms 上限的预滚。
///
/// 与 `lyric-kit` 的 `getWordSweepProgress` 一致：
/// `adjustedStart = max(行首, 字首 - min(80, 时长 × 0.3))`。
/// 片段无时长时退化为「到点即亮」，与旧行为兼容。
double lyricWordSweepProgress(
  LyricGroup group,
  LyricFragment fragment,
  int positionMs,
) {
  final start = group.original.timeMs + fragment.startMs;
  final duration = fragment.durationMs ?? 0;
  if (duration <= 0) return positionMs >= start ? 1.0 : 0.0;
  final preRoll = math.min(kLyricWordSweepPreRollMs, duration * 0.3);
  final adjustedStart = math.max(group.original.timeMs, start - preRoll);
  final adjustedDuration = math.max(1, start + duration - adjustedStart);
  return ((positionMs - adjustedStart) / adjustedDuration)
      .clamp(0.0, 1.0)
      .toDouble();
}

/// [_rowHeight] 缓存容量上限（简单有界，避免歌词行数很大时无界增长）。
const int _kLyricsRowHeightCacheMax = 256;

/// [_rowHeight] 的缓存键：仅包含会影响实测高度的输入（文本 / 翻译 /
/// 是否当前行 / 字号 / 行高 / 可用宽度 / 是否显示翻译 / 默认字体样式 /
/// 文本缩放）。任一输入变化即键失配，等价于失效重算。
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
    baseStyle,
    textScaler,
  );
}

class _Line extends StatelessWidget {
  const _Line({
    required this.group,
    required this.line,
    required this.isCurrent,
    required this.positionMs,
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
    this.unplayedAlpha = 0.35,
    this.textAlign = TextAlign.center,
    this.onTap,
  });

  final LyricGroup group;

  /// 平衡换行后的显示内容（含逐字片段；未平衡时与 [group] 原文一致）。
  final BalancedLyric line;
  final bool isCurrent;
  final int positionMs;
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
    final lineColor = playedColor ?? scheme.primary;
    final dimColor = (unplayedColor ?? scheme.onSurfaceVariant).withValues(
      alpha: unplayedAlpha,
    );

    final original = isCurrent && (line.fragments?.isNotEmpty ?? false)
        ? _KaraokeLineText(
            group: group,
            line: line,
            positionMs: positionMs,
            played: lineColor,
            textAlign: textAlign,
          )
        : Text(line.text, textAlign: textAlign);
    final translation =
        (isCurrent && showTranslation && group.translation != null)
        ? Text(
            group.translation!,
            textAlign: textAlign,
            style: TextStyle(
              fontSize: math.max(9.0, fontSize * kTranslationFontScale),
              height: 1.2,
              color: lineColor.withValues(alpha: 0.75),
            ),
          )
        : null;
    final romanization = (isCurrent && showRomanization && group.romaji != null)
        ? Text(
            group.romaji!,
            textAlign: textAlign,
            style: TextStyle(
              fontSize: math.max(9.0, fontSize * kTranslationFontScale),
              height: 1.2,
              color: lineColor.withValues(alpha: 0.6),
            ),
          )
        : null;

    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedDefaultTextStyle(
          // 与 `lyric-dom` 的行激活 / 失活过渡同量级（250ms 左右）：
          // 颜色、字重、字号一起缓动，换行时不再有整行瞬切。
          duration: animDuration(context, const Duration(milliseconds: 260)),
          curve: Curves.easeOutCubic,
          style: isCurrent
              ? TextStyle(
                  fontSize: currentFontSize ?? fontSize * kActiveLineFontScale,
                  fontWeight: fontWeight,
                  color: lineColor,
                )
              : TextStyle(
                  fontSize: fontSize,
                  fontWeight: inactiveFontWeight,
                  color: dimColor,
                ),
          child: AnimatedScale(
            duration: animDuration(context, const Duration(milliseconds: 260)),
            curve: Curves.easeOutCubic,
            // 左/右对齐时以对应边为缩放原点，避免文字整体向内缩。
            alignment: switch (textAlign) {
              TextAlign.left || TextAlign.start => Alignment.centerLeft,
              TextAlign.right || TextAlign.end => Alignment.centerRight,
              _ => Alignment.center,
            },
            scale: isCurrent ? 1.0 : inactiveScale,
            child: Container(
              alignment: textAlign == TextAlign.left
                  ? Alignment.centerLeft
                  : textAlign == TextAlign.right
                  ? Alignment.centerRight
                  : Alignment.center,
              // 固定行高改为最小行高：长行换行后可自然增高，不再截断。
              constraints: BoxConstraints(minHeight: lineHeight),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                // TextAlign 只作用于单个 Text 内部；原文/音译/翻译跨行排列时
                // 还要让 Column 的交叉轴跟随同一方向，否则译文仍会居中。
                crossAxisAlignment: textAlign == TextAlign.left
                    ? CrossAxisAlignment.start
                    : textAlign == TextAlign.right
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.center,
                children: [
                  original,
                  if (romanization != null) ...[
                    SizedBox(
                      height: math.max(2, fontSize * kMainTranslationGapEm),
                    ),
                    romanization,
                  ],
                  if (translation != null) ...[
                    SizedBox(
                      height: math.max(2, fontSize * kMainTranslationGapEm),
                    ),
                    translation,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyLyrics extends StatelessWidget {
  const _EmptyLyrics();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        context.l10n.commonNoLyrics,
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _NoScrollbarBehavior extends ScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

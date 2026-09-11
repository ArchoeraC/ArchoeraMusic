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
        final maxWidth = math.max(40.0, constraints.maxWidth - 24);
        // 用环境默认字体（含主题字体/回退链）实测，保证换行点与渲染一致。
        final baseStyle = DefaultTextStyle.of(context).style;
        // 实测每行高度（长行换行后可变），用于滚动定位。
        final heights = <double>[
          for (var i = 0; i < widget.groups.length; i++)
            _rowHeight(widget.groups[i], i == index, maxWidth, baseStyle),
        ];
        if (index != _current) {
          _current = index;
          // index < 0：播放位置早于第一句（循环回放 / 前奏）——锚定首行。
          final anchor = index < 0 ? 0 : index;
          _scrollToOffset(_offsetFor(anchor, heights, constraints.maxHeight));
        }
        final half = constraints.maxHeight / 2;
        final pad = half - widget.lineHeight / 2;
        return ScrollConfiguration(
          behavior: const _NoScrollbarBehavior(),
          child: ListView.builder(
            controller: _controller,
            padding: EdgeInsets.symmetric(vertical: pad < 0 ? 0 : pad),
            itemCount: widget.groups.length,
            // 不设固定 itemExtent：长行换行后行高可变（对齐 AMLL）。
            itemBuilder: (context, i) {
              final group = widget.groups[i];
              return _Line(
                group: group,
                isCurrent: i == index,
                positionMs: widget.positionMs,
                fontSize: widget.fontSize,
                lineHeight: widget.lineHeight,
                playedColor: widget.playedColor,
                unplayedColor: widget.unplayedColor,
                showTranslation: widget.showTranslation,
                onTap: widget.onSeek == null
                    ? null
                    : () => widget.onSeek!(group.original.timeMs),
              );
            },
          ),
        );
      },
    );
  }

  /// 单行渲染高度：主行（当前行放大加粗）+（当前行）翻译小字 + 竖直内边距，
  /// 且不小于设置行高 [LyricsView.lineHeight]。与 [_Line] 的布局结构保持一致，
  /// 保证滚动定位精确。
  double _rowHeight(
    LyricGroup g,
    bool isCurrent,
    double maxWidth,
    TextStyle base,
  ) {
    final fs = isCurrent ? widget.fontSize + 3 : widget.fontSize;
    final main = TextPainter(
      text: TextSpan(
        text: g.original.text,
        style: base.copyWith(
          fontSize: fs,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: maxWidth);
    var h = main.height;
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
      )..layout(maxWidth: maxWidth);
      h += math.max(2, widget.fontSize * kMainTranslationGapEm) + sub.height;
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

class _Line extends StatelessWidget {
  const _Line({
    required this.group,
    required this.isCurrent,
    required this.positionMs,
    required this.fontSize,
    required this.lineHeight,
    this.playedColor,
    this.unplayedColor,
    this.showTranslation = true,
    this.onTap,
  });

  final LyricGroup group;
  final bool isCurrent;
  final int positionMs;
  final double fontSize;
  final double lineHeight;
  final Color? playedColor;
  final Color? unplayedColor;
  final bool showTranslation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = group.original;
    final lineColor = playedColor ?? scheme.primary;
    final dimColor = (unplayedColor ?? scheme.onSurfaceVariant).withValues(
      alpha: 0.55,
    );

    final original = isCurrent
        ? _karaokeSpan(base, group.fragments, lineColor)
        : Text(base.text, textAlign: TextAlign.center);
    final translation =
        (isCurrent && showTranslation && group.translation != null)
        ? Text(
            group.translation!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: math.max(9.0, fontSize * kTranslationFontScale),
              height: 1.2,
              color: lineColor.withValues(alpha: 0.75),
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
          duration: animDuration(context, const Duration(milliseconds: 180)),
          curve: Curves.easeOut,
          style: isCurrent
              ? TextStyle(
                  fontSize: fontSize + 3,
                  fontWeight: FontWeight.w600,
                  color: lineColor,
                )
              : TextStyle(fontSize: fontSize, color: dimColor),
          child: Container(
            alignment: Alignment.center,
            // 固定行高改为最小行高：长行换行后可自然增高，不再截断。
            constraints: BoxConstraints(minHeight: lineHeight),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                original,
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
    );
  }

  Widget _karaokeSpan(
    LyricLine line,
    List<LyricFragment>? fragments,
    Color played,
  ) {
    if (fragments == null || fragments.isEmpty) {
      return Text(line.text, textAlign: TextAlign.center);
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final f in fragments)
            TextSpan(
              text: f.text,
              style: TextStyle(
                color: (line.timeMs + f.startMs) <= positionMs
                    ? played
                    : played.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
      textAlign: TextAlign.center,
    );
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
            AppLocalizations.of(context).commonNoLyrics,
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

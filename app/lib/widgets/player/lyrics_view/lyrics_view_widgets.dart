// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_view.dart';

extension _LyricsViewBuild on _LyricsViewState {
  Widget _buildLyricsView(BuildContext context) {
    if (widget.groups.isEmpty) return const _EmptyLyrics();

    final index = lyricIndexAt(widget.groups, widget.positionMs);
    if (index != _current) {
      _current = index;
      _scrollToIndex(index);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final half = constraints.maxHeight / 2;
        final pad = half - widget.lineHeight / 2;
        return ScrollConfiguration(
          behavior: const _NoScrollbarBehavior(),
          child: ListView.builder(
            controller: _controller,
            padding: EdgeInsets.symmetric(vertical: pad < 0 ? 0 : pad),
            itemCount: widget.groups.length,
            itemExtent: widget.lineHeight,
            itemBuilder: (context, i) {
              final group = widget.groups[i];
              final isCurrent = i == index;
              return _Line(
                group: group,
                isCurrent: isCurrent,
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
        : Text(
            base.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );
    final translation =
        (isCurrent && showTranslation && group.translation != null)
        ? Text(
            group.translation!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
            height: lineHeight,
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
      return Text(
        line.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      );
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
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
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

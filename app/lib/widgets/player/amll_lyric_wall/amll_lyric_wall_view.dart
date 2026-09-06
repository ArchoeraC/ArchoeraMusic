// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../amll_lyric_wall.dart';

extension _AmllLyricWallView on _AmllLyricWallState {
  void _ensureVisible(int index) {
    if (!_controller.hasClients) return;
    final target = (index * widget.lineHeight)
        .clamp(0.0, _controller.position.maxScrollExtent)
        .toDouble();
    final first = !_everPlaced;
    _everPlaced = true;
    final dist = (target - _controller.offset).abs();
    final viewH = _viewH > 0 ? _viewH : 400.0;
    final longJump = dist > viewH * 1.2;
    if (!widget.animate || first || longJump) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  Widget _buildAmllLyricWall(BuildContext context) {
    final groups = widget.groups;
    if (groups.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final rawH = constraints.maxHeight;
        final viewH = (rawH.isFinite && rawH > 0) ? rawH : 400.0;
        final lineH = widget.lineHeight.clamp(8, 400).toDouble();
        if (viewH != _viewH) {
          _viewH = viewH;
          final a = widget.alignFraction.clamp(0.1, 0.9);
          _padTop = math.max(0.0, a * viewH - lineH / 2);
          _padBottom = math.max(0.0, (1 - a) * viewH - lineH / 2);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_controller.hasClients) return;
            _controller.jumpTo(
              (_current * lineH)
                  .clamp(0.0, _controller.position.maxScrollExtent)
                  .toDouble(),
            );
          });
        }

        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: const [0.0, 0.15, 0.85, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ScrollConfiguration(
            behavior: _NoScrollbarBehavior(),
            child: ListView.builder(
              controller: _controller,
              itemExtent: lineH,
              padding: EdgeInsets.only(top: _padTop, bottom: _padBottom),
              physics: const BouncingScrollPhysics(),
              itemCount: groups.length,
              itemBuilder: (context, i) => _buildRow(groups[i], i),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(LyricGroup group, int index) {
    final isCurrent = index == _current;
    final isPassed = _current >= 0 && index < _current;
    if (widget.hidePassed && isPassed) return const SizedBox.shrink();

    final played = widget.playedColor;
    final dist = (_current - index).abs().toDouble();
    final lineAlpha = isCurrent
        ? 1.0
        : math
              .max(
                widget.inactiveAlpha.clamp(0.0, 1.0),
                1 - (math.max(0.0, dist - 1) * 0.35),
              )
              .clamp(0.0, 1.0);
    final lineColor = isCurrent
        ? played
        : widget.unplayedColor.withValues(alpha: lineAlpha);
    final rowScale = isCurrent || !widget.enableScale
        ? 1.0
        : math.max(0.9, 1 - math.max(0.0, dist - 1) * 0.025);

    final Widget original = isCurrent
        ? _currentSpan(group, played)
        : Text(
            group.original.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );

    final translation =
        (isCurrent &&
            widget.showTranslation &&
            group.translation != null &&
            group.translation!.isNotEmpty)
        ? Text(
            group.translation!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: widget.fontSize - 4,
              color: played.withValues(alpha: 0.75),
            ),
          )
        : null;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSeek(group.original.timeMs),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          style: isCurrent
              ? TextStyle(
                  fontSize: widget.fontSize + 3,
                  fontWeight: FontWeight.w600,
                  color: played,
                )
              : TextStyle(
                  fontSize: widget.fontSize,
                  fontWeight: FontWeight.w400,
                  color: lineColor,
                ),
          child: Container(
            alignment: Alignment.center,
            height: widget.lineHeight,
            child: Transform.scale(
              scale: rowScale,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  original,
                  if (translation != null) ...[
                    const SizedBox(height: 2),
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

  Widget _currentSpan(LyricGroup group, Color played) {
    final frags = group.fragments;
    if (!widget.wordSweep || frags == null || frags.isEmpty) {
      return Text(
        group.original.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final f in frags) _fragSpan(f, group.original.timeMs, played),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
  }

  TextSpan _fragSpan(LyricFragment f, int lineStart, Color played) {
    final abs = lineStart + f.startMs;
    final dur = (f.durationMs != null && f.durationMs! > 0)
        ? f.durationMs!
        : 500;
    final Color c;
    if (widget.positionMs < abs) {
      c = played.withValues(alpha: 0.4);
    } else if (widget.positionMs >= abs + dur) {
      c = played;
    } else {
      c = Color.lerp(
        played.withValues(alpha: 0.4),
        played,
        (widget.positionMs - abs) / dur,
      )!;
    }
    return TextSpan(
      text: f.text,
      style: TextStyle(color: c),
    );
  }
}

class _NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

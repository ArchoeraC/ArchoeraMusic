// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../bar_lyric_text.dart';

extension _BarLyricTextView on _BarLyricTextState {
  Widget _buildBarLyricText(BuildContext context) {
    final positionMs = ref.watch(
      playbackProvider.select((s) => s.position.inMilliseconds),
    );
    final prefs = ref.watch(appPrefsProvider);
    final showTranslation = prefs.showTranslation;
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);

    final idx = lyricIndexAt(groups, positionMs);
    if (idx < 0) return SizedBox(height: widget.height);
    if (idx != _lastIdx) {
      _lastIdx = idx;
      _animMs = 120 + _rand.nextInt(121);
    }

    final g = groups[idx];
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 11,
      height: 1,
      color: scheme.primary,
      fontWeight: FontWeight.w500,
    );

    final fragments = g.fragments;
    final useKaraoke =
        prefs.barEnhancedLyrics && fragments != null && fragments.isNotEmpty;
    final transText =
        (showTranslation && g.translation != null && g.translation!.isNotEmpty)
        ? g.translation!
        : '';
    final TextSpan span;
    if (useKaraoke) {
      span = TextSpan(
        style: style,
        children: [
          for (final f in fragments)
            TextSpan(
              text: f.text,
              style: TextStyle(
                color: (g.original.timeMs + f.startMs) <= positionMs
                    ? scheme.primary
                    : scheme.primary.withValues(alpha: 0.4),
              ),
            ),
        ],
      );
    } else {
      final text = transText.isNotEmpty
          ? '${g.original.text}（$transText）'
          : g.original.text;
      if (text.isEmpty) return SizedBox(height: widget.height);
      span = TextSpan(text: text, style: style);
    }

    return SizedBox(
      height: widget.height,
      child: AnimatedSwitcher(
        duration: animDuration(context, const Duration(milliseconds: 250)),
        reverseDuration: animDuration(
          context,
          const Duration(milliseconds: 150),
        ),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.4),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
        child: LayoutBuilder(
          key: ValueKey('$idx:${g.original.text}:$transText'),
          builder: (context, constraints) {
            final painter = TextPainter(
              text: span,
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            if (painter.width > constraints.maxWidth) {
              if (useKaraoke) {
                return _KaraokeFollow(
                  span: span,
                  textWidth: painter.width,
                  playedWidth: _playedTextWidth(
                    style,
                    fragments,
                    g.original.timeMs,
                    positionMs,
                  ),
                  maxWidth: constraints.maxWidth,
                  rightPadding: style.fontSize! * 0.3,
                  animMs: _animMs,
                );
              }
              return _Marquee(text: span.toPlainText(), span: span);
            }
            return Align(
              alignment: Alignment.centerRight,
              child: Text.rich(
                span,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _KaraokeFollow extends StatelessWidget {
  const _KaraokeFollow({
    required this.span,
    required this.textWidth,
    required this.playedWidth,
    required this.maxWidth,
    required this.rightPadding,
    required this.animMs,
  });

  final TextSpan span;
  final double textWidth;
  final double playedWidth;
  final double maxWidth;
  final double rightPadding;
  final int animMs;

  @override
  Widget build(BuildContext context) {
    final dx = (maxWidth / 2 - playedWidth)
        .clamp(-(textWidth - maxWidth + rightPadding), 0)
        .toDouble();
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: dx),
        duration: Duration(milliseconds: animMs),
        curve: Curves.easeOut,
        builder: (context, value, child) => OverflowBox(
          alignment: Alignment.centerLeft,
          maxWidth: double.infinity,
          child: Transform.translate(offset: Offset(value, 0), child: child),
        ),
        child: Padding(
          padding: EdgeInsets.only(right: rightPadding),
          child: Text.rich(span, maxLines: 1),
        ),
      ),
    );
  }
}

class _Marquee extends StatefulWidget {
  const _Marquee({required this.text, required this.span});

  final String text;
  final TextSpan span;

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee>
    with SingleTickerProviderStateMixin {
  static const double _gap = 50;
  static const double _speed = 30;

  late final AnimationController _ctrl;
  Timer? _startTimer;
  double? _textWidth;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _startTimer = Timer(const Duration(milliseconds: 2000), _start);
  }

  @override
  void didUpdateWidget(_Marquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    _startTimer?.cancel();
    _ctrl
      ..stop()
      ..value = 0;
    _textWidth = null;
    _startTimer = Timer(const Duration(milliseconds: 2000), _start);
    setState(() {});
  }

  void _start() {
    if (!mounted) return;
    final painter = TextPainter(
      text: widget.span,
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = painter.width;
    _ctrl.duration = Duration(
      milliseconds: ((painter.width + _gap) / _speed * 1000).round(),
    );
    _ctrl.repeat();
    setState(() {});
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final w = _textWidth ?? 0;
          final dx = w <= 0 ? 0.0 : -_ctrl.value * (w + _gap);
          return OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: Transform.translate(
              offset: Offset(dx, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(widget.span, maxLines: 1),
                  const SizedBox(width: _gap),
                  Text.rich(widget.span, maxLines: 1),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

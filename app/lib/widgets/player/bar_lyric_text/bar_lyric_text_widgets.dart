// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../bar_lyric_text.dart';

extension _BarLyricTextView on _BarLyricTextState {
  Widget _buildBarLyricText(BuildContext context) {
    final positionMs = ref.watch(
      playbackProvider.select((s) => s.position.inMilliseconds),
    );
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final prefs = ref.watch(appPrefsProvider);
    final showTranslation = prefs.showTranslation;
    final groups =
        ref.watch(currentLyricsProvider).value ??
        const <LyricGroup>[];

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
      // 1.0 行高会把拉丁字母的升部/降部（b/g/y 及重音）裁掉；1.2 与
      // 迷你区高度（见 _barInfoHeight）配合，中英日文字形都能完整显示。
      height: 1.2,
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
      child: _LyricRoll(
        index: idx,
        lineKey: '$idx:${g.original.text}:$transText',
        duration: animDuration(context, const Duration(milliseconds: 220)),
        child: LayoutBuilder(
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
              return _Marquee(
                text: span.toPlainText(),
                span: span,
                playing: playing,
              );
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

/// 歌词换行过渡：旧行滚出、新行滚入（竖向平移）。
///
/// 与「淡入淡出切换」不同，这里两行沿**同一方向**同时平移（旧行滚出视口、
/// 新行从另一侧滚入），形成「整条歌词滚动一行」的观感。前进时向上滚
/// （新行自下方滚入），后退 seek 时方向相反。
///
/// 每次换行只播放**一次性** [AnimationController.forward]（`from: 0`），
/// 不 `repeat`；性能模式（时长归零）下直接交换、不保留旧行。
class _LyricRoll extends StatefulWidget {
  const _LyricRoll({
    required this.child,
    required this.lineKey,
    required this.index,
    required this.duration,
  });

  /// 当前行的渲染体。
  final Widget child;

  /// 当前行身份（行号 + 文本）；变化即触发滚动过渡。
  final Object lineKey;

  /// 当前行序号，用于判定滚动方向（前进 / 倒退）。
  final int index;

  /// 一次性滚动时长；[Duration.zero] 表示直接切换（性能模式）。
  final Duration duration;

  @override
  State<_LyricRoll> createState() => _LyricRollState();
}

class _LyricRollState extends State<_LyricRoll>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// 正在滚出的旧行（连同其身份键）；为 null 表示停在当前行。
  Widget? _outgoing;
  Object? _outgoingKey;

  /// true：向上滚（新行自下方入）；false：向下滚（新行自上方入）。
  bool _rollUp = true;

  @override
  void initState() {
    super.initState();
    // 初值 1（已完成）：首帧即停在当前行，不做入场动画。
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1,
    )..addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && _outgoing != null) {
      setState(() => _outgoing = null);
    }
  }

  @override
  void didUpdateWidget(_LyricRoll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lineKey == oldWidget.lineKey) return;
    if (widget.duration == Duration.zero) {
      // 性能模式：直接交换，不保留旧行，也不启动动画。
      _outgoing = null;
      _outgoingKey = null;
      return;
    }
    // 旧行交给过渡；新行从另一侧滚入。方向按行号增减判定。
    _outgoing = oldWidget.child;
    _outgoingKey = oldWidget.lineKey;
    _rollUp = widget.index >= oldWidget.index;
    _ctrl
      ..duration = widget.duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          // easeOutCubic：起步快、收尾稳，读起来像「滚过去」而非「弹过去」。
          final t = Curves.easeOutCubic.transform(_ctrl.value);
          // 新行位移：前进时 1→0（自下方上移入位），倒退时 -1→0。
          final incoming = _rollUp ? 1 - t : t - 1;
          // 旧行位移：前进时 0→-1（向上滚出），倒退时 0→1。
          final outgoing = _rollUp ? -t : t;
          return Stack(
            fit: StackFit.passthrough,
            children: [
              if (_outgoing != null)
                KeyedSubtree(
                  key: ValueKey(_outgoingKey),
                  child: FractionalTranslation(
                    translation: Offset(0, outgoing),
                    child: _outgoing,
                  ),
                ),
              KeyedSubtree(
                key: ValueKey(widget.lineKey),
                child: FractionalTranslation(
                  translation: Offset(0, incoming),
                  child: widget.child,
                ),
              ),
            ],
          );
        },
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
  const _Marquee({
    required this.text,
    required this.span,
    required this.playing,
  });

  final String text;
  final TextSpan span;

  /// 播放中才循环滚动；暂停时停表冻结当前位移，避免空闲持续出帧。
  final bool playing;

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
    if (widget.playing) {
      _startTimer = Timer(const Duration(milliseconds: 2000), _start);
    }
  }

  @override
  void didUpdateWidget(_Marquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _startTimer?.cancel();
      _startTimer = null;
      _ctrl
        ..stop()
        ..value = 0;
      _textWidth = null;
      if (widget.playing) {
        _startTimer = Timer(const Duration(milliseconds: 2000), _start);
      }
      setState(() {});
      return;
    }
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        // 恢复播放：已测宽则接续滚动，否则重新走延迟启动。
        if (_textWidth != null) {
          _ctrl.repeat();
        } else {
          _startTimer?.cancel();
          _startTimer = Timer(const Duration(milliseconds: 2000), _start);
        }
      } else {
        // 暂停：停表冻结（ticker 不再请求帧）。
        _startTimer?.cancel();
        _startTimer = null;
        _ctrl.stop();
      }
    }
  }

  void _start() {
    if (!mounted || !widget.playing) return;
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

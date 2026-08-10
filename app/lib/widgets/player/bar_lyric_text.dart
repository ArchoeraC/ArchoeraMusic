/// 播放条迷你歌词（时间下方；有歌词时替代迷你频谱）。
///
/// 显示当前行「原文（翻译）」；文本超宽时循环滚动（对齐 SPlayer-Next
/// SMarquee：速度 30px/s、延迟 2s 启动、两段间距 50px）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/lyrics/lyric_line.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../stores/lyrics_provider.dart';
import '../common/anim.dart';

/// 迷你歌词（固定高度；无当前行时返回空占位，交由调用方回退频谱）。
class BarLyricText extends ConsumerStatefulWidget {
  const BarLyricText({super.key, required this.height});

  final double height;

  @override
  ConsumerState<BarLyricText> createState() => _BarLyricTextState();
}

class _BarLyricTextState extends ConsumerState<BarLyricText> {
  @override
  Widget build(BuildContext context) {
    final positionMs = ref.watch(
      playbackProvider.select((s) => s.position.inMilliseconds),
    );
    final prefs = ref.watch(appPrefsProvider);
    final showTranslation = prefs.showTranslation;
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);

    // 无歌词 / 播放位置早于首句（前奏）：空占位（调用方回退频谱或留白）
    final idx = lyricIndexAt(groups, positionMs);
    if (idx < 0) return SizedBox(height: widget.height);

    final g = groups[idx];
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 11,
      height: 1,
      color: scheme.primary,
      fontWeight: FontWeight.w500,
    );

    // 高级歌词（YRC/KRC 逐字片段）且「播放条高级歌词」开启：
    // 卡拉OK 逐字高亮（已唱实色 / 未唱 40% 透明度），翻译弱化追加；
    // 否则整行普通文本（原文 + 可选翻译）。
    final fragments = g.fragments;
    final useKaraoke =
        prefs.barEnhancedLyrics && fragments != null && fragments.isNotEmpty;
    final transText = (showTranslation &&
            g.translation != null &&
            g.translation!.isNotEmpty)
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
          if (transText.isNotEmpty)
            TextSpan(
              text: '（$transText）',
              style: TextStyle(
                color: scheme.primary.withValues(alpha: 0.45),
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

    // 歌词行切换动效（对齐 SPlayer-Next TrackInfo slide-up：进入 250ms
    // 从下方 4px 滑入 + 淡入，退出 150ms；性能模式动效归零）
    return SizedBox(
      height: widget.height,
      child: AnimatedSwitcher(
        duration: animDuration(context, const Duration(milliseconds: 250)),
        reverseDuration: animDuration(context, const Duration(milliseconds: 150)),
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
          // 行变化（含翻译开关切换）才触发过渡：以「索引 + 原文 + 翻译」为
          // key，同一行重复播放（同 key）不闪动
          key: ValueKey('$idx:${g.original.text}:$transText'),
          builder: (context, constraints) {
            final painter = TextPainter(
              text: span,
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            // 超宽：循环滚动（对齐 SMarquee overflow → scrolling）
            if (painter.width > constraints.maxWidth) {
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

/// 循环滚动富文本（溢出才渲染本组件；延迟 2s 启动，30px/s，间距 50px）。
///
/// [text] 仅用于行切换比对（卡拉OK 高亮下每 50ms 重建 span，颜色变化
/// 不重置滚动；[span] 为实际渲染内容）。
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
  static const double _speed = 30; // px/s，对齐 SMarquee speed: 30

  late final AnimationController _ctrl;
  Timer? _startTimer;

  /// 文本实际宽度（动画总位移 = 文本宽 + 间距）。
  double? _textWidth;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 5));
    // 对齐 SMarquee delay: 2000：先静止展示 2s，再开始循环滚动
    _startTimer = Timer(const Duration(milliseconds: 2000), _start);
  }

  /// 歌词行切换（文本变化）时重置动画：对齐 SMarquee 在 TrackInfo 中以
  /// `:key="lyric-${lyricIndex}"` 重建组件——重新延迟 2s 静止展示新行，
  /// 再从头循环滚动；否则新文本会以滚动中途状态出现（动效生硬）。
  @override
  void didUpdateWidget(_Marquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    _startTimer?.cancel();
    _ctrl
      ..stop()
      ..value = 0;
    _textWidth = null;
    // 重新延迟启动（先静止看清整行，再开始滚动）
    _startTimer = Timer(const Duration(milliseconds: 2000), _start);
    // _ctrl.stop() 不触发 AnimatedBuilder 重绘，手动重建以清除旧位移
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
          // 静止期（未开始滚动）显示首段
          final dx = w <= 0 ? 0.0 : -_ctrl.value * (w + _gap);
          // OverflowBox：放宽宽度约束，滚动文本（宽于父容器）不触发
          // debug 下的 RenderFlex 横向 overflow 警告；配合外层 ClipRect 裁剪。
          // alignment 取 centerLeft，静止期文本从左侧起始展示。
          return OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: Transform.translate(
              offset: Offset(dx, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(widget.span, maxLines: 1),
                  SizedBox(width: _gap),
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

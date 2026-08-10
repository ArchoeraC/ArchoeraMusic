/// 播放条迷你歌词（时间下方；有歌词时替代迷你频谱）。
///
/// 显示当前行「原文（翻译）」；文本超宽时循环滚动（对齐 SPlayer-Next
/// SMarquee：速度 30px/s、延迟 2s 启动、两段间距 50px）。
library;

import 'dart:async';
import 'dart:math';

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
  final Random _rand = Random();

  /// 本行滚动态效时长（ms）：歌词行切换时取 120~240ms 随机值，避免所有
  /// 行同一节奏；行内保持该值，TweenAnimationBuilder 每帧以当前值追赶新
  /// 目标位移，时长不变则动画不重置。
  int _animMs = 180;
  int _lastIdx = -1;

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
    if (idx != _lastIdx) {
      _lastIdx = idx;
      _animMs = 120 + _rand.nextInt(121); // 120 ~ 240
    }

    final g = groups[idx];
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 11,
      height: 1,
      color: scheme.primary,
      fontWeight: FontWeight.w500,
    );

    // 高级歌词（YRC/KRC 逐字片段）且「播放条高级歌词」开启：
    // 卡拉OK 逐字高亮（已唱实色 / 未唱 40% 透明度），此时相对禁用翻译
    // （翻译无逐字时间轴、会混入滚动基准，干扰卡拉OK 高亮）；
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
            // 超宽：
            // - 卡拉OK 模式：跟随播放进度平移，当前唱到的字保持水平居中；
            // - 普通模式：循环滚动（对齐 SMarquee overflow → scrolling）。
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
                  // em 单位右端安全间距（借鉴 SPlayer-Next Electron 桌面
                  // 歌词 has-mask 的 `padding: 0.25em 0.4em`，取 0.3em）
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

/// 卡拉OK 模式下已唱片段（`lineStartMs + f.startMs <= positionMs`）的累计
/// 文本宽度，用于跟随滚动时定位"当前字"的水平位置。
double _playedTextWidth(
  TextStyle style,
  List<LyricFragment> fragments,
  int lineStartMs,
  int positionMs,
) {
  final played = StringBuffer();
  for (final f in fragments) {
    if (lineStartMs + f.startMs <= positionMs) played.write(f.text);
  }
  if (played.isEmpty) return 0;
  return (TextPainter(
    text: TextSpan(text: played.toString(), style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout())
      .width;
}

/// 卡拉OK 超宽跟随滚动（三段式，对齐主流卡拉OK 歌词行为）：
/// - 开头：已唱不足半屏前，文本左对齐静止展示（dx = 0）；
/// - 中部：已唱过半屏后，当前高亮字随进度保持水平居中；
/// - 末尾：唱到尾字时文本右端停在「容器右缘 − em 安全间距」处，视觉上
///   仍贴齐时间「最后一位」。位移经 [TweenAnimationBuilder] 平滑过渡。
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

  /// 右端安全间距（em 单位，随字号/字体缩放自适应）：滚动终点文本右端
  /// 停在容器右缘内侧该宽度处，末字 ink（right bearing，会超出布局
  /// advance 约 1~2px）不被 ClipRect 裁掉最右一列像素。借鉴 SPlayer-Next
  /// Electron 桌面歌词 has-mask 的 `padding: 0.25em 0.4em`——用字体排版
  /// 单位而非固定 px（实测 Flutter 公开 API 拿不到字形 ink 边界）。
  final double rightPadding;

  /// 本行滚动态效时长（ms）：行切换时随机 120~240ms，行内保持恒定。
  final int animMs;

  @override
  Widget build(BuildContext context) {
    // 播放头居中 → 已唱宽；clamp 到 [−(文本宽−容器宽+em 间距), 0]：
    // 上界 0 保证开头静止时文本左对齐；下界保证唱完时末字完整贴齐时间右缘。
    final dx = (maxWidth / 2 - playedWidth)
        .clamp(-(textWidth - maxWidth + rightPadding), 0)
        .toDouble();
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: dx),
        duration: Duration(milliseconds: animMs),
        curve: Curves.easeOut,
        builder: (context, value, child) => OverflowBox(
          // 放宽水平约束：单行文本按自然宽度布局（宽于父容器），
          // 配合外层 ClipRect 裁剪；alignment centerLeft 起始展示文本开头。
          alignment: Alignment.centerLeft,
          maxWidth: double.infinity,
          child: Transform.translate(
            offset: Offset(value, 0),
            child: child,
          ),
        ),
        child: Padding(
          // em 右间距计入文本整体宽度：滚动终点 padding 右端贴容器右缘，
          // 文本（含末字 ink）落在右缘内侧，完整显示且与时间右缘贴齐。
          padding: EdgeInsets.only(right: rightPadding),
          child: Text.rich(span, maxLines: 1),
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

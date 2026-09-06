/// AMLL 歌词墙引擎 —— 稳定实现（行渲染对齐原版 LyricsView 的中文/居中逻辑）。
///
/// 滚动通道：ListView + ScrollController（可回滚、无上漂）。当前行默认锚定
/// 视口 50%（可经 alignFraction 调节）。行渲染照搬原版 _Line：
///   Container(height=lineHeight, alignment:center) + 居中 Column；
///   AnimatedDefaultTextStyle：当前行 fontSize+3 / w600 / 主色，非当前行
///   fontSize / 未唱色×inactiveAlpha；翻译小字 fontSize-4、主色×0.75；
///   有字级片段 → 卡拉 OK 逐字（已唱实色/未唱主色×0.4），无片段整行文本；
///   点击行 seek。
/// 顶部叠加上下渐隐 ShaderMask；性能模式走瞬移。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/lyrics/lyric_line.dart';

/// AMLL 弹簧预设保留。
const Map<String, (double, double, double)> amllSpringPresets = {
  'default': (1.0, 24.0, 180.0),
  'smooth': (1.0, 18.0, 110.0),
  'responsive': (1.0, 30.0, 420.0),
  'jello': (1.2, 8.0, 130.0),
  'heavy': (2.4, 20.0, 120.0),
};

class AmllLyricWall extends StatefulWidget {
  const AmllLyricWall({
    super.key,
    required this.groups,
    required this.positionMs,
    required this.onSeek,
    this.fontSize = 18,
    this.lineHeight = 52,
    this.playedColor = const Color(0xFF4DA3FF),
    this.unplayedColor = const Color(0xFF9AA1B5),
    this.showTranslation = true,
    this.alignFraction = 0.5,
    this.inactiveAlpha = 0.45,
    this.wordSweep = true,
    this.hidePassed = false,
    this.enableScale = true,
    this.springPreset = 'default',
    this.animate = true,
  });

  final List<LyricGroup> groups;
  final int positionMs;
  final ValueChanged<int> onSeek;

  final double fontSize;
  final double lineHeight;
  final Color playedColor;
  final Color unplayedColor;
  final bool showTranslation;

  /// 激活行锚定（0~1，默认 0.5 = 视口居中，同原版）。
  final double alignFraction;

  /// 非当前行透明度（0~1，默认 0.45，可读性同原版 0.55 档）。
  final double inactiveAlpha;

  /// 逐字卡拉 OK。
  final bool wordSweep;

  /// 隐藏已唱过的行。
  final bool hidePassed;

  /// 非当前行缩小（默认 0.97）。
  final bool enableScale;

  /// 弹簧预设（保留）。
  final String springPreset;

  /// false = 性能模式：瞬移。
  final bool animate;

  @override
  State<AmllLyricWall> createState() => _AmllLyricWallState();
}

class _AmllLyricWallState extends State<AmllLyricWall> {
  late final ScrollController _controller;
  int _current = -1;
  double _viewH = 0;
  double _padTop = 0;
  double _padBottom = 0;
  bool _everPlaced = false;

  int get _activeIndex => lyricIndexAt(widget.groups, widget.positionMs);

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _current = _activeIndex;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AmllLyricWall oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idx = _activeIndex;
    if (idx != _current || oldWidget.groups != widget.groups) {
      _current = idx;
      _ensureVisible(idx);
    }
  }

  /// 定位到行：始终走动画（含切歌/断点续播后的首次换行，700ms 生效）；
  /// 仅在首次挂载或长距离跳转（seek/换歌跨屏）时瞬移，避免飞渡。
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
      // 换行过渡加长：歌词墙的整屏滚动应有“从容上移”的时长感
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
    // 距离梯度：越靠近当前行越亮、越远越淡（收敛到 inactiveAlpha）
    final dist = (_current - index).abs().toDouble();
    final lineAlpha = isCurrent
        ? 1.0
        : math.max(
            widget.inactiveAlpha.clamp(0.0, 1.0),
            1 - (math.max(0.0, dist - 1) * 0.35),
          ).clamp(0.0, 1.0);
    final lineColor = isCurrent
        ? played
        : widget.unplayedColor.withValues(alpha: lineAlpha);
    final rowScale = isCurrent || !widget.enableScale
        ? 1.0
        : math.max(0.9, 1 - math.max(0.0, dist - 1) * 0.025);

    final Widget original;
    if (isCurrent) {
      original = _currentSpan(group, played);
    } else {
      original = Text(
        group.original.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      );
    }

    // 翻译：主色半透明小字（与原版一致：fontSize-4 / 主色×0.75）
    final translation =
        (isCurrent && widget.showTranslation && group.translation != null &&
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

  /// 当前行原文：有逐字 → 逐字渐变扫亮（未唱 主色×0.4 → 已唱 主色）；
  /// 无逐字 → 整行文本（普通模式，起唱即主色）。
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
    return TextSpan(text: f.text, style: TextStyle(color: c));
  }
}

/// 隐藏歌词滚动条（对齐原版 LyricsView 的视觉纯净处理）。
class _NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}


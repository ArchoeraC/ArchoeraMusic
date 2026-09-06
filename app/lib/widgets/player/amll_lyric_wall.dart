/// AMLL（Apple Music 风格歌词墙）引擎 —— 稳定实现。
///
/// 采用 ListView + ScrollController 的框架滚动通道（已验证稳定、可回滚），
/// 叠加 AMLL 观感层：激活行锚定于可调比例、行切换平滑滚动、非激活行
/// 按 inactiveAlpha 淡出并缩小、视口上下渐隐、逐字扫亮、翻译副行、点击 seek。
///
/// 与旧引擎并存切换（设置 → 歌词 → 引擎）。无第三方依赖。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/lyrics/lyric_line.dart';

/// AMLL 弹簧预设保留（供后续物理化参数使用）。
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
    this.alignFraction = 0.35,
    this.inactiveAlpha = 0.25,
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

  /// 激活行锚定（占歌词区高度比例，0~1）。
  final double alignFraction;

  /// 非激活行透明度（0~1）。
  final double inactiveAlpha;

  /// 逐字扫亮。
  final bool wordSweep;

  /// 隐藏已唱过的行。
  final bool hidePassed;

  /// 非激活行缩小（0.92）。
  final bool enableScale;

  /// 弹簧预设（保留字段）。
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
  bool _placed = false;

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
      _ensureVisible(idx, snap: !widget.animate || !_placed);
    }
  }

  void _ensureVisible(int index, {bool snap = false}) {
    if (!_controller.hasClients) return;
    final target = (index * widget.lineHeight)
        .clamp(0.0, _controller.position.maxScrollExtent)
        .toDouble();
    _placed = true;
    if (snap) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
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
            stops: const [0.0, 0.1, 0.9, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: _controller,
            itemExtent: lineH,
            padding: EdgeInsets.only(top: _padTop, bottom: _padBottom),
            physics: const BouncingScrollPhysics(),
            itemCount: groups.length,
            itemBuilder: (context, i) => _buildRow(groups[i], i, lineH),
          ),
        );
      },
    );
  }

  Widget _buildRow(LyricGroup group, int index, double lineH) {
    final active = _current >= 0 ? _current : -1;
    final isActive = index == active;
    final isPassed = active >= 0 && index < active;
    if (widget.hidePassed && isPassed) return const SizedBox.shrink();

    final Widget text;
    if (isActive) {
      text = _activeLineText(group);
    } else {
      text = Text(
        group.original.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: FontWeight.w400,
          color: widget.unplayedColor,
        ),
      );
    }

    final alpha = isActive ? 1.0 : widget.inactiveAlpha.clamp(0.0, 1.0);
    final scale = (!isActive && widget.enableScale) ? 0.92 : 1.0;

    return Center(
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: alpha,
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onTap: () => widget.onSeek(group.original.timeMs),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  text,
                  if (isActive &&
                      widget.showTranslation &&
                      group.translation != null &&
                      group.translation!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        group.translation!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: math.max(11, widget.fontSize * 0.5),
                          color: widget.unplayedColor.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _activeLineText(LyricGroup group) {
    final pos = widget.positionMs;
    final start = group.original.timeMs;
    final frags = group.fragments;
    final baseStyle = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w600,
    );

    if (!widget.wordSweep || frags == null || frags.isEmpty) {
      final played = pos >= start;
      return Text(
        group.original.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: baseStyle.copyWith(
          color: played ? widget.playedColor : widget.unplayedColor,
        ),
      );
    }

    final span = TextSpan(
      children: [for (final f in frags) _fragmentSpan(f, pos, start)],
    );
    return Text.rich(
      span,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: baseStyle,
    );
  }

  TextSpan _fragmentSpan(LyricFragment f, int pos, int lineStart) {
    final abs = lineStart + f.startMs;
    final dur = (f.durationMs != null && f.durationMs! > 0)
        ? f.durationMs!
        : 500;
    final style = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w600,
    );
    if (pos < abs) {
      return TextSpan(
        text: f.text,
        style: style.copyWith(color: widget.unplayedColor),
      );
    }
    if (pos >= abs + dur) {
      return TextSpan(
        text: f.text,
        style: style.copyWith(color: widget.playedColor),
      );
    }
    final t = (pos - abs) / dur;
    return TextSpan(
      text: f.text,
      style: style.copyWith(
        color: Color.lerp(widget.unplayedColor, widget.playedColor, t),
      ),
    );
  }
}

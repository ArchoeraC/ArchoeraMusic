/// 歌词滚动渲染组件（§10.2 UI 层；AMLL 观感简化版）。
///
/// 行为：当前行居中 + 主色放大高亮（周边行渐隐）；播放位置驱动
/// 自动滚动（行切换时一次动画）；点击行 → [onSeek]（毫秒）。
/// 增强歌词：当前行原文按逐字片段（YRC/KRC）做卡拉OK 高亮，
/// 翻译以次行小字显示（[LyricGroup.translation]）。
/// 数据为空时显示占位（对应 Web 端空态）。
///
/// 样式参数（字号 / 行高 / 已唱色 / 未唱色）由播放页从「设置 → 歌词」
/// 偏好传入（对齐原版 desktopLyric 的个性化配置）。
library;

import 'package:flutter/material.dart';

import '../../services/lyrics/lyric_line.dart';
import '../../l10n/generated/app_localizations.dart';
import '../common/anim.dart';

/// 歌词滚动渲染。
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.groups,
    required this.positionMs,
    this.onSeek,
    this.fontSize = 14,
    this.lineHeight = LyricsView.defaultLineHeight,
    this.playedColor,
    this.unplayedColor,
    this.showTranslation = true,
  });

  final List<LyricGroup> groups;

  /// 当前播放位置（毫秒）。
  final int positionMs;

  /// 点击歌词行 seek（参数 = 行起始毫秒）；null 禁用点击。
  final ValueChanged<int>? onSeek;

  /// 非当前行字号（px；设置「歌词字号」，默认 14）。
  final double fontSize;

  /// 行高（含间距；设置「歌词行距」，默认 44）。
  final double lineHeight;

  /// 当前行颜色（设置「已唱颜色」，默认跟随主题主色）。
  final Color? playedColor;

  /// 非当前行颜色（设置「未唱颜色」，默认主题次级前景）。
  final Color? unplayedColor;

  /// 显示翻译（当前行翻译次行小字；设置「显示翻译」，默认开）。
  final bool showTranslation;

  /// 行高默认值（含间距）。
  static const double defaultLineHeight = 44;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _controller = ScrollController();

  /// 当前行索引（避免每帧滚动）。
  int _current = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.groups.isEmpty) return _EmptyLyrics();

    final index = lyricIndexAt(widget.groups, widget.positionMs);
    if (index != _current) {
      _current = index;
      _scrollToIndex(index);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final half = constraints.maxHeight / 2;
        final pad = half - widget.lineHeight / 2;
        // 不显示滚动条（歌词区视觉纯净，滚动仍可用）
        return ScrollConfiguration(
          behavior: _NoScrollbarBehavior(),
          child: ListView.builder(
            controller: _controller,
            // 上下对称留白：首末行也能居中（避免最后几行沉到底部才滚动）
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

  void _scrollToIndex(int index) {
    // index < 0：播放位置早于第一句歌词（循环回放 / 前奏阶段）——
    // 也滚回首行，否则循环重新播放时歌词停留在上一轮最后位置
    final targetIndex = index < 0 ? 0 : index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 第 index 行中心滚到视口中心：滚动量恰为 index × 行高
      // （顶部对称留白 half - lineHeight/2 已把偏移抵消）
      final max = _controller.position.maxScrollExtent;
      final target = (targetIndex * widget.lineHeight).clamp(0.0, max);
      _controller.animateTo(
        target,
        duration: animDuration(
            context, const Duration(milliseconds: 280)),
        curve: Curves.easeOutCubic,
      );
    });
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
    final dimColor = (unplayedColor ?? scheme.onSurfaceVariant)
        .withValues(alpha: 0.55);

    final original = isCurrent
        ? _karaokeSpan(base, group.fragments, lineColor)
        : Text(
            base.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );
    // 当前行翻译：主色半透明小字（在原文下方）；无翻译或关闭翻译显示则无
    final translation =
        (isCurrent && showTranslation && group.translation != null)
            ? Text(
                group.translation!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: fontSize - 4,
                  color: lineColor.withValues(alpha: 0.75),
                ),
              )
            : null;

    return MouseRegion(
      cursor:
          onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedDefaultTextStyle(
          duration: animDuration(
              context, const Duration(milliseconds: 180)),
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
                  const SizedBox(height: 2),
                  translation,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 当前行原文：有逐字片段 → 卡拉OK 高亮（已唱实色 / 未唱半透明）；
  /// 无片段 → 整行实色文本。
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
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lyrics_outlined,
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

/// 不渲染滚动条的 ScrollBehavior（滚动功能保留，仅视觉隐藏）。
class _NoScrollbarBehavior extends ScrollBehavior {
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

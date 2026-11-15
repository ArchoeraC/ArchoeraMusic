// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 普通歌词的逐字扫亮：与 AMLL 歌词墙同一套**基础渐变**。
//
// 不再只做「整字透明度插值」，而是像歌词墙一样：
// - 整行先画未唱底（同一色相的暗态）；
// - 已唱的字/词叠一层已唱色；
// - 正在扫过的字/词用 x 方向线性渐变做羽化裁切（宽度 = 字号 × 0.5），
//   得到从头到尾连续推进的扫光，而不是整字跳色。
//
// 只做渐变，不加歌词墙的上浮 / 强调 / 缩放等额外特效。

part of '../lyrics_view.dart';

/// 扫亮羽化宽度（相对字号）：对齐歌词墙的 `wordFadeWidth = 0.5`。
const double kKaraokeWordFadeWidth = 0.5;

/// 自绘扫亮画布的 Key（测试定位用；同一时刻只有当前行会构建）。
const Key kKaraokePaintKey = ValueKey<String>('lyrics-karaoke-paint');

/// 当前行的逐字文本（含基础渐变扫亮）。
///
/// 只有带逐字片段且布局可映射到单行盒时走自绘；否则回退到
/// 按片段透明度插值的 [Text.rich]，保证任何歌词都能正常显示。
class _KaraokeLineText extends StatefulWidget {
  const _KaraokeLineText({
    required this.group,
    required this.line,
    required this.positionMs,
    required this.played,
    required this.textAlign,
  });

  final LyricGroup group;
  final BalancedLyric line;
  final int positionMs;
  final Color played;
  final TextAlign textAlign;

  @override
  State<_KaraokeLineText> createState() => _KaraokeLineTextState();
}

class _KaraokeLineTextState extends State<_KaraokeLineText> {
  _KaraokeLayout? _layout;
  Object? _key;

  @override
  void dispose() {
    _layout?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final defaultStyle = DefaultTextStyle.of(context);
    final style = defaultStyle.style;
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 800.0;
        // 字号动画期间按 0.25px 量化 + 去掉颜色（不影响排版），
        // 避免 260ms 过渡里每帧重建整行 + 每个片段的 TextPainter。
        final sizeStep = ((style.fontSize ?? 14) * 4).round();
        final keyStyle = style.merge(
          TextStyle(color: const Color(0x00000000), fontSize: sizeStep / 4),
        );
        final key = (
          text: widget.line.text,
          fragments: widget.line.fragments,
          style: keyStyle,
          textScaler: textScaler,
          maxWidth: maxWidth,
          textAlign: widget.textAlign,
          direction: direction,
          locale: locale,
          heightBehavior: defaultStyle.textHeightBehavior,
          played: widget.played,
        );
        if (_key != key) {
          _key = key;
          _layout?.dispose();
          _layout = _buildKaraokeLayout(
            line: widget.line,
            style: style,
            textScaler: textScaler,
            maxWidth: maxWidth,
            textAlign: widget.textAlign,
            direction: direction,
            locale: locale,
            heightBehavior: defaultStyle.textHeightBehavior,
            played: widget.played,
          );
        }
        final layout = _layout;
        if (layout == null) return _fallback();
        return CustomPaint(
          key: kKaraokePaintKey,
          size: Size(layout.width, layout.height),
          painter: _KaraokePainter(
            layout: layout,
            group: widget.group,
            positionMs: widget.positionMs,
            played: widget.played,
            feather: math.max(
              1.0,
              (style.fontSize ?? 14) * kKaraokeWordFadeWidth,
            ),
          ),
        );
      },
    );
  }

  Widget _fallback() {
    final fragments = widget.line.fragments;
    if (fragments == null || fragments.isEmpty) {
      return Text(widget.line.text, textAlign: widget.textAlign);
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final fragment in fragments)
            TextSpan(
              text: fragment.text,
              style: TextStyle(
                color: _karaokeWordColor(
                  widget.group,
                  fragment,
                  widget.positionMs,
                  widget.played,
                ),
              ),
            ),
        ],
      ),
      textAlign: widget.textAlign,
    );
  }
}

/// 构建一次自绘所需的两套段落与逐字盒；任何一步不成立都返回 null。
_KaraokeLayout? _buildKaraokeLayout({
  required BalancedLyric line,
  required TextStyle style,
  required TextScaler textScaler,
  required double maxWidth,
  required TextAlign textAlign,
  required TextDirection direction,
  required Locale? locale,
  required TextHeightBehavior? heightBehavior,
  required Color played,
}) {
  final fragments = line.fragments;
  if (fragments == null || fragments.isEmpty) return null;
  final joined = fragments.map((f) => f.text).join();
  if (joined != line.text) return null;

  final dim = TextPainter(
    text: TextSpan(
      text: line.text,
      style: style.copyWith(color: played.withValues(alpha: 0.4)),
    ),
    textDirection: direction,
    textAlign: textAlign,
    textScaler: textScaler,
    locale: locale,
    textHeightBehavior: heightBehavior,
  )..layout(maxWidth: maxWidth);
  if (dim.width <= 0 || dim.height <= 0) {
    dim.dispose();
    return null;
  }

  final items = <_KaraokeFragment>[];
  final lineMetrics = dim.computeLineMetrics();
  var offset = 0;
  for (final fragment in fragments) {
    final start = offset;
    offset += fragment.text.length;
    // 换行 / 空白片段不画（换行仍参与段落布局）。
    if (fragment.text.trim().isEmpty) continue;
    final boxes = dim.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: offset),
    );
    // 片段跨行时放弃自绘（常见于超长单词），回退整字插值。
    if (boxes.length != 1) {
      _disposeKaraokeItems(items);
      dim.dispose();
      return null;
    }
    final box = boxes.single.toRect();
    if (box.width <= 0 || box.height <= 0) {
      _disposeKaraokeItems(items);
      dim.dispose();
      return null;
    }
    final lit = TextPainter(
      text: TextSpan(
        text: fragment.text,
        style: style.copyWith(color: played),
      ),
      textDirection: direction,
      textScaler: textScaler,
      locale: locale,
      textHeightBehavior: heightBehavior,
    )..layout();
    // 片段自身排版宽度必须与整行中的盒一致，否则叠层会错位。
    if ((lit.width - box.width).abs() > 1.5) {
      lit.dispose();
      _disposeKaraokeItems(items);
      dim.dispose();
      return null;
    }
    // 按行基线对齐：混合字体（CJK 回退 / 拉丁）行高不同也能贴合。
    final baseline = _baselineForTop(lineMetrics, box.top);
    final litBaseline = lit.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    items.add(
      _KaraokeFragment(
        fragment: fragment,
        lit: lit,
        box: box,
        dy: baseline - litBaseline,
      ),
    );
  }

  return _KaraokeLayout(
    dim: dim,
    fragments: items,
    width: dim.width,
    height: dim.height,
  );
}

void _disposeKaraokeItems(List<_KaraokeFragment> items) {
  for (final item in items) {
    item.lit.dispose();
  }
}

/// 取 [top] 所在行的绝对基线（相对段落顶部）。
double _baselineForTop(List<ui.LineMetrics> metrics, double top) {
  if (metrics.isEmpty) return top;
  var lineTop = 0.0;
  for (final metric in metrics) {
    final lineBottom = lineTop + metric.height;
    if (top < lineBottom) return metric.baseline;
    lineTop = lineBottom;
  }
  return metrics.last.baseline;
}

class _KaraokeLayout {
  const _KaraokeLayout({
    required this.dim,
    required this.fragments,
    required this.width,
    required this.height,
  });

  final TextPainter dim;
  final List<_KaraokeFragment> fragments;
  final double width;
  final double height;

  void dispose() {
    dim.dispose();
    _disposeKaraokeItems(fragments);
  }
}

class _KaraokeFragment {
  const _KaraokeFragment({
    required this.fragment,
    required this.lit,
    required this.box,
    required this.dy,
  });

  final LyricFragment fragment;
  final TextPainter lit;
  final Rect box;

  /// 已唱片段相对段落顶部的绘制纵坐标（按行基线对齐）。
  final double dy;
}

class _KaraokePainter extends CustomPainter {
  const _KaraokePainter({
    required this.layout,
    required this.group,
    required this.positionMs,
    required this.played,
    required this.feather,
  });

  final _KaraokeLayout layout;
  final LyricGroup group;
  final int positionMs;
  final Color played;
  final double feather;

  @override
  void paint(Canvas canvas, Size size) {
    layout.dim.paint(canvas, Offset.zero);
    for (final item in layout.fragments) {
      final progress = lyricWordSweepProgress(group, item.fragment, positionMs);
      if (progress <= 0) continue;
      final box = item.box;
      if (progress >= 1) {
        item.lit.paint(canvas, Offset(box.left, item.dy));
        continue;
      }

      // 与歌词墙 `_drawSweepLit` 相同的渐变羽化：从左向右扫过字/词。
      final rect = Rect.fromLTWH(
        box.left - 1,
        item.dy - 1,
        box.width + 2,
        item.lit.height + 2,
      );
      final width = math.max(1.0, box.width);
      final featherPx = feather.clamp(1.0, width * 2);
      final head = width * progress.clamp(0.0, 1.0);
      var a = ((head - featherPx / 2) / width).clamp(0.0, 1.0);
      var b = ((head + featherPx / 2) / width).clamp(0.0, 1.0);
      if (b <= a) b = math.min(1.0, a + 1e-3);
      final shader = ui.Gradient.linear(
        Offset(box.left, item.dy),
        Offset(box.left + width, item.dy),
        const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        [a, b],
      );
      canvas.saveLayer(rect, Paint());
      item.lit.paint(canvas, Offset(box.left, item.dy));
      canvas.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = shader,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _KaraokePainter oldDelegate) =>
      oldDelegate.positionMs != positionMs ||
      oldDelegate.layout != layout ||
      oldDelegate.played != played ||
      oldDelegate.feather != feather;
}

/// 逐字扫亮的回退颜色（自绘不可用时）：未唱暗态 → 已唱色连续插值。
Color _karaokeWordColor(
  LyricGroup group,
  LyricFragment fragment,
  int positionMs,
  Color played,
) {
  final dim = played.withValues(alpha: 0.4);
  final t = lyricWordSweepProgress(group, fragment, positionMs);
  if (t <= 0) return dim;
  if (t >= 1) return played;
  return Color.lerp(dim, played, t)!;
}

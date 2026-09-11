// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_physics_wall.dart';

class _Painter extends CustomPainter {
  _Painter(this.c, Listenable repaint) : super(repaint: repaint);
  final _PaintCtx c;

  /// 文本可用宽度左右各留的边距（px）。
  static const double _widthPad = 24;

  @override
  void paint(Canvas canvas, Size size) {
    // 防御性取交集：y/heights/groups 任一失配（如换歌瞬间）都按最短绘制，
    // 避免越界崩溃。正常路径三者长度一致。
    final n = math.min(c.y.length, math.min(c.groups.length, c.heights.length));
    if (n == 0) return;
    final viewH = c.h > 0 ? c.h : size.height;
    final visible = <int>{};
    for (var i = 0; i < n; i++) {
      final cy = c.y[i];
      final half = c.heights[i] / 2;
      if (cy + half < 0 || cy - half > viewH) continue;
      if (c.hidePassed && c.active >= 0 && i < c.active) continue;
      visible.add(i);
      final g = c.groups[i];
      final isActive = i == c.active;
      final d = (i - c.active).abs().toDouble();
      final alpha = isActive
          ? 1.0
          : math
                .max(c.inactiveAlpha, 1 - (math.max(0.0, d - 1) * 0.35))
                .clamp(0.0, 1.0);
      final scale = isActive ? 1.0 : 0.97;
      _drawLine(canvas, g, i, cy, alpha, scale, isActive);
    }
    // 只缓存可见窗口 → 常驻内存 O(视口)，与歌长无关（§3.4）。
    c.cache.pruneTo(visible);
  }

  void _drawLine(
    Canvas canvas,
    LyricGroup g,
    int index,
    double centerY,
    double alpha,
    double scale,
    bool isActive,
  ) {
    final fs = c.fontSize;
    final maxWidth = math.max(40.0, c.w - _widthPad);
    final main = _mainParagraph(g, index, isActive, alpha, fs, maxWidth);
    // 去 saveLayer：透明行距/渐隐直接写进文字颜色（见 _mainParagraph），
    // 缩放用 canvas.scale，不再为每行开离屏渲染目标。
    canvas.save();
    canvas.translate(c.w / 2, centerY);
    canvas.scale(scale);
    canvas.translate(-main.width / 2, -main.height / 2);
    canvas.drawParagraph(main, Offset.zero);
    canvas.restore();

    final tr = g.translation;
    if (c.showTranslation && tr != null && tr.isNotEmpty) {
      final sub = _translationParagraph(
        tr,
        index,
        isActive,
        alpha,
        fs,
        maxWidth,
      );
      canvas.drawParagraph(
        sub,
        Offset(
          c.w / 2 - sub.width / 2,
          centerY + main.height / 2 + math.max(3.0, fs * kMainTranslationGapEm),
        ),
      );
    }
  }

  /// 主行段落：活跃逐字行颜色逐帧变化 → 每帧重建（仅 1 行）；其余走缓存复用。
  ui.Paragraph _mainParagraph(
    LyricGroup g,
    int index,
    bool isActive,
    double alpha,
    double fs,
    double maxWidth,
  ) {
    final frags = g.fragments;
    if (isActive && c.wordSweep && frags != null && frags.isNotEmpty) {
      final b = ui.ParagraphBuilder(_pStyle(c.fontFamily, fs, FontWeight.w600));
      b.pushStyle(_uiStyle(c.fontFamily, fs, FontWeight.w600, c.played));
      for (final f in frags) {
        b.pushStyle(
          _uiStyle(
            c.fontFamily,
            fs,
            FontWeight.w600,
            _fragColor(f, g.original.timeMs),
          ),
        );
        b.addText(f.text);
        b.pop();
      }
      b.pop();
      return _layout(b, maxWidth);
    }
    final weight = isActive ? FontWeight.w600 : FontWeight.w400;
    final color = isActive
        ? (c.positionMs >= g.original.timeMs ? c.played : c.unplayed)
        : c.unplayed.withValues(alpha: alpha);
    final key = (
      g.original.text,
      c.fontFamily,
      fs,
      weight.value,
      color.toARGB32(),
      maxWidth,
    );
    return c.cache.obtainMain(index, key, () {
      final b = ui.ParagraphBuilder(_pStyle(c.fontFamily, fs, weight));
      b.pushStyle(_uiStyle(c.fontFamily, fs, weight, color));
      b.addText(g.original.text);
      b.pop();
      return _layout(b, maxWidth);
    });
  }

  /// 翻译小字段落（颜色含透明度，替代 saveLayer）。
  ui.Paragraph _translationParagraph(
    String text,
    int index,
    bool isActive,
    double alpha,
    double fs,
    double maxWidth,
  ) {
    final color = isActive
        ? c.played.withValues(alpha: 0.8)
        : c.unplayed.withValues(alpha: alpha);
    final subFs = fs * kTranslationFontScale;
    final key = (text, c.fontFamily, subFs, color.toARGB32(), maxWidth);
    return c.cache.obtainTranslation(index, key, () {
      final b = ui.ParagraphBuilder(_pStyle(c.fontFamily, subFs, FontWeight.w400));
      b.pushStyle(_uiStyle(c.fontFamily, subFs, FontWeight.w400, color));
      b.addText(text);
      b.pop();
      return _layout(b, maxWidth);
    })!;
  }

  static ui.ParagraphStyle _pStyle(
    String? family,
    double fs,
    FontWeight w,
  ) => ui.ParagraphStyle(
    textAlign: ui.TextAlign.center,
    textDirection: ui.TextDirection.ltr,
    fontFamily: family,
    fontSize: fs,
    fontWeight: w,
  );

  static ui.TextStyle _uiStyle(
    String? family,
    double fs,
    FontWeight w,
    Color color,
  ) => ui.TextStyle(
    color: color,
    fontFamily: family,
    fontSize: fs,
    fontWeight: w,
  );

  static ui.Paragraph _layout(ui.ParagraphBuilder b, double maxWidth) {
    final p = b.build();
    p.layout(ui.ParagraphConstraints(width: maxWidth));
    return p;
  }

  Color _fragColor(LyricFragment f, int lineStart) {
    final abs = lineStart + f.startMs;
    final dur = (f.durationMs != null && f.durationMs! > 0)
        ? f.durationMs!
        : 500;
    if (c.positionMs < abs) return c.played.withValues(alpha: 0.4);
    if (c.positionMs >= abs + dur) return c.played;
    return Color.lerp(
      c.played.withValues(alpha: 0.4),
      c.played,
      (c.positionMs - abs) / dur,
    )!;
  }

  @override
  bool shouldRepaint(_Painter old) => false;
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

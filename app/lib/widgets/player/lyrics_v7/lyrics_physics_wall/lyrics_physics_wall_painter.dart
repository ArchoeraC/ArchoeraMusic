// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_physics_wall.dart';

class _Painter extends CustomPainter {
  _Painter(this.c, Listenable repaint) : super(repaint: repaint);
  final _PaintCtx c;

  @override
  void paint(Canvas canvas, Size size) {
    // 防御性取交集：y/heights/groups 任一失配（如换歌瞬间）都按最短绘制，
    // 避免越界崩溃。正常路径三者长度一致。
    final n = math.min(
      c.y.length,
      math.min(c.groups.length, c.heights.length),
    );
    if (n == 0) return;
    final viewH = c.h > 0 ? c.h : size.height;
    for (var i = 0; i < n; i++) {
      final cy = c.y[i];
      final half = c.heights[i] / 2;
      if (cy + half < 0 || cy - half > viewH) continue;
      final g = c.groups[i];
      final isActive = i == c.active;
      if (c.hidePassed && c.active >= 0 && i < c.active) continue;
      final d = (i - c.active).abs().toDouble();
      final alpha = isActive
          ? 1.0
          : math
                .max(c.inactiveAlpha, 1 - (math.max(0.0, d - 1) * 0.35))
                .clamp(0.0, 1.0);
      final scale = isActive ? 1.0 : 0.97;
      _drawLine(canvas, size, g, i, cy, alpha, scale, isActive);
    }
  }

  void _drawLine(
    Canvas canvas,
    Size size,
    LyricGroup g,
    int index,
    double centerY,
    double alpha,
    double scale,
    bool isActive,
  ) {
    final fs = c.fontSize;
    final main = _painterFor(g, isActive, fs);
    main.layout(maxWidth: math.max(40, c.w - 24));
    if (alpha < 0.999) {
      canvas.saveLayer(
        Rect.fromCenter(
          center: Offset(c.w / 2, centerY),
          width: main.width + 40,
          height: c.heights[index] + 20,
        ),
        Paint()..color = Color.fromRGBO(0, 0, 0, alpha),
      );
    }
    canvas.save();
    canvas.translate(c.w / 2, centerY);
    canvas.scale(scale);
    canvas.translate(-main.width / 2, -main.height / 2);
    main.paint(canvas, Offset.zero);
    canvas.restore();
    if (alpha < 0.999) canvas.restore();

    final tr = g.translation;
    if (c.showTranslation && (tr?.isNotEmpty ?? false)) {
      final sub = TextPainter(
        text: TextSpan(
          text: tr,
          style: TextStyle(
            fontFamily: c.fontFamily,
            fontSize: fs * kTranslationFontScale,
            color: isActive
                ? c.played.withValues(alpha: 0.8)
                : c.unplayed.withValues(alpha: alpha),
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(40, c.w - 24));
      sub.paint(
        canvas,
        Offset(
          c.w / 2 - sub.width / 2,
          centerY + main.height / 2 + math.max(3.0, fs * kMainTranslationGapEm),
        ),
      );
    }
  }

  TextPainter _painterFor(LyricGroup g, bool isActive, double fs) {
    if (isActive && c.wordSweep) {
      final frags = g.fragments;
      if (frags != null && frags.isNotEmpty) {
        return TextPainter(
          text: TextSpan(
            style: TextStyle(
              fontFamily: c.fontFamily,
              fontSize: fs,
              fontWeight: FontWeight.w600,
            ),
            children: [
              for (final f in frags)
                TextSpan(
                  text: f.text,
                  style: TextStyle(color: _fragColor(f, g.original.timeMs)),
                ),
            ],
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        );
      }
    }
    final color = isActive
        ? (c.positionMs >= g.original.timeMs ? c.played : c.unplayed)
        : c.unplayed;
    return TextPainter(
      text: TextSpan(
        text: g.original.text,
        style: TextStyle(
          fontFamily: c.fontFamily,
          fontSize: fs,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          color: color,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
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

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_physics_wall.dart';

class _Painter extends CustomPainter {
  _Painter(this.c, Listenable repaint) : super(repaint: repaint);
  final _PaintCtx c;

  /// 文本可用宽度左右各留的边距（px）。
  static const double _widthPad = 24;

  /// 激活行未唱部分的透明度（对齐 AMLL `--dark-mask-alpha`）。
  static const double _unsungAlpha = 0.4;

  /// 激活行已唱部分的透明度（对齐 AMLL `--bright-mask-alpha`）。
  static const double _litAlpha = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    // 防御性取交集：y/heights/groups 任一失配（如换歌瞬间）都按最短绘制，
    // 避免越界崩溃。正常路径三者长度一致。
    final n = math.min(c.y.length, math.min(c.groups.length, c.heights.length));
    if (n == 0) return;
    final viewH = c.h > 0 ? c.h : size.height;
    final visible = <int>{};
    final keepFrag = <int>{};
    final hideBoundary = c.active >= 0 ? c.active : (c.anchor + 1);
    for (var i = 0; i < n; i++) {
      final cy = c.y[i];
      final half = c.heights[i] / 2;
      if (cy + half < 0 || cy - half > viewH) continue;
      if (c.hidePassed && hideBoundary > 0 && i < hideBoundary) continue;
      visible.add(i);
      final fade = i < c.fade.length ? c.fade[i] : 0.0;
      // 淡出中的上一激活行仍需逐字渲染数据（否则会从扫亮态「啪」地变灰）。
      if (fade > 0.02) keepFrag.add(i);
      _drawLine(canvas, i, cy, fade);
    }
    _drawInterludeDots(canvas, viewH);
    // 只缓存可见窗口 → 常驻内存 O(视口)，与歌长无关（§3.4）。
    c.cache.pruneTo(visible);
    c.fragCache.pruneTo(keepFrag);
  }

  /// 间奏三点（对齐 AMLL interlude-dots：依次点亮 + 呼吸缩放 + 两段式退场）。
  void _drawInterludeDots(Canvas canvas, double viewH) {
    final st = c.dots;
    if (!st.visible || st.opacity <= 0.001) return;
    final fs = c.fontSize;
    final size = fs * 0.3;
    final gap = fs * 0.18;
    final maxWidth = math.max(40.0, c.w - _widthPad);
    final left = c.w / 2 - maxWidth / 2 + fs * 0.4;
    final anchor = c.anchor;
    final offset = (anchor >= 0 && anchor < c.centers.length)
        ? (c.centers[anchor] - c.h * c.align)
        : 0.0;
    final cy = c.dotsNaturalY - offset;
    if (cy < -size || cy > viewH + size) return;
    canvas.save();
    canvas.translate(left, cy);
    canvas.scale(st.scale);
    for (var i = 0; i < 3 && i < st.dots.length; i++) {
      final a = (st.dots[i] * st.opacity).clamp(0.0, 1.0);
      if (a <= 0.002) continue;
      canvas.drawCircle(
        Offset(size / 2 + i * (size + gap), 0),
        size / 2,
        Paint()..color = c.played.withValues(alpha: a),
      );
    }
    canvas.restore();
  }

  /// 非激活行透明度：距「焦点行」（激活行，间奏时为锚点行）的距离渐淡，
  /// 下限为 [_PaintCtx.inactiveAlpha]。背景人声行再乘 0.4
  /// （对齐 AMLL `.lyricBgLine` opacity .4）。
  double _alphaFor(int i) {
    final focus = c.active >= 0 ? c.active : c.anchor;
    final d = focus < 0 ? 99.0 : (i - focus).abs().toDouble();
    var a = math
        .max(c.inactiveAlpha, 1 - (math.max(0.0, d - 1) * 0.35))
        .clamp(0.0, 1.0);
    if (i < c.groups.length && c.groups[i].isBG) a *= 0.4;
    return a;
  }

  /// 当前失焦半径（px，由状态层平滑；对齐 AMLL `blur(min(5, 1+distance))`）。
  double _blurFor(int i) =>
      (c.enableBlur && i < c.blur.length) ? c.blur[i] : 0;

  /// 当前缩放（激活 1.0，非激活 0.97）。
  double _scaleFor(int i) => i < c.scale.length ? c.scale[i] : 1.0;

  /// 离屏层范围：主行以 [cy] 为中心，翻译小字挂在主行下方，因此有翻译时
  /// 需要向下扩一整个行高的余量（否则翻译底部会被裁掉）。
  Rect _lineBounds(int index, double cy) {
    final h = index < c.heights.length ? c.heights[index] : 40.0;
    final pad = c.fontSize * 0.5;
    final g = index < c.groups.length ? c.groups[index] : null;
    final hasSub =
        (c.showRomanization && (g?.romaji?.isNotEmpty ?? false)) ||
        (c.showTranslation && (g?.translation?.isNotEmpty ?? false));
    final bottom = hasSub ? cy + h + pad : cy + h / 2 + pad;
    return Rect.fromLTRB(0, cy - h / 2 - pad, math.max(1.0, c.w), bottom);
  }

  void _drawLine(Canvas canvas, int index, double cy, double fade) {
    final g = c.groups[index];
    final fs = g.isBG ? c.fontSize * kBgFontScale : c.fontSize;
    final maxWidth = math.max(40.0, c.w - _widthPad);
    final alpha = _alphaFor(index);
    final scale = _scaleFor(index);
    final blur = _blurFor(index);
    final bounds = _lineBounds(index, cy);

    final blurLayer = blur > 0.05;
    if (blurLayer) {
      // 失焦用离屏高斯：Flutter 无法给 drawParagraph 直接加 ImageFilter，
      // 只能对整行开层。仅非激活行、且按距离限制在 5px 内。
      canvas.saveLayer(
        bounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: blur * 0.5,
            sigmaY: blur * 0.5,
          ),
      );
    }

    // 基础层：非激活外观（未唱色）。fade→1 时完全被激活外观盖住，可跳过。
    // fade 在 (0,1) 之间时给基础层乘 (1-fade)，与激活层的 fade 加权形成
    // 真正的交叉淡化（否则两层叠加会在过渡中段整体偏亮）。
    if (fade < 0.995) {
      final base = _solidParagraph(
        index,
        g,
        active: false,
        alpha: alpha,
        fs: fs,
        maxWidth: maxWidth,
      );
      final crossfade = fade > 0.005;
      if (crossfade) {
        canvas.saveLayer(
          bounds,
          Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 1 - fade),
        );
      }
      canvas.save();
      canvas.translate(c.w / 2, cy);
      canvas.scale(scale);
      canvas.translate(-base.width / 2, -base.height / 2);
      canvas.drawParagraph(base, Offset.zero);
      canvas.restore();
      _drawSubLines(
        canvas,
        index,
        g,
        cy + base.height / 2,
        active: false,
        alpha: alpha,
        fs: fs,
        maxWidth: maxWidth,
      );
      if (crossfade) canvas.restore();
    }

    // 激活外观层：整层按 fade 调节透明度，实现「点亮/熄灭」交叉淡化。
    if (fade > 0.005) {
      canvas.saveLayer(
        bounds,
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: fade),
      );
      _drawActive(canvas, index, g, cy, scale, fs, maxWidth);
      canvas.restore();
    }

    if (blurLayer) canvas.restore();
  }

  /// 激活外观（已唱色 + 扫亮遮罩 + 逐词上浮/强调）。
  void _drawActive(
    Canvas canvas,
    int index,
    LyricGroup g,
    double cy,
    double scale,
    double fs,
    double maxWidth,
  ) {
    final fr = _fragRender(index, g, fs, maxWidth);
    if (fr != null) {
      canvas.save();
      canvas.translate(c.w / 2, cy);
      canvas.scale(scale);
      canvas.translate(-fr.width / 2, -fr.height / 2);
      _drawFragments(canvas, g, fr, fs, maxWidth);
      canvas.restore();
      _drawSubLines(
        canvas,
        index,
        g,
        cy + fr.height / 2,
        active: true,
        alpha: 1,
        fs: fs,
        maxWidth: maxWidth,
      );
      return;
    }
    final main = _solidParagraph(
      index,
      g,
      active: true,
      alpha: 1,
      fs: fs,
      maxWidth: maxWidth,
    );
    canvas.save();
    canvas.translate(c.w / 2, cy);
    canvas.scale(scale);
    canvas.translate(-main.width / 2, -main.height / 2);
    canvas.drawParagraph(main, Offset.zero);
    canvas.restore();
    _drawSubLines(
      canvas,
      index,
      g,
      cy + main.height / 2,
      active: true,
      alpha: 1,
      fs: fs,
      maxWidth: maxWidth,
    );
  }

  /// 逐字绘制：未唱 → 未唱变体；已唱 → 已唱变体；正在扫过 → 未唱打底 +
  /// 羽化遮罩裁切的已唱（对齐 AMLL 的渐变蒙版扫亮）。
  void _drawFragments(
    Canvas canvas,
    LyricGroup g,
    LyricsFragmentRender fr,
    double fs,
    double maxWidth,
  ) {
    final lineStart = g.original.timeMs;
    final pos = c.positionMs;
    final n = fr.length;
    for (var k = 0; k < n; k++) {
      final box = fr.boxes[k];
      final startAbs = lineStart + fr.startMs[k];
      final dur = fr.durationMs[k];
      final t = pos - startAbs;
      final anim = _wordAnim(k, n, fr, dur, pos - lineStart, fs);

      canvas.save();
      final cx = box.left + box.width / 2;
      final cyF = box.top + box.height / 2;
      if (anim.dx != 0 || anim.dy != 0 || anim.scale != 1.0) {
        canvas.translate(cx + anim.dx, cyF + anim.dy);
        canvas.scale(anim.scale);
        canvas.translate(-cx, -cyF);
      }
      if (t >= dur) {
        canvas.drawParagraph(
          _litParagraph(fr, k, fs, maxWidth, anim),
          Offset(box.left, box.top),
        );
      } else if (t <= 0) {
        canvas.drawParagraph(fr.dim[k], Offset(box.left, box.top));
      } else {
        canvas.drawParagraph(fr.dim[k], Offset(box.left, box.top));
        _drawSweepLit(canvas, fr, k, box, t / dur, fs, maxWidth, anim);
      }
      canvas.restore();
    }
  }

  /// 扫亮羽化：在未唱底上叠一层「已唱」，并用 x 方向线性渐变做 dstIn 遮罩。
  void _drawSweepLit(
    Canvas canvas,
    LyricsFragmentRender fr,
    int k,
    FragBox box,
    double p,
    double fs,
    double maxWidth,
    WordAnim anim,
  ) {
    final lit = _litParagraph(fr, k, fs, maxWidth, anim);
    final rect = Rect.fromLTWH(
      box.left - 1,
      box.top - 1,
      box.width + 2,
      box.height + 2,
    );
    final width = math.max(1.0, box.width);
    final feather = (c.wordFadeWidth * fs).clamp(1.0, width * 2);
    final x0 = width * p.clamp(0.0, 1.0);
    var a = ((x0 - feather / 2) / width).clamp(0.0, 1.0);
    var b = ((x0 + feather / 2) / width).clamp(0.0, 1.0);
    if (b <= a) b = math.min(1.0, a + 1e-3);
    final shader = ui.Gradient.linear(
      Offset(box.left, box.top),
      Offset(box.left + width, box.top),
      const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
      [a, b],
    );
    canvas.saveLayer(rect, Paint());
    canvas.drawParagraph(lit, Offset(box.left, box.top));
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = shader,
    );
    canvas.restore();
  }

  /// 已唱变体（长音强调时每帧重建带辉光的段落，仅少数长音字/词）。
  ui.Paragraph _litParagraph(
    LyricsFragmentRender fr,
    int k,
    double fs,
    double maxWidth,
    WordAnim anim,
  ) {
    if (anim.glowAlpha <= 0.01) return fr.lit[k];
    return buildGlowFragment(
      fontFamily: c.fontFamily,
      fontSize: fs,
      weight: c.fontWeight,
      maxWidth: maxWidth,
      color: c.played.withValues(alpha: _litAlpha),
      text: fr.texts[k],
      glowAlpha: anim.glowAlpha,
      blurRadius: anim.glowBlur,
    );
  }

  /// 单个字/词的每帧动画参数（对齐 AMLL float + emphasize）。
  WordAnim _wordAnim(
    int k,
    int n,
    LyricsFragmentRender fr,
    int dur,
    int tRel,
    double fs,
  ) => resolveWordAnim(
    text: fr.texts[k],
    index: k,
    count: n,
    relStartMs: fr.startMs[k],
    durationMs: dur,
    lineRelMs: tRel,
    fontSize: fs,
  );

  LyricsFragmentRender? _fragRender(
    int index,
    LyricGroup g,
    double fs,
    double maxWidth,
  ) {
    final frags = g.fragments;
    if (!c.wordSweep || frags == null || frags.isEmpty) return null;
    final key = (
      g.original.text,
      c.fontFamily,
      fs,
      c.fontWeight.value,
      maxWidth,
      c.played.toARGB32(),
      _unsungAlpha,
      _litAlpha,
    );
    return c.fragCache.obtain(
      index,
      key,
      () => buildLyricsFragmentRender(
        fragments: frags,
        lineText: g.original.text,
        fontFamily: c.fontFamily,
        fontSize: fs,
        weight: c.fontWeight,
        maxWidth: maxWidth,
        played: c.played,
        unsungAlpha: _unsungAlpha,
        litAlpha: _litAlpha,
      ),
    );
  }

  /// 整行段落（未激活 = 未唱色 × alpha × w400；激活 = 已唱色 × w600）。
  ui.Paragraph _solidParagraph(
    int index,
    LyricGroup g,
    {required bool active,
    required double alpha,
    required double fs,
    required double maxWidth}) {
    final weight = active ? c.fontWeight : FontWeight.w400;
    final color = active
        ? c.played.withValues(alpha: alpha)
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

  /// 主行下方的附属小字：音译（罗马音）在上、翻译在下（对齐 AMLL
  /// `.lyricSubLine` 的堆叠顺序与 `gap: .3em`）。
  void _drawSubLines(
    Canvas canvas,
    int index,
    LyricGroup g,
    double mainBottom,
    {required bool active,
    required double alpha,
    required double fs,
    required double maxWidth}) {
    final gap = fs * kLyricTranslationGapEm;
    var below = mainBottom;
    final ro = g.romaji;
    if (c.showRomanization && ro != null && ro.isNotEmpty) {
      final sub = _romajiParagraph(index, ro, active, alpha, fs, maxWidth);
      below += gap;
      canvas.drawParagraph(sub, Offset(c.w / 2 - sub.width / 2, below));
      below += sub.height;
    }
    final tr = g.translation;
    if (c.showTranslation && tr != null && tr.isNotEmpty) {
      final sub = _translationParagraph(index, tr, active, alpha, fs, maxWidth);
      below += gap;
      canvas.drawParagraph(sub, Offset(c.w / 2 - sub.width / 2, below));
    }
  }

  /// 音译（罗马音）小字段落（颜色含透明度，替代 saveLayer）。
  ui.Paragraph _romajiParagraph(
    int index,
    String text,
    bool active,
    double alpha,
    double fs,
    double maxWidth,
  ) {
    final color = active
        ? c.played.withValues(alpha: 0.65)
        : c.unplayed.withValues(alpha: alpha * 0.85);
    final subFs = lyricTranslationFontSize(fs);
    final key = (text, c.fontFamily, subFs, color.toARGB32(), maxWidth);
    return c.cache.obtainRomanization(index, key, () {
      final b = ui.ParagraphBuilder(
        _pStyle(
          c.fontFamily,
          subFs,
          FontWeight.w400,
          height: kLyricTranslationLineHeightEm,
        ),
      );
      b.pushStyle(
        _uiStyle(
          c.fontFamily,
          subFs,
          FontWeight.w400,
          color,
          height: kLyricTranslationLineHeightEm,
        ),
      );
      b.addText(text);
      b.pop();
      return _layout(b, maxWidth);
    })!;
  }

  ui.Paragraph _translationParagraph(
    int index,
    String text,
    bool active,
    double alpha,
    double fs,
    double maxWidth,
  ) {
    final color = active
        ? c.played.withValues(alpha: 0.8)
        : c.unplayed.withValues(alpha: alpha);
    final subFs = lyricTranslationFontSize(fs);
    final key = (text, c.fontFamily, subFs, color.toARGB32(), maxWidth);
    return c.cache.obtainTranslation(index, key, () {
      final b = ui.ParagraphBuilder(
        _pStyle(
          c.fontFamily,
          subFs,
          FontWeight.w400,
          height: kLyricTranslationLineHeightEm,
        ),
      );
      b.pushStyle(
        _uiStyle(
          c.fontFamily,
          subFs,
          FontWeight.w400,
          color,
          height: kLyricTranslationLineHeightEm,
        ),
      );
      b.addText(text);
      b.pop();
      return _layout(b, maxWidth);
    })!;
  }

  /// 段落/文本样式：行高必须与 `computeLineHeights` 的实测一致，
  /// 否则布局行高与实际渲染不符（间距会漂）。
  static ui.ParagraphStyle _pStyle(
    String? family,
    double fs,
    FontWeight w, {
    double height = kLyricLineHeightEm,
  }) => ui.ParagraphStyle(
    textAlign: ui.TextAlign.center,
    textDirection: ui.TextDirection.ltr,
    fontFamily: family,
    fontSize: fs,
    fontWeight: w,
    height: height,
  );

  static ui.TextStyle _uiStyle(
    String? family,
    double fs,
    FontWeight w,
    Color color, {
    double height = kLyricLineHeightEm,
    List<ui.Shadow>? shadows,
  }) => ui.TextStyle(
    color: color,
    fontFamily: family,
    fontSize: fs,
    fontWeight: w,
    height: height,
    shadows: shadows,
  );

  static ui.Paragraph _layout(ui.ParagraphBuilder b, double maxWidth) {
    final p = b.build();
    p.layout(ui.ParagraphConstraints(width: maxWidth));
    return p;
  }

  @override
  bool shouldRepaint(_Painter old) => false;
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

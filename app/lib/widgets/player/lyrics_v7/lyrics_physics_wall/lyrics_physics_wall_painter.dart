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

  /// 轻量档伪散焦：把非激活行「放大 4% + 低透明」再画一遍（零离屏层、零高斯）。
  static const double _liteGhostScale = 1.04;
  static const double _liteGhostAlpha = 0.35;

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
    final fades = <int, double>{};
    final staticLines = <int>[];
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
      fades[i] = fade;
      // 烘焙候选：可见且非激活（fade==0）——稳态时全部可见行除激活行外都在此。
      if (i != c.active && fade <= 0.005) staticLines.add(i);
    }
    if (c.blurMode == LyricsBlurMode.panel && c.blurStrength > 0.02) {
      // 稳态判定：无动画、无过渡、无悬停渐变，激活外观已完整。
      final steady = _panelSteady(visible, fades);
      var baked = false;
      if (c.bakeEnabled && steady) {
        // 稳态贴图：整层高斯已在烘焙图里，每帧只剩逐行贴图。
        // 烘焙缓存与位置无关：换行/滚动只对新进入视口的行烘一张，
        // 其余行直接复用（避免换行后首帧的全量重烘焙尖峰）。
        baked = true;
        for (final i in staticLines) {
          final line = c.bake.lookup(c, i);
          if (line == null) {
            // 尚未烘焙：本帧回退逐行高斯（观感等价），由下方预取摊到
            // 后续稳态帧，绝不在同一帧批量烘焙。
            _drawLine(
              canvas,
              i,
              c.y[i],
              0,
              sigmaOverride: kPanelBlurSigma * c.blurStrength,
            );
            continue;
          }
          final alpha = (_alphaFor(i) * _edgeAlphaAt(c.y[i])).clamp(0.0, 1.0);
          canvas.drawImageRect(
            line.image,
            Rect.fromLTWH(
              0,
              0,
              line.image.width.toDouble(),
              line.image.height.toDouble(),
            ),
            Rect.fromLTRB(
              0,
              c.y[i] + line.top,
              math.max(1.0, c.w),
              c.y[i] + line.bottom,
            ),
            Paint()
              ..filterQuality = ui.FilterQuality.low
              ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha),
          );
        }
        // 预取：每帧最多烘一张（视口上下各 2 行），把烘焙成本摊到稳态帧。
        c.bake.prefetchOne(this, c, visible);
      } else {
        // 过渡帧：基座优先用位置无关的烘焙图（行在动，但模糊外观不变 →
        // 贴图跟随 y 移动即可），无缓存/强度动画中才回退逐行高斯。
        // 激活外观始终逐帧重绘（扫亮/上浮是真正逐帧变化的部分）。
        final useCache = c.bakeEnabled && c.blurStrengthSettled;
        for (final i in visible) {
          final fade = fades[i]!;
          final line = useCache ? c.bake.lookup(c, i) : null;
          if (line == null) {
            _drawLine(
              canvas,
              i,
              c.y[i],
              fade,
              sigmaOverride: i == c.active
                  ? 0
                  : kPanelBlurSigma * c.blurStrength,
            );
            continue;
          }
          // 基座 = 烘焙图 × 实际 alpha ×（1 − fade）：与 _drawBase 的
          // 交叉淡化同语义（高斯/透明度对 alpha 线性）。
          final baseAlpha = _alphaFor(i) * (1 - fade) * _edgeAlphaAt(c.y[i]);
          if (baseAlpha > 0.004) {
            canvas.drawImageRect(
              line.image,
              Rect.fromLTWH(
                0,
                0,
                line.image.width.toDouble(),
                line.image.height.toDouble(),
              ),
              Rect.fromLTRB(
                0,
                c.y[i] + line.top,
                math.max(1.0, c.w),
                c.y[i] + line.bottom,
              ),
              Paint()
                ..filterQuality = ui.FilterQuality.low
                ..color = const Color(0xFFFFFFFF)
                    .withValues(alpha: baseAlpha.clamp(0.0, 1.0)),
            );
          }
          _drawActiveLayer(canvas, i, c.y[i], fade, edge: _edgeAlphaAt(c.y[i]));
        }
      }
      if (c.bakeEnabled && steady) {
        // 稳态分支只贴静态行：激活外观在此统一叠回。
        for (final i in visible) {
          _drawActiveLayer(
            canvas,
            i,
            c.y[i],
            fades[i]!,
            edge: _edgeAlphaAt(c.y[i]),
          );
        }
      }
      c.lastFrameBaked = baked;
    } else {
      c.lastFrameBaked = false;
      for (final i in visible) {
        _drawLine(canvas, i, c.y[i], fades[i]!);
      }
    }
    _drawInterludeDots(canvas, viewH);
    // 只缓存可见窗口 → 常驻内存 O(视口)，与歌长无关（§3.4）。
    c.cache.pruneTo(visible);
    c.fragCache.pruneTo(keepFrag);
    c.transFragCache.pruneTo(keepFrag);
    c.romaFragCache.pruneTo(keepFrag);
    c.bake.pruneTo(visible);
  }

  /// 整层档稳态判定：全部满足才允许使用/重建烘焙图——
  /// 1. 无动画（弹簧/过渡/浏览由状态层的 `moving` 汇总）；
  /// 2. 整层失焦强度已到目标（悬停/切档渐变结束）；
  /// 3. 激活行外观完整（fade == 1），其余可见行 fade == 0；
  /// 4. 缩放已落到终值（激活 1.0 / 非激活 0.97）。
  ///
  /// blur[]（逐行半径）只影响逐行档，不参与整层稳态判定。
  bool _panelSteady(Set<int> visible, Map<int, double> fades) {
    if (!c.staticIdle || !c.blurStrengthSettled) return false;
    if (c.active >= c.groups.length) return false;
    if (c.active >= 0 && (fades[c.active] ?? 0) < 0.995) return false;
    final scaleTarget = c.enableScale ? 0.97 : 1.0;
    for (final i in visible) {
      if (i == c.active) continue;
      if ((fades[i] ?? 0) > 0.005) return false;
      if ((c.scale[i] - scaleTarget).abs() > 1e-4) return false;
    }
    return true;
  }

  /// 间奏三点（对齐 AMLL interlude-dots：依次点亮 + 呼吸缩放 + 两段式退场）。
  void _drawInterludeDots(Canvas canvas, double viewH) {
    final st = c.dots;
    if (!st.visible || st.opacity <= 0.001) return;
    final edge = _edgeAlphaAt(c.dotsNaturalY);
    if (edge <= 0.002) return;
    final fs = c.fontSize;
    final size = fs * 0.3;
    final gap = fs * 0.18;
    final maxWidth = math.max(40.0, c.w - _widthPad);
    final textLeft = (c.w - maxWidth) / 2;
    final groupWidth = 3 * size + 2 * gap;
    final left = c.textAlign == ui.TextAlign.right
        ? textLeft + maxWidth - groupWidth - fs * 0.4
        : textLeft + fs * 0.4;
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
      final a = (st.dots[i] * st.opacity * edge).clamp(0.0, 1.0);
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

  /// 当前行失焦等级（px，= AMLL 的 `blur()` 参数 = 高斯 σ）。
  ///
  /// 只有逐行档才逐行取值；整层档稳态由烘焙图承载失焦、过渡帧统一取
  /// `kPanelBlurSigma × 强度`（见 [_drawLine] 的 `sigmaOverride`），
  /// 关闭/降级档恒为 0。
  double _blurFor(int i) {
    if (c.blurMode != LyricsBlurMode.perLine) return 0;
    if (i >= c.blur.length) return 0;
    return c.blur[i];
  }

  /// 当前缩放（激活 1.0，非激活 0.97）。
  double _scaleFor(int i) => i < c.scale.length ? c.scale[i] : 1.0;

  /// 行中心处的上下渐隐保留量（[AmllPhysicsWall.edgeFade] 关闭时恒为 1）。
  ///
  /// 逐行模式把外层 `ShaderMask` 的面积级离屏层换成「绘制时乘 alpha」：
  /// 零离屏层、零额外纹理，代价是阶梯式淡出（行中心取样）。与
  /// [lyricsEdgeFadeAt] 同一曲线，保证两种实现的观感可比。
  double _edgeAlphaAt(double cy) {
    if (!c.edgeFade) return 1.0;
    final viewH = c.h > 0 ? c.h : 0.0;
    if (viewH <= 0) return 1.0;
    return lyricsEdgeFadeAt(cy / viewH);
  }

  /// 离屏层范围：以 [cy] 为行块中心（主行 + 译文/音译同属一个行块），
  /// 上下各取半个完整行高，避免子行底部被裁掉。
  Rect _lineBounds(int index, double cy) {
    final h = _lineHeightAt(index);
    final pad = c.fontSize * 0.5;
    // 行块 = 主行 + 译文/音译，`cy` 是**整块**中心（与 computeCenters /
    // AMLL wrapper 一致），绘制与离屏层都用 ±h/2，不能只按主行高度算。
    return Rect.fromLTRB(
      0,
      cy - h / 2 - pad,
      math.max(1.0, c.w),
      cy + h / 2 + pad,
    );
  }

  /// 该行的完整行块高度（含译文/音译）；越界时给一个保守值。
  double _lineHeightAt(int index) =>
      index < c.heights.length ? c.heights[index] : 40.0;

  /// 逐行档：一行一个离屏高斯（最贴 AMLL 的半径梯度，层数 ≈ 可见行数）。
  ///
  /// [sigmaOverride] 非空时覆盖该行的失焦半径（整层档过渡帧用：全部非激活行
  /// 统一取整层目标 σ，与稳态烘焙观感一致；激活行传 0 保持清晰）。
  void _drawLine(
    Canvas canvas,
    int index,
    double cy,
    double fade, {
    double? sigmaOverride,
  }) {
    final blur = sigmaOverride ?? _blurFor(index);
    final blurLayer = blur > 0.05;
    if (blurLayer) {
      // 失焦用离屏高斯：Flutter 无法给 drawParagraph 直接加 ImageFilter，
      // 只能对整行开层。σ 直接取 AMLL 的 blur 参数（= σ，不折半）。
      canvas.saveLayer(
        _lineBounds(index, cy),
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      );
    }
    _drawBase(canvas, index, cy, fade, edge: _edgeAlphaAt(cy));
    _drawActiveLayer(canvas, index, cy, fade, edge: _edgeAlphaAt(cy));
    if (blurLayer) canvas.restore();
  }

  /// 基础层：非激活外观（未唱色）。`fade → 1` 时完全被激活外观盖住，可跳过。
  ///
  /// `fade` 在 (0,1) 之间时给基础层乘 `(1-fade)`，与激活层的 `fade` 加权形成
  /// 真正的交叉淡化（否则两层叠加会在过渡中段整体偏亮）。
  ///
  /// [alphaOverride] / [scaleOverride] 供烘焙使用：把透明度归一为 1、缩放固定
  /// 为稳态值后栅格一次，绘制时再乘实际 alpha（高斯对 alpha 线性，等价）。
  void _drawBase(
    Canvas canvas,
    int index,
    double cy,
    double fade, {
    double? alphaOverride,
    double? scaleOverride,
    double edge = 1.0,
  }) {
    if (fade >= 0.995) return;
    final g = c.groups[index];
    final fs = g.isBG ? c.fontSize * kBgFontScale : c.fontSize;
    final maxWidth = math.max(40.0, c.w - _widthPad);
    final alpha = (alphaOverride ?? _alphaFor(index)) * edge;
    if (alpha <= 0.002) return;
    final scale = scaleOverride ?? _scaleFor(index);
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
        _lineBounds(index, cy),
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 1 - fade),
      );
    }
    // 主行按**整块**顶部对齐：cy 是整块中心，整块高度含译文/音译。
    // 若仍按主行自身高度居中，子行会整体探出预留槽位，压到下一行（尤其
    // 0.4× 行距的辅词行）。
    final h = _lineHeightAt(index);
    canvas.save();
    canvas.translate(c.w / 2, cy);
    canvas.scale(scale);
    canvas.translate(-base.width / 2, -h / 2);
    canvas.drawParagraph(base, Offset.zero);
    canvas.restore();
    // 轻量档：不跑高斯，用一次放大 + 低透明重绘近似散焦（强度随悬停/切档平滑）。
    if (c.blurMode == LyricsBlurMode.lite && c.blurStrength > 0.02) {
      final ghost = _solidParagraph(
        index,
        g,
        active: false,
        alpha: alpha * _liteGhostAlpha * c.blurStrength,
        fs: fs,
        maxWidth: maxWidth,
      );
      canvas.save();
      canvas.translate(c.w / 2, cy);
      canvas.scale(scale * _liteGhostScale);
      canvas.translate(-ghost.width / 2, -h / 2);
      canvas.drawParagraph(ghost, Offset.zero);
      canvas.restore();
    }
    _drawSubLines(
      canvas,
      index,
      g,
      cy - h / 2 + base.height,
      active: false,
      alpha: alpha,
      fs: fs,
      maxWidth: maxWidth,
    );
    if (crossfade) canvas.restore();
  }

  /// 激活外观层：整层按 `fade` 调节透明度，实现「点亮/熄灭」交叉淡化。
  ///
  /// [edge] 为上下渐隐保留量（逐行渐隐模式），直接折进本层透明度。
  void _drawActiveLayer(
    Canvas canvas,
    int index,
    double cy,
    double fade, {
    double edge = 1.0,
  }) {
    final a = (fade * edge).clamp(0.0, 1.0);
    if (a <= 0.005) return;
    final g = c.groups[index];
    final fs = g.isBG ? c.fontSize * kBgFontScale : c.fontSize;
    final maxWidth = math.max(40.0, c.w - _widthPad);
    if (a >= 0.995) {
      // 外观完整时 alpha=1 的 saveLayer 是纯开销：裁剪语义用 clipRect 保留
      // （边界与原离屏层一致），内容直接绘制。
      canvas.save();
      canvas.clipRect(_lineBounds(index, cy));
      _drawActive(canvas, index, g, cy, _scaleFor(index), fs, maxWidth);
      canvas.restore();
      return;
    }
    canvas.saveLayer(
      _lineBounds(index, cy),
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: a),
    );
    _drawActive(canvas, index, g, cy, _scaleFor(index), fs, maxWidth);
    canvas.restore();
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
    final h = _lineHeightAt(index);
    final fr = _fragRender(index, g, fs, maxWidth);
    if (fr != null) {
      canvas.save();
      canvas.translate(c.w / 2, cy);
      canvas.scale(scale);
      canvas.translate(-fr.width / 2, -h / 2);
      _drawFragments(canvas, g, fr, fs, maxWidth);
      canvas.restore();
      _drawSubLines(
        canvas,
        index,
        g,
        cy - h / 2 + fr.height,
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
    canvas.translate(-main.width / 2, -h / 2);
    canvas.drawParagraph(main, Offset.zero);
    canvas.restore();
    _drawSubLines(
      canvas,
      index,
      g,
      cy - h / 2 + main.height,
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
    double maxWidth, {
    double lineHeightEm = kLyricLineHeightEm,
  }) {
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
          _litParagraph(fr, k, fs, maxWidth, anim, lineHeightEm),
          Offset(box.left, box.top),
        );
      } else if (t <= 0) {
        canvas.drawParagraph(fr.dim[k], Offset(box.left, box.top));
      } else {
        canvas.drawParagraph(fr.dim[k], Offset(box.left, box.top));
        _drawSweepLit(
          canvas,
          fr,
          k,
          box,
          t / dur,
          fs,
          maxWidth,
          anim,
          lineHeightEm,
        );
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
    double lineHeightEm,
  ) {
    final lit = _litParagraph(fr, k, fs, maxWidth, anim, lineHeightEm);
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
    double lineHeightEm,
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
      lineHeightEm: lineHeightEm,
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
      c.textAlign,
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
        textAlign: c.textAlign,
      ),
    );
  }

  /// 整行段落（未激活 = 未唱色 × alpha × w400；激活 = 已唱色 × w600）。
  ui.Paragraph _solidParagraph(
    int index,
    LyricGroup g, {
    required bool active,
    required double alpha,
    required double fs,
    required double maxWidth,
  }) {
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
      c.textAlign,
    );
    return c.cache.obtainMain(index, key, () {
      final b = ui.ParagraphBuilder(
        _pStyle(c.fontFamily, fs, weight, textAlign: c.textAlign),
      );
      b.pushStyle(_uiStyle(c.fontFamily, fs, weight, color));
      b.addText(g.original.text);
      b.pop();
      return _layout(b, maxWidth);
    });
  }

  /// 主行下方的附属小字：**翻译在上、音译（罗马音）在下**。
  ///
  /// 对齐 AMLL `lyric-line` 子节点顺序（`lyric-line.ts`：children =
  /// [main, translation, romanization]）与 `gap: .3em`；音译直接贴主行会让
  /// 罗马注音出现在译文上方，与原设计不符。
  void _drawSubLines(
    Canvas canvas,
    int index,
    LyricGroup g,
    double mainBottom, {
    required bool active,
    required double alpha,
    required double fs,
    required double maxWidth,
  }) {
    // AMLL 的主行/译文/音译是 `.lyricLine` 内的块级兄弟，直接堆叠，不加 gap。
    var below = mainBottom;
    final subFs = lyricTranslationFontSize(fs);
    final tr = g.translation;
    if (c.showTranslation && tr != null && tr.isNotEmpty) {
      final fr = active
          ? _subFragRender(index, g, roman: false, fs: fs, maxWidth: maxWidth)
          : null;
      if (fr != null) {
        canvas.save();
        canvas.translate(c.w / 2 - fr.width / 2, below);
        _drawFragments(
          canvas,
          g,
          fr,
          subFs,
          maxWidth,
          lineHeightEm: kLyricTranslationLineHeightEm,
        );
        canvas.restore();
        below += fr.height;
      } else {
        final sub = _translationParagraph(
          index,
          tr,
          active,
          alpha,
          fs,
          maxWidth,
        );
        canvas.drawParagraph(sub, Offset(c.w / 2 - sub.width / 2, below));
        below += sub.height;
      }
    }
    final ro = g.romaji;
    if (c.showRomanization && ro != null && ro.isNotEmpty) {
      final fr = active
          ? _subFragRender(index, g, roman: true, fs: fs, maxWidth: maxWidth)
          : null;
      if (fr != null) {
        canvas.save();
        canvas.translate(c.w / 2 - fr.width / 2, below);
        _drawFragments(
          canvas,
          g,
          fr,
          subFs,
          maxWidth,
          lineHeightEm: kLyricTranslationLineHeightEm,
        );
        canvas.restore();
        below += fr.height;
      } else {
        final sub = _romajiParagraph(index, ro, active, alpha, fs, maxWidth);
        canvas.drawParagraph(sub, Offset(c.w / 2 - sub.width / 2, below));
        below += sub.height;
      }
    }
  }

  /// 翻译 / 音译小字的逐字渲染（无片段 / 关闭逐字时返回 null 回退段落）。
  LyricsFragmentRender? _subFragRender(
    int index,
    LyricGroup g, {
    required bool roman,
    required double fs,
    required double maxWidth,
  }) {
    if (!c.wordSweep) return null;
    final frags = roman ? g.romajiFragments : g.translationFragments;
    final text = roman ? g.romaji : g.translation;
    // 普通行（翻译/音译同样没有字级片段）不做逐字。
    if (frags == null || frags.isEmpty || text == null || text.isEmpty) {
      return null;
    }
    final subFs = lyricTranslationFontSize(fs);
    // 与 _translationParagraph / _romajiParagraph 的激活色一致：
    // 翻译 lit 0.8 / 音译 lit 0.65，未唱取 lit × 0.4（对齐主行 0.4 比例）。
    final litAlpha = roman ? 0.65 : 0.8;
    final unsungAlpha = litAlpha * _unsungAlpha;
    final cache = roman ? c.romaFragCache : c.transFragCache;
    final key = (
      text,
      c.fontFamily,
      subFs,
      maxWidth,
      c.played.toARGB32(),
      unsungAlpha,
      litAlpha,
      c.textAlign,
    );
    return cache.obtain(
      index,
      key,
      () => buildLyricsFragmentRender(
        fragments: frags,
        lineText: text,
        fontFamily: c.fontFamily,
        fontSize: subFs,
        weight: FontWeight.w400,
        maxWidth: maxWidth,
        played: c.played,
        unsungAlpha: unsungAlpha,
        litAlpha: litAlpha,
        lineHeightEm: kLyricTranslationLineHeightEm,
        textAlign: c.textAlign,
      ),
    );
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
    final key = (
      text,
      c.fontFamily,
      subFs,
      color.toARGB32(),
      maxWidth,
      c.textAlign,
    );
    return c.cache.obtainRomanization(index, key, () {
      final b = ui.ParagraphBuilder(
        _pStyle(
          c.fontFamily,
          subFs,
          FontWeight.w400,
          height: kLyricTranslationLineHeightEm,
          textAlign: c.textAlign,
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
    final key = (
      text,
      c.fontFamily,
      subFs,
      color.toARGB32(),
      maxWidth,
      c.textAlign,
    );
    return c.cache.obtainTranslation(index, key, () {
      final b = ui.ParagraphBuilder(
        _pStyle(
          c.fontFamily,
          subFs,
          FontWeight.w400,
          height: kLyricTranslationLineHeightEm,
          textAlign: c.textAlign,
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
    ui.TextAlign textAlign = ui.TextAlign.center,
  }) => ui.ParagraphStyle(
    textAlign: textAlign,
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

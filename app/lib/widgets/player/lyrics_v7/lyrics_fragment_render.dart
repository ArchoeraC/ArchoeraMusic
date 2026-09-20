// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 激活行逐字渲染：把一行的 [LyricFragment] 变成「可独立定位/变换的逐字
/// 段落」，让扫亮羽化、逐词上浮、长音强调都能作用到单个字/词上。
///
/// 上游 AMLL 是 DOM 结构（每个 word 一个 `<span>`），天然可以逐词做
/// transform / mask。Flutter 的 `ui.Paragraph` 做不到逐 run 变换，所以这里：
/// 1. 先用整行文本排一个「布局段落」，用 [ui.Paragraph.getBoxesForRange] 取
///    每个字/词在段落内的精确盒（含自动换行与居中对齐的结果）；
/// 2. 再为每个字/词单独排一个**左对齐**小段落，绘制时放到对应盒的原点。
///
/// 因此自动换行、居中对齐、字体 shaping 都由整行段落决定，逐字段落只负责
/// 「画自己」。逐字段落按行缓存，仅激活行（及其淡出中的上一行）需要。
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../services/lyrics/lyric_line.dart';
import 'lyrics_layout.dart';

/// 单个字/词在整行段落内的盒（逻辑像素，相对段落原点）。
class FragBox {
  const FragBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;
}

/// 一行的逐字渲染数据（未唱/已唱两套颜色变体 + 几何）。
class LyricsFragmentRender {
  const LyricsFragmentRender({
    required this.dim,
    required this.lit,
    required this.boxes,
    required this.startMs,
    required this.durationMs,
    required this.texts,
    required this.width,
    required this.height,
  });

  /// 未唱变体段落（played 色 × 未唱透明度）。
  final List<ui.Paragraph> dim;

  /// 已唱变体段落（played 色 × 已唱透明度）。
  final List<ui.Paragraph> lit;

  /// 每个字/词在段落坐标系内的盒。
  final List<FragBox> boxes;

  /// 每个字/词的相对行起始偏移（毫秒）。
  final List<int> startMs;

  /// 每个字/词的时长（毫秒，≥1）。
  final List<int> durationMs;

  /// 每个字/词的绘制文本（强调辉光需按帧重建段落）。
  final List<String> texts;

  /// 整行布局段落的宽度（用于居中定位）。
  final double width;

  /// 整行布局段落的高度（用于居中定位）。
  final double height;

  int get length => boxes.length;
}

/// 逐字渲染缓存：以行索引 + 键缓存，支持按可见/淡出集合淘汰。
///
/// 可缓存 null（该行无法逐字渲染，如整行文本与片段拼接不一致），避免每帧
/// 重复尝试构建。
class LyricsFragmentCache {
  final Map<int, _Entry> _entries = <int, _Entry>{};

  LyricsFragmentRender? obtain(
    int index,
    Object key,
    LyricsFragmentRender? Function() build,
  ) {
    final e = _entries[index];
    if (e != null && e.key == key) return e.render;
    final render = build();
    _entries[index] = _Entry(key, render);
    return render;
  }

  /// 只保留 [keep] 中的行（激活行 + 淡出中的上一行）。
  void pruneTo(Set<int> keep) {
    if (_entries.isEmpty) return;
    _entries.removeWhere((k, _) => !keep.contains(k));
  }

  /// 清空缓存（切歌 / 字号 / 字体 / 宽度变化）。
  void clear() => _entries.clear();

  /// 当前缓存条目数（测试用）。
  int get entryCount => _entries.length;

  /// 窥视某行缓存（测试用）。
  LyricsFragmentRender? peek(int index) => _entries[index]?.render;
}

class _Entry {
  _Entry(this.key, this.render);
  final Object key;
  final LyricsFragmentRender? render;
}

/// 构建一行的逐字渲染数据。
///
/// [unsungAlpha] / [litAlpha] 是 played 色的未唱/已唱透明度（对齐 AMLL 的
/// `--dark-mask-alpha` 0.4 与 `--bright-mask-alpha` 1.0）。
///
/// 空白字/词会被跳过（不绘制，仍占位）。整行文本与逐字拼接不一致时（极少）
/// 返回 null，由调用方回退到整行段落绘制。
LyricsFragmentRender? buildLyricsFragmentRender({
  required List<LyricFragment> fragments,
  required String lineText,
  required String? fontFamily,
  required double fontSize,
  required FontWeight weight,
  required double maxWidth,
  required Color played,
  required double unsungAlpha,
  required double litAlpha,
}) {
  if (maxWidth <= 0) return null;
  final joined = StringBuffer();
  for (final f in fragments) {
    joined.write(f.text);
  }
  final joinedText = joined.toString();
  final trimmed = joinedText.trim();
  if (trimmed.isEmpty) return null;
  // 布局文本用拼接结果（去掉首尾空白）；与整行文本不一致时放弃逐字路径。
  if (lineText.trim() != trimmed) return null;
  final lead = joinedText.length - joinedText.trimLeft().length;

  final layoutBuilder = ui.ParagraphBuilder(
    _pStyleCenter(fontFamily, fontSize, weight),
  )..pushStyle(_uStyle(fontFamily, fontSize, weight, played));
  layoutBuilder.addText(joinedText.trim());
  layoutBuilder.pop();
  final layout = layoutBuilder.build()
    ..layout(ui.ParagraphConstraints(width: maxWidth));

  final dim = <ui.Paragraph>[];
  final lit = <ui.Paragraph>[];
  final boxes = <FragBox>[];
  final startMs = <int>[];
  final durationMs = <int>[];
  final texts = <String>[];

  var charIndex = 0;
  for (final f in fragments) {
    final s = (charIndex - lead).clamp(0, trimmed.length);
    final e = (charIndex + f.text.length - lead).clamp(0, trimmed.length);
    charIndex += f.text.length;
    if (e <= s) continue;
    final sub = trimmed.substring(s, e);
    if (sub.trim().isEmpty) continue;
    final tb = layout.getBoxesForRange(
      s,
      e,
      boxHeightStyle: ui.BoxHeightStyle.max,
    );
    if (tb.isEmpty) continue;
    final box = tb.first;
    boxes.add(
      FragBox(
        left: box.left,
        top: box.top,
        width: box.right - box.left,
        height: box.bottom - box.top,
      ),
    );
    startMs.add(f.startMs);
    final d = f.durationMs;
    durationMs.add(d == null || d <= 0 ? 1 : d);
    texts.add(sub);
    dim.add(
      _fragParagraph(
        fontFamily: fontFamily,
        fontSize: fontSize,
        weight: weight,
        maxWidth: maxWidth,
        color: played.withValues(alpha: unsungAlpha),
        text: sub,
      ),
    );
    lit.add(
      _fragParagraph(
        fontFamily: fontFamily,
        fontSize: fontSize,
        weight: weight,
        maxWidth: maxWidth,
        color: played.withValues(alpha: litAlpha),
        text: sub,
      ),
    );
  }
  if (boxes.isEmpty) return null;

  return LyricsFragmentRender(
    dim: dim,
    lit: lit,
    boxes: boxes,
    startMs: startMs,
    durationMs: durationMs,
    texts: texts,
    width: layout.width,
    height: layout.height,
  );
}

/// 排一个左对齐的逐字小段落（用于独立定位/变换）。
ui.Paragraph _fragParagraph({
  required String? fontFamily,
  required double fontSize,
  required FontWeight weight,
  required double maxWidth,
  required Color color,
  required String text,
  List<ui.Shadow>? shadows,
}) {
  final b = ui.ParagraphBuilder(_pStyle(fontFamily, fontSize, weight));
  b.pushStyle(_uStyle(fontFamily, fontSize, weight, color, shadows: shadows));
  b.addText(text);
  b.pop();
  return b.build()..layout(ui.ParagraphConstraints(width: maxWidth));
}

/// 供 painter 构建「强调辉光」变体（每帧重建，仅少数长音字/词）。
ui.Paragraph buildGlowFragment({
  required String? fontFamily,
  required double fontSize,
  required FontWeight weight,
  required double maxWidth,
  required Color color,
  required String text,
  required double glowAlpha,
  required double blurRadius,
}) {
  return _fragParagraph(
    fontFamily: fontFamily,
    fontSize: fontSize,
    weight: weight,
    maxWidth: maxWidth,
    color: color,
    text: text,
    shadows: [
      ui.Shadow(
        color: const Color(0xFFFFFFFF).withValues(alpha: glowAlpha.clamp(0.0, 1.0)),
        blurRadius: blurRadius,
      ),
    ],
  );
}

ui.ParagraphStyle _pStyleCenter(String? family, double fs, FontWeight w) =>
    ui.ParagraphStyle(
      textAlign: ui.TextAlign.center,
      textDirection: ui.TextDirection.ltr,
      fontFamily: family,
      fontSize: fs,
      fontWeight: w,
      height: kLyricLineHeightEm,
    );

ui.ParagraphStyle _pStyle(String? family, double fs, FontWeight w) =>
    ui.ParagraphStyle(
      textAlign: ui.TextAlign.left,
      textDirection: ui.TextDirection.ltr,
      fontFamily: family,
      fontSize: fs,
      fontWeight: w,
      height: kLyricLineHeightEm,
    );

ui.TextStyle _uStyle(
  String? family,
  double fs,
  FontWeight w,
  Color color, {
  List<ui.Shadow>? shadows,
}) => ui.TextStyle(
  color: color,
  fontFamily: family,
  fontSize: fs,
  fontWeight: w,
  height: kLyricLineHeightEm,
  shadows: shadows,
);

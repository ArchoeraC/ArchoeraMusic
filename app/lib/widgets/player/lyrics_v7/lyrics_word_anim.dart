// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 逐词动画参数解算：普通上浮 + 长音强调（对齐 AMLL
/// `animation/float` 与 `animation/emphasize`）。
///
/// - **上浮**：每个字/词从 0 升到 -0.05em（背景人声 -0.10em），ease-out，
///   之后保持（唱过的字略微抬高，整行像在「呼吸」）；
/// - **强调**：时长 ≥ 1000ms 的字/词额外获得一次脉冲（`empathEasing`
///   0→1→0）：白辉光 + 1.1 倍缩放 + 轻微相互推挤；词尾再叠加一个
///   `sin` 半周的上浮 bob。
///
/// 纯 Dart（除 `dart:math` 外无依赖），可单测。
library;

import 'dart:math' as math;

import 'curves.dart';

/// 单个字/词的每帧动画参数（相对该字/词自身坐标系）。
class WordAnim {
  const WordAnim({
    required this.dx,
    required this.dy,
    required this.scale,
    required this.glowAlpha,
    required this.glowBlur,
  });

  /// 横向位移（逻辑像素，强调时的「相互推挤」）。
  final double dx;

  /// 纵向位移（逻辑像素，负 = 向上）。
  final double dy;

  /// 缩放（1.0 = 不缩放）。
  final double scale;

  /// 辉光透明度（0 = 无辉光）。
  final double glowAlpha;

  /// 辉光模糊半径（逻辑像素）。
  final double glowBlur;

  static const WordAnim none = WordAnim(
    dx: 0,
    dy: 0,
    scale: 1,
    glowAlpha: 0,
    glowBlur: 0,
  );

  /// 是否为恒等变换（绘制时可跳过 transform）。
  bool get isIdentity => dx == 0 && dy == 0 && scale == 1.0;
}

/// 文本是否全为 CJK（对齐 AMLL `isCJK`）：长音强调对 CJK 与拉丁词的
/// 字数判定不同。
bool isCjkText(String s) {
  if (s.isEmpty) return false;
  for (final r in s.runes) {
    final cjk =
        (r >= 0x3040 && r <= 0x30FF) || // 平假名 / 片假名
        (r >= 0x3400 && r <= 0x4DBF) || // 扩展 A
        (r >= 0x4E00 && r <= 0x9FFF) || // 基本汉字
        (r >= 0xAC00 && r <= 0xD7AF) || // 谚文音节
        (r >= 0xF900 && r <= 0xFAFF); // 兼容汉字
    if (!cjk) return false;
  }
  return true;
}

/// 是否需要长音强调（对齐 AMLL `shouldEmphasize`）。
bool shouldEmphasizeWord({required String text, required int durationMs}) {
  if (durationMs < 1000) return false;
  if (isCjkText(text)) return true;
  final n = text.trim().length;
  return n > 1 && n <= 7;
}

/// 解算第 [index] 个字/词（共 [count] 个）在行内相对时间 [lineRelMs] 的
/// 动画参数。
///
/// [relStartMs] / [durationMs] 是该字/词的相对行起始偏移与时长；
/// [text] 用于强调判定（CJK 与拉丁词的字数门槛不同）。
WordAnim resolveWordAnim({
  required String text,
  required int index,
  required int count,
  required int relStartMs,
  required int durationMs,
  required int lineRelMs,
  required double fontSize,
  bool isBG = false,
}) {
  final t = lineRelMs - relStartMs;
  // 普通上浮：0 → up，ease-out，之后保持。
  final floatDur = math.max(1000, durationMs);
  final fp = (t / floatDur).clamp(0.0, 1.0);
  final eo = 1 - math.pow(1 - fp, 3).toDouble();
  final up = isBG ? 0.10 : 0.05;
  var dy = -up * fontSize * eo;
  var dx = 0.0;
  var scale = 1.0;
  var glowAlpha = 0.0;
  var glowBlur = 0.0;

  final emphasize = shouldEmphasizeWord(text: text, durationMs: durationMs);
  if (emphasize) {
    var du = math.max(1000, durationMs).toDouble();
    var amount = du / 2000;
    amount = amount > 1 ? math.sqrt(amount) : amount * amount * amount;
    var blur = du / 3000;
    blur = blur > 1 ? math.sqrt(blur) : blur * blur * blur;
    amount *= 0.6;
    blur *= 0.5;
    if (index == count - 1) {
      // 末词演出更强（对齐上游）
      amount *= 1.6;
      blur *= 1.5;
      du *= 1.2;
    }
    amount = math.min(1.2, amount);
    blur = math.min(0.8, blur);

    final x = (t / du).clamp(0.0, 1.0);
    final e = empathEasing(x);
    glowAlpha = e * blur;
    glowBlur = math.min(0.3, blur * 0.3) * fontSize;
    scale = 1 + e * 0.1 * amount;
    dx = -e * 0.03 * amount * (count / 2 - index) * fontSize;
    dy += -e * 0.025 * amount * fontSize;
    // 强调专属上浮：sin 半周（比辉光早 400ms 开始）
    final bobDur = du * 1.4;
    final xb = ((t + 400) / bobDur).clamp(0.0, 1.0);
    dy += -math.sin(xb * math.pi) * up * fontSize;
  }
  return WordAnim(
    dx: dx,
    dy: dy,
    scale: scale,
    glowAlpha: glowAlpha,
    glowBlur: glowBlur,
  );
}

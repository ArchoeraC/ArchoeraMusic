// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 图片背景遮罩（`backgroundDim`）滑块的上下限。
const double kBackgroundDimMin = 0.3;
const double kBackgroundDimMax = 0.9;

/// 自动抬高遮罩下限时的上限：再往上背景图几乎不可见，宁可让对比度目标
/// 让步，也不能把用户选的图「吃掉」。
const double kBackgroundDimAutoMax = 0.75;

/// 图片模式下的正文前景色（暗色板 `AppPalette.dark.onSurface` = #ECECEC）。
///
/// 图片模式会强制暗色主题（见 `app.dart` 的 `effectiveThemeMode`），正文恒为
/// 这一种浅色，因此可以在遮罩下限里按它解一次对比度约束，无需逐段切换文字色
/// （后者会在滚动经过亮部时闪烁）。
const int _imageModeTextArgb = 0xFFECECEC;

/// 正文对比度目标（WCAG AA 小字号 4.5:1）。
const double _textContrastTarget = 4.5;

/// 达到 [_textContrastTarget] 时，图与遮罩混合后允许的最大 sRGB 通道值。
///
/// 遮罩是纯黑叠加且由 GPU 在 sRGB 空间混合，故单个通道满足
/// `channel * (1 - dim) <= budget`。0.42 由 #ECECEC 反解得到。
final double _textChannelBudget = _budgetForTextColor(_imageModeTextArgb);

/// 采样图片亮度（每次选图/启动一次）。
///
/// 通过引擎图片编解码器把图片解成 32×32 缩略图（解码在 UI isolate 之外），
/// 返回不透明像素的相对亮度 **90 分位值**；文件读不到、解码失败或没有不透明
/// 像素时返回 null（调用方保留用户自己的遮罩设置）。
///
/// 用分位数而不是均值：一张暗图里的一盏灯 / 一片亮天空不会被大面积暗部平均
/// 掉，否则最亮的那块恰好是标题所在的位置时仍然不可读。
Future<double?> sampleImageLuminance(String path) async {
  Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 32,
      targetHeight: 32,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return _percentileLuminance(data.buffer.asUint8List(), 0.9);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// 保证深色正文在图片上可读所需的最小遮罩浓度。
///
/// [luminance] 为 [sampleImageLuminance] 的结果（null = 未测到）：
/// - 未测到或接近全黑 → 用户设置的原下限 [kBackgroundDimMin]；
/// - 越亮 → 下限越高，最亮（纯白）约 58%，封顶 [kBackgroundDimAutoMax]。
///
/// 只作为**下限**：用户把滑块调得更高时以用户为准；存盘的 `backgroundDim`
/// 仍是用户意图，换一张更暗的图后会自动回到原来的值。
double backgroundDimFloorFor(double? luminance) {
  if (luminance == null || luminance <= 0) return kBackgroundDimMin;
  final channel = _encode(luminance.clamp(0.0, 1.0));
  if (channel <= 0) return kBackgroundDimMin;
  final floor = 1 - _textChannelBudget / channel;
  return floor.clamp(kBackgroundDimMin, kBackgroundDimAutoMax).toDouble();
}

/// 取不透明像素相对亮度的 [percentile] 分位值（0~1），无样本返回 null。
double? _percentileLuminance(Uint8List rgba, double percentile) {
  final values = <double>[];
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 16) continue;
    values.add(_relativeLuminance(rgba[i], rgba[i + 1], rgba[i + 2]));
  }
  if (values.isEmpty) return null;
  values.sort();
  final index = ((values.length - 1) * percentile).round().clamp(
    0,
    values.length - 1,
  );
  return values[index];
}

double _budgetForTextColor(int argb) {
  final text = _relativeLuminance(
    (argb >> 16) & 0xFF,
    (argb >> 8) & 0xFF,
    argb & 0xFF,
  );
  final background = (text + 0.05) / _textContrastTarget - 0.05;
  return _encode(background.clamp(0.0, 1.0));
}

/// WCAG 相对亮度（sRGB 线性化后按 Rec.709 系数加权）。
double _relativeLuminance(int red, int green, int blue) =>
    0.2126 * _linear(red) + 0.7152 * _linear(green) + 0.0722 * _linear(blue);

double _linear(int channel) {
  final value = channel / 255;
  return value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
}

double _encode(double linear) {
  if (linear <= 0.0031308) return linear * 12.92;
  return (1.055 * math.pow(linear, 1 / 2.4) - 0.055).toDouble();
}

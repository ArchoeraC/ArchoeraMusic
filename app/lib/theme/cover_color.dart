// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show ByteData, Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';

/// 封面取样尺寸（对齐原版 COVER_SAMPLE_SIZE=64，缩图降计算量）。
const int _sampleSize = 64;

/// 封面边缘留白（跳过四周装饰/边框干扰）。
const int _edgeMargin = 3;

/// 候选桶最低色度（HCT chroma，对齐原版 MIN_COVER_CHROMA=8）。
const double _minChroma = 8;

/// 彩色区域至少覆盖该比例，避免少量点缀色覆盖大面积中性色
/// （对齐原版 MIN_COLORFUL_POPULATION_RATIO=0.12）。
const double _minColorfulRatio = 0.12;

/// 从封面提取代表主色（对齐 SPlayer-Next `utils/color.ts`）：
/// 解码缩放到 64×64 → 中心区域加权取样 → **Material 色度量化（QuantizerCelebi）**
/// → 用 **HCT 感知色彩空间**（色度/色调）过滤与评分选代表色 → 约束到适合作为
/// 背景基色的范围。
///
/// 相比朴素 4bit 分桶 + HSL 饱和度/亮度：Celebi 量化能处理复杂封面的多色分布；
/// HCT 的 tone/chroma 是感知量，浅色（高亮度）封面也能稳定选出可用主色，
/// 不再因相对亮度阈值而大量落空。
///
/// 本地文件直接读字节；http(s) 走全局 [HttpClient]（默认 UA 已由 CoverImage 的
/// HttpOverrides 设置为浏览器 UA，CDN 可正常访问）。加载失败 / 单调 / 低彩度返回
/// null（调用方回退设计体系默认色）。
Future<Color?> extractDominantColor(String cover) async {
  if (cover.isEmpty) return null;
  final List<int> bytes;
  try {
    if (cover.startsWith('http')) {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(cover));
        final res = await req.close();
        if (res.statusCode != 200) return null;
        bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      } finally {
        client.close();
      }
    } else {
      final path = cover.startsWith('file://') ? cover.substring(7) : cover;
      final file = File(path);
      if (!file.existsSync()) return null;
      bytes = file.readAsBytesSync();
    }
  } catch (_) {
    return null;
  }

  try {
    // 解码时直接缩到取样尺寸，避免大图全量解码
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(bytes),
      targetWidth: _sampleSize,
      targetHeight: _sampleSize,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    final height = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    final picked = await _pickRepresentative(data, width, height);
    if (picked == null) return null;
    return _toCoverBaseColor(picked);
  } catch (_) {
    return null;
  }
}

/// 中心区域加权（对齐原版 sampleWeight：中心 34% 内权重 3，58% 内 2）。
double _sampleWeight(int x, int y) {
  final center = (_sampleSize - 1) / 2;
  final dx = (x - center) / center;
  final dy = (y - center) / center;
  final distance = math.sqrt(dx * dx + dy * dy);
  if (distance < 0.34) return 3;
  if (distance < 0.58) return 2;
  return 1;
}

/// 中心加权取样 → QuantizerCelebi 量化 → HCT 感知评分选代表色。
/// 返回 ARGB int；单调/低彩度返回 null。
Future<int?> _pickRepresentative(ByteData data, int width, int height) async {
  // 加权取样：按权重重复 push 像素（对齐原版），交由量化器统计。
  final pixels = <int>[];
  for (var y = _edgeMargin; y < height - _edgeMargin; y++) {
    for (var x = _edgeMargin; x < width - _edgeMargin; x++) {
      final i = (y * width + x) * 4;
      final a = data.getUint8(i + 3);
      if (a < 16) continue; // 近透明跳过
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      final argb = (a << 24) | (r << 16) | (g << 8) | b;
      final weight = _sampleWeight(x, y).round();
      for (var j = 0; j < weight; j++) {
        pixels.add(argb);
      }
    }
  }
  if (pixels.isEmpty) return null;
  final quantized = await QuantizerCelebi().quantize(pixels, 128);
  return _pickFromQuantized(quantized.colorToCount);
}

/// 从量化结果按「占比 + 色度 + 色调」评分选代表色（对齐原版
/// pickRepresentativeCoverColor）。
int? _pickFromQuantized(Map<int, int> colorToCount) {
  if (colorToCount.isEmpty) return null;
  var total = 0;
  for (final c in colorToCount.values) {
    total += c;
  }
  final colorful = <int, int>{};
  var colorfulCount = 0;
  for (final entry in colorToCount.entries) {
    final hct = Hct.fromInt(entry.key);
    if (hct.chroma >= _minChroma && hct.tone >= 10 && hct.tone <= 94) {
      colorful[entry.key] = entry.value;
      colorfulCount += entry.value;
    }
  }
  if (colorful.isEmpty || colorfulCount / total < _minColorfulRatio) {
    return null;
  }
  final maxCount = colorful.values.reduce(math.max);
  int? best;
  var bestScore = 0.0;
  for (final entry in colorful.entries) {
    final hct = Hct.fromInt(entry.key);
    final populationScore = math.pow(entry.value / maxCount, 0.72).toDouble();
    final chromaScore = math.min(hct.chroma / 52, 1);
    final toneScore = math.max(0.0, 1 - (hct.tone - 58).abs() / 58);
    final score =
        populationScore * 0.58 + chromaScore * 0.28 + toneScore * 0.14;
    if (score > bestScore) {
      bestScore = score;
      best = entry.key;
    }
  }
  return best;
}

/// 把代表色约束到适合作为背景基色的范围（对齐原版 toCoverBaseColor）：
/// 在 HCT 空间把色调收敛到 [28,72]、色度收敛到 [12,64]，保持色相不变。
/// 浅色封面（高 tone）会被压到 72 以内，深色封面抬到 28，均得到可读基色。
Color _toCoverBaseColor(int argb) {
  final hct = Hct.fromInt(argb);
  final tone = hct.tone.clamp(28.0, 72.0).toDouble();
  final chroma = hct.chroma.clamp(12.0, 64.0).toDouble();
  final out = Hct.from(hct.hue, chroma, tone).toInt();
  return Color(0xFF000000 | (out & 0xFFFFFF));
}

/// 封面取色（主题色来源 = cover 时作为主色种子）。
///
/// 实时跟随当前曲目：切歌/切到 cover 来源时重新提取；切走 cover 时清空。
/// 仅 cover 模式下才发请求（其余来源下 _extract 直接返回，避免无谓网络流量）。
final coverColorProvider =
    NotifierProvider<CoverColorNotifier, Color?>(CoverColorNotifier.new);

class CoverColorNotifier extends Notifier<Color?> {
  int _token = 0;

  @override
  Color? build() {
    // 切歌 → 重新提取封面主色（幂等，重复触发无副作用）
    ref.listen(playbackProvider.select((s) => s.track), (_, track) {
      _extract(track?.cover);
    });
    // 切到 cover 来源 → 立即按当前曲目取色；切走 → 清空
    ref.listen(appPrefsProvider.select((p) => p.themeSource), (_, source) {
      if (source == 'cover') {
        _extract(ref.read(playbackProvider).track?.cover);
      } else {
        state = null;
      }
    });
    _extract(ref.read(playbackProvider).track?.cover);
    return null;
  }

  Future<void> _extract(String? cover) async {
    if (ref.read(appPrefsProvider).themeSource != 'cover') return;
    // 竞态 token：只认最后一次取色结果
    final token = ++_token;
    final color = cover == null || cover.isEmpty
        ? null
        : await extractDominantColor(cover);
    if (token == _token) state = color;
  }
}

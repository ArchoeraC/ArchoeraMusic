import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show ByteData, Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';

/// 封面取样尺寸（对齐原版 COVER_SAMPLE_SIZE=64，缩图降计算量）。
const int _sampleSize = 64;

/// 封面边缘留白（跳过四周装饰/边框干扰）。
const int _edgeMargin = 3;

/// 候选桶最低彩度（对齐原版 MIN_COVER_CHROMA=8）。
const double _minSaturation = 0.12;

/// 彩色区域至少覆盖该比例，避免少量点缀色覆盖大面积中性色
/// （对齐原版 MIN_COLORFUL_POPULATION_RATIO=0.12）。
const double _minColorfulRatio = 0.12;

/// 从封面提取代表主色（对齐原版 utils/color.ts extractColorFromImage 思路）：
/// 解码缩放到 64×64 → 中心区域加权取样 → 量化成色桶 → 按「占比 + 彩度 +
/// 亮度」评分选代表色 → 约束到适合作为背景基色的范围。
///
/// 本地文件直接读字节；http(s) 走全局 [HttpClient]（默认 UA 已由
/// CoverImage 的 HttpOverrides 设置为浏览器 UA，CDN 可正常访问）。
/// 加载失败 / 单调 / 低彩度返回 null（调用方回退设计体系默认色）。
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

  final Color? representative;
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
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    representative = _pickRepresentative(data, image.width, image.height);
  } catch (_) {
    return null;
  }
  if (representative == null) return null;
  return _clampCoverBase(representative);
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

/// 量化取色：色桶（每通道 4bit 量化）→ 彩度/亮度过滤 → 加权评分。
Color? _pickRepresentative(ByteData data, int width, int height) {
  final buckets = <int, _Bucket>{};
  double totalCount = 0;
  for (var y = _edgeMargin; y < height - _edgeMargin; y++) {
    for (var x = _edgeMargin; x < width - _edgeMargin; x++) {
      final i = (y * width + x) * 4;
      final a = data.getUint8(i + 3);
      if (a < 16) continue; // 近透明跳过
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      // 每通道 4bit 量化成桶
      final key = (r & 0xF0) << 8 | (g & 0xF0) << 4 | (b & 0xF0);
      final weight = _sampleWeight(x, y);
      final bucket = buckets.putIfAbsent(key, () => _Bucket());
      bucket.count += weight;
      bucket.r += r * weight;
      bucket.g += g * weight;
      bucket.b += b * weight;
      totalCount += weight;
    }
  }
  if (buckets.isEmpty) return null;

  // 过滤出「彩色」候选（彩度足够 + 亮度在可读范围）
  final colorful = buckets.values.where((b) {
    final avg = b.average();
    final s = _saturation(avg);
    final lum = _luminance(avg);
    return s >= _minSaturation && lum >= 0.06 && lum <= 0.92;
  }).toList();
  if (colorful.isEmpty) return null;
  final colorfulCount = colorful.fold<double>(0, (sum, b) => sum + b.count);
  if (colorfulCount / totalCount < _minColorfulRatio) return null;

  final maxCount =
      colorful.map((b) => b.count).reduce(math.max);
  Color? best;
  var bestScore = 0.0;
  for (final b in colorful) {
    final avg = b.average();
    final populationScore = math.pow(b.count / maxCount, 0.72).toDouble();
    final saturationScore = math.min(_saturation(avg) / 0.55, 1);
    final lum = _luminance(avg);
    final toneScore = math.max(0, 1 - (lum - 0.3).abs() / 0.6);
    final score =
        populationScore * 0.58 + saturationScore * 0.28 + toneScore * 0.14;
    if (score > bestScore) {
      bestScore = score;
      best = avg;
    }
  }
  return best;
}

/// 色桶（累计加权和，取均值还原颜色）。
class _Bucket {
  double count = 0;
  double r = 0;
  double g = 0;
  double b = 0;

  Color average() => Color.fromARGB(
        255,
        (r / count).round().clamp(0, 255),
        (g / count).round().clamp(0, 255),
        (b / count).round().clamp(0, 255),
      );
}

double _saturation(Color c) {
  final max = math.max(c.r, math.max(c.g, c.b));
  final min = math.min(c.r, math.min(c.g, c.b));
  return max == 0 ? 0 : (max - min) / max;
}

double _luminance(Color c) =>
    0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

/// 把代表色约束到适合作为背景基色的范围（对齐原版 toCoverBaseColor：
/// 收敛彩度与亮度，避免过艳/过亮/过暗的种子）。
Color _clampCoverBase(Color c) {
  var out = c;
  // 彩度压到 0.5 以内（太鲜艳时向灰阶收敛）
  final s = _saturation(out);
  if (s > 0.5) {
    out = Color.lerp(out, const Color(0xFF808080), (s - 0.5) / s)!;
  }
  // 亮度约束到 [0.15, 0.55]（过亮向黑、过暗向白收敛）
  var lum = out.computeLuminance();
  if (lum > 0.55) {
    out = Color.lerp(out, Colors.black, (lum - 0.55) / lum)!;
  } else if (lum < 0.15) {
    out = Color.lerp(out, Colors.white, (0.15 - lum) / 0.15)!;
  }
  lum = out.computeLuminance();
  if (lum > 0.55) out = Color.lerp(out, Colors.black, (lum - 0.55) / lum)!;
  return out;
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

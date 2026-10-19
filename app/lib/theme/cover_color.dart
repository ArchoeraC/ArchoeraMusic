// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show ByteData, BytesBuilder, Uint8List;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../utils/safe_file.dart';
import 'theme_sources/theme_source_registry.dart';

/// 封面取样尺寸（对齐原版 COVER_SAMPLE_SIZE=64，缩图降计算量）。
const int _sampleSize = 64;

/// 封面边缘留白（跳过四周装饰/边框干扰）。
const int _edgeMargin = 3;

/// 候选桶最低色度（HCT chroma）。取 2：封面只要有一点点偏色（偏暖/偏冷的灰）
/// 就采用其色相；真正无色相（chroma≈0）时才保持近中性。
const double _minChroma = 2;

/// 「近中性/噪声」色度阈值：低于此值视为量化/HCT 噪声（如偏白封面的轻微冷色），
/// 基色**中性化**（chroma 0）。否则 `ColorScheme.fromSeed` 会把这点噪声色度
/// 放大成突兀的彩色方案（偏白封面出青色）。真实偏色（≥ 此值）才保留。
const double _neutralChroma = 6;

/// 彩色区域至少覆盖该比例，避免少量点缀色覆盖大面积中性色
/// （对齐原版 MIN_COLORFUL_POPULATION_RATIO=0.12）。
const double _minColorfulRatio = 0.12;

/// 从封面提取代表主色：
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
        // BytesBuilder 线性累积（旧实现 fold + addAll 是 O(n²) 且产生巨量
        // 中间 int 列表；封面可达数百 KB～数 MB）。
        final bb = BytesBuilder(copy: false);
        await for (final chunk in res) {
          bb.add(chunk);
        }
        bytes = bb.takeBytes();
      } finally {
        client.close();
      }
    } else {
      final path = cover.startsWith('file://') ? cover.substring(7) : cover;
      // 安全读取：封面路径可能来自用户音乐库（同用户可写）——拒绝 FIFO/设备/目录与超大文件。
      final safe = SafeFile.readBytes(path, maxBytes: 64 << 20);
      if (safe == null) return null;
      bytes = safe;
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
    // 没有足够彩色（纯灰/近灰，或彩色仅少量点缀）：**不再判无效**，
    // 回退到最多数色——保留封面本色（多为中性 → 近中性基色）。
    return _mostPopulous(colorToCount);
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

/// 最多数色（保底：无彩色候选时用，保留封面主色调）。
int _mostPopulous(Map<int, int> colorToCount) {
  var best = colorToCount.keys.first;
  var bestCount = -1;
  for (final e in colorToCount.entries) {
    if (e.value > bestCount) {
      bestCount = e.value;
      best = e.key;
    }
  }
  return best;
}

/// 把代表色约束到适合作为背景基色的范围（对齐原版 toCoverBaseColor）：
/// 在 HCT 空间保持色相，色调收敛到 [28,72]。
/// 色度：低于 [_neutralChroma] 视为噪声 → **中性化**（0），避免 fromSeed 放大成
/// 突兀彩色；否则保留本色度（上限 64），不额外放大。
Color _toCoverBaseColor(int argb) {
  final hct = Hct.fromInt(argb);
  final tone = hct.tone.clamp(28.0, 72.0).toDouble();
  final chroma = hct.chroma < _neutralChroma ? 0.0 : math.min(hct.chroma, 64.0);
  final out = Hct.from(hct.hue, chroma, tone).toInt();
  return Color(0xFF000000 | (out & 0xFFFFFF));
}

/// 封面取色（主题色来源 = cover 时作为主色种子）。
///
/// 实时跟随当前曲目：切歌/切到 cover 来源时重新提取；切走 cover 时清空。
/// 仅 cover 模式下才发请求（其余来源下 _extract 直接返回，避免无谓网络流量）。
final coverColorProvider = NotifierProvider<CoverColorNotifier, Color?>(
  CoverColorNotifier.new,
);

class CoverColorNotifier extends Notifier<Color?> {
  int _token = 0;

  /// 封面 → 主色结果缓存（含 null 负结果）。切歌来回跳时避免重复下载+解码
  /// （旧实现每次 track 变化都整幅重下并重新量化）。LRU 近似：超限删最旧。
  static const int _cacheMax = 64;
  final Map<String, Color?> _cache = <String, Color?>{};

  /// 清空取色缓存（应用进入后台时释放；下次取色重新计算）。
  void clearCache() => _cache.clear();

  @override
  Color? build() {
    // 切歌 → 重新提取封面主色（幂等，重复触发无副作用）
    ref.listen(playbackProvider.select((s) => s.track), (_, track) {
      _extract(track?.cover);
    });
    // 主题色来源切到 cover、或开启「歌词跟随封面颜色」→ 立即按当前曲目
    // 取色；两者都关闭 → 清空（避免无谓的封面取色请求）。
    ref.listen(
      appPrefsProvider.select((p) => (p.themeSource, p.followCoverColor)),
      (_, v) {
        if (themeSourceStyleFor(v.$1).usesCoverAccent || v.$2) {
          _extract(ref.read(playbackProvider).track?.cover);
        } else {
          state = null;
        }
      },
    );
    _extract(ref.read(playbackProvider).track?.cover);
    return null;
  }

  Future<void> _extract(String? cover) async {
    final prefs = ref.read(appPrefsProvider);
    // 仅在需要封面色时取色（global cover 主题 或 歌词跟随封面颜色）。
    if (!themeSourceStyleFor(prefs.themeSource).usesCoverAccent &&
        !prefs.followCoverColor) {
      return;
    }
    // 竞态 token：只认最后一次取色结果
    final token = ++_token;
    if (cover == null || cover.isEmpty) {
      state = null;
      return;
    }
    if (_cache.containsKey(cover)) {
      final hit = _cache.remove(cover); // 值可能为 null（负结果）
      _cache[cover] = hit; // LRU 保活
      if (token == _token) state = hit;
      return;
    }
    final color = await extractDominantColor(cover);
    if (_cache.length >= _cacheMax) _cache.remove(_cache.keys.first);
    _cache[cover] = color;
    if (token == _token) state = color;
  }
}

/// 播放页「封面主色」背景（`coverTone`）专用取色。
///
/// 与 [coverColorProvider] 的分工：
/// - [coverColorProvider] 服务于全局主题 / 歌词跟随，受
///   `themeSourceStyleFor(...).usesCoverAccent || followCoverColor` 门控；
/// - 本 provider 只服务背景样式，**不能沿用**上述门控——否则默认主题下
///   `coverTone` 将永远取不到色、只剩兜底渐变。
///
/// 为避免用户不用该样式时白白下载/解码封面，仅在背景样式为 `coverTone`
/// 时取色（这是「是否使用」判断，不是主题来源门控）；切走时清空颜色但保留
/// 缓存，切回可直接命中。
final playerCoverToneProvider =
    NotifierProvider<PlayerCoverToneNotifier, Color?>(
      PlayerCoverToneNotifier.new,
    );

class PlayerCoverToneNotifier extends Notifier<Color?> {
  /// 竞态 token：只认最后一次取色的结果（快速切歌时旧请求不得覆盖新颜色）。
  int _token = 0;

  /// 封面 → 主色缓存（含 null 负结果）。与 [CoverColorNotifier] 各自持有：
  /// 两边门控/生命周期不同，共用会让其中一方的清空影响另一方。
  /// LRU 近似：超限删最旧。
  static const int _cacheMax = 64;
  final Map<String, Color?> _cache = <String, Color?>{};

  /// 清空取色缓存（应用进入后台时释放）。
  void clearCache() => _cache.clear();

  @override
  Color? build() {
    // 切歌 → 重新提取（仅背景在用 coverTone 时才真正发请求，见 [_extract]）。
    ref.listen(playbackProvider.select((s) => s.track), (_, track) {
      _extract(track?.cover);
    });
    // 背景样式切换：切到 coverTone 立即按当前曲目取色；切走则清空颜色。
    ref.listen(
      appPrefsProvider.select((p) => p.playerBgType),
      (_, _) => _extract(ref.read(playbackProvider).track?.cover),
    );
    // 首次挂载：build 内不写 state（初始值本就是 null），只发起取色。
    if (ref.read(appPrefsProvider).playerBgType == 'coverTone') {
      _extract(ref.read(playbackProvider).track?.cover);
    }
    return null;
  }

  Future<void> _extract(String? cover) async {
    // 递增 token 必须在所有分支之前：切走/清空同样要作废在途请求。
    final token = ++_token;
    if (ref.read(appPrefsProvider).playerBgType != 'coverTone' ||
        cover == null ||
        cover.isEmpty) {
      _clear();
      return;
    }
    if (_cache.containsKey(cover)) {
      final hit = _cache.remove(cover); // 值可能为 null（负结果）
      _cache[cover] = hit; // LRU 保活
      if (token == _token) _publish(hit);
      return;
    }
    final color = await extractDominantColor(cover);
    // 缓存即使被更新的请求取代也保留，方便来回切歌命中。
    if (_cache.length >= _cacheMax) _cache.remove(_cache.keys.first);
    _cache[cover] = color;
    if (token == _token) _publish(color);
  }

  /// 写入颜色；`ref.mounted` 防御容器/测试提前销毁后的迟到回调。
  void _publish(Color? color) {
    if (ref.mounted) state = color;
  }

  /// 清空当前颜色（保留缓存）。build 期间也安全：`stateOrNull` 未初始化时为 null。
  void _clear() {
    if (!ref.mounted) return;
    if (stateOrNull != null) state = null;
  }
}

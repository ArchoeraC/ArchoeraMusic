// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 首页「随机聚光」：从若干候选池里抽一组歌、随机指定起始曲。
///
/// 设计目标（与常见实现刻意不同）：
/// - **可复现**：随机数由「逻辑日 + 重掷次数」派生（[spotlightSeed]），
///   同一逻辑日、同一重掷次数下选择稳定——避免 Flutter 高频 rebuild 时
///   卡片每次都换歌；
/// - **不连着撞**：来源带权重（个性化优先），上一轮来源降权（冷却）；
///   起始曲避开最近展示过的几首（[SpotlightPick]）；
/// - **可再掷**：调用方递增重掷次数即可「换一批」。
library;

import '../netease/track.dart';

/// 聚光来源：每日推荐 / 我的收藏 / 本地曲库。
enum SpotlightSource { daily, liked, local }

/// 各来源基础权重（越大越容易被抽中；个性化来源优先）。
const Map<SpotlightSource, int> kSpotlightWeights = {
  SpotlightSource.daily: 5,
  SpotlightSource.liked: 3,
  SpotlightSource.local: 2,
};

/// 与上一轮同源时的冷却系数（百分比）：降低但不归零，仍可能偶尔连中。
const int kSpotlightSourceCooldownPercent = 30;

/// 起始曲避让记忆长度（最近展示过的不再当起始曲）。
const int kSpotlightLeadMemory = 4;

/// 起始曲避让的最大重试次数（池子太小则退回随机结果）。
const int kSpotlightLeadAttempts = 6;

/// 一次聚光的结果：来源 + 曲目池 + 起始曲下标。
class SpotlightPick {
  const SpotlightPick({
    required this.source,
    required this.tracks,
    required this.leadIndex,
  });

  final SpotlightSource source;
  final List<Track> tracks;

  /// 起始曲下标（决定封面 / 标题 / 立即播放的起点）。
  final int leadIndex;

  /// 起始曲；池子为空时为 null。
  Track? get lead =>
      (leadIndex >= 0 && leadIndex < tracks.length) ? tracks[leadIndex] : null;

  /// 从起始曲起、回绕取 [count] 首的预览。
  List<Track> preview(int count) {
    if (tracks.isEmpty || count <= 0) return const [];
    final out = <Track>[];
    for (var i = 0; i < count && i < tracks.length; i++) {
      out.add(tracks[(leadIndex + i) % tracks.length]);
    }
    return out;
  }
}

/// 曲目稳定标识（跨平台唯一）：`source:id`。
String spotlightTrackKey(Track track) => '${track.source}:${track.id}';

/// 32 位 xorshift 伪随机数（我们自己的轻量实现；仅用于 UI 选曲，
/// 不承担任何安全用途）。相同种子在不同平台/版本上序列一致，便于测试。
class SpotlightRng {
  SpotlightRng(int seed) : _state = (seed & 0x7FFFFFFF) | 1;

  int _state;

  int _next() {
    var x = _state;
    x ^= (x << 13) & 0x7FFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0x7FFFFFFF;
    _state = x & 0x7FFFFFFF;
    return _state;
  }

  /// `[0, max)` 内整数；max ≤ 0 返回 0。
  int nextInt(int max) => max <= 0 ? 0 : _next() % max;
}

/// FNV-1a 32 位字符串散列（稳定、跨版本一致）。
int _fnv1a(String text) {
  var h = 0x811C9DC5;
  for (final c in text.codeUnits) {
    h ^= c & 0xFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// 由逻辑日与重掷次数派生随机种子。
int spotlightSeed(String dayKey, int roll) {
  final base = _fnv1a(dayKey);
  // 每重掷一次混入一个黄金比例常量（与线性同余的常见做法同构但自有取值）。
  return (base ^ ((roll + 1) * 0x1F123BB5)) & 0x7FFFFFFF;
}

/// 从候选池抽一次聚光；所有池都为空时返回 null。
///
/// - [pools]：来源 → 曲目（空列表的来源不参与）；
/// - [rng]：随机源（调用方用 [spotlightSeed] 构造以保证可复现）；
/// - [avoidSource]：上一轮来源（降权冷却）；
/// - [recentLeadKeys]：最近展示过的起始曲 [spotlightTrackKey]（避让）。
SpotlightPick? rollSpotlight({
  required Map<SpotlightSource, List<Track>> pools,
  required SpotlightRng rng,
  SpotlightSource? avoidSource,
  Set<String> recentLeadKeys = const {},
  Map<SpotlightSource, int> weights = kSpotlightWeights,
}) {
  final available = [
    for (final e in pools.entries)
      if (e.value.isNotEmpty) e.key,
  ];
  if (available.isEmpty) return null;

  final source = _pickSource(
    available: available,
    rng: rng,
    avoidSource: avoidSource,
    weights: weights,
  );
  final tracks = pools[source]!;

  var leadIndex = rng.nextInt(tracks.length);
  if (tracks.length > 1 && recentLeadKeys.isNotEmpty) {
    for (var attempt = 0; attempt < kSpotlightLeadAttempts; attempt++) {
      final candidate = rng.nextInt(tracks.length);
      if (!recentLeadKeys.contains(spotlightTrackKey(tracks[candidate]))) {
        leadIndex = candidate;
        break;
      }
      leadIndex = candidate;
    }
  }
  return SpotlightPick(source: source, tracks: tracks, leadIndex: leadIndex);
}

SpotlightSource _pickSource({
  required List<SpotlightSource> available,
  required SpotlightRng rng,
  required SpotlightSource? avoidSource,
  required Map<SpotlightSource, int> weights,
}) {
  var total = 0;
  final effective = <SpotlightSource, int>{};
  for (final s in available) {
    var w = weights[s] ?? 1;
    if (s == avoidSource) {
      w = (w * kSpotlightSourceCooldownPercent) ~/ 100;
      if (w < 1) w = 1;
    }
    effective[s] = w;
    total += w;
  }
  var roll = rng.nextInt(total);
  for (final s in available) {
    roll -= effective[s]!;
    if (roll < 0) return s;
  }
  return available.last;
}

/// 把本次起始曲记入避让记忆（保持最近 [kSpotlightLeadMemory] 条，最新在前）。
List<String> pushRecentLead(
  List<String> recent,
  Track? lead, {
  int limit = kSpotlightLeadMemory,
}) {
  if (lead == null) return recent;
  final key = spotlightTrackKey(lead);
  final next = [key, ...recent.where((k) => k != key)];
  return next.length > limit ? next.sublist(0, limit) : next;
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词「模糊匹配」共享流程：`fingerprint 缓存 → 搜索 → 挑最佳 → 按 id 直取`。
///
/// 三个平台（netease / qqmusic / kugou）此前各写一份几乎相同的流程；本文件
/// 统一为 [fetchMatchedLyric]，平台只提供两件事：
///  - `search`：关键词 → 归一化候选（含平台主键的 `extra`）；
///  - `byId`：平台主键 + `extra` → 歌词结果。
/// 缓存读写、关键词构造、[pickBestCandidate] 调用都在这里完成。
library;

import '../../services/netease/track.dart';
import '../runtime.dart';
import 'fingerprint.dart';
import 'types.dart';
import 'utils.dart';

/// 搜索回调：关键词 → 候选列表（失败时返回空列表并自行记日志）。
typedef LyricCandidateSearch =
    Future<List<LyricCandidate<Map<String, String>>>> Function(String keyword);

/// 按平台主键直取回调（`extra` 为候选/缓存携带的平台附加字段）。
typedef LyricFetchById =
    Future<LyricMatchResult?> Function(String id, Map<String, String> extra);

/// 搜索→匹配→直取的共享流程（含 fingerprint 映射缓存）。
///
/// 命中映射缓存时直接 `byId`；否则搜索并挑最佳，写入映射缓存后再 `byId`。
/// [idOf] 从候选 `extra` 取平台主键（空 = 放弃）。
/// [logMatch] 供调用方输出平台前缀的匹配日志（可选）。
Future<LyricMatchResult?> fetchMatchedLyric({
  required String platform,
  required Track track,
  required LyricCandidateSearch search,
  required LyricFetchById byId,
  required String Function(Map<String, String> extra) idOf,
  void Function(String keyword, int hits, String? bestName)? logMatch,
}) async {
  final fingerprint = buildFingerprint(track);
  final cached = getRuntime().lyricMatchCache.get(fingerprint, platform);
  if (cached != null) {
    return byId(
      cached.platformId,
      Map<String, String>.from(cached.extra ?? const {}),
    );
  }

  final keyword = buildLyricSearchKeyword(track);
  if (keyword.isEmpty) return null;

  final candidates = await search(keyword);
  final best = pickBestCandidate(candidates, track);
  logMatch?.call(keyword, candidates.length, best?.name);
  if (best == null) return null;

  final id = idOf(best.extra);
  if (id.isEmpty) return null;
  getRuntime().lyricMatchCache.set(fingerprint, platform, id, best.extra);
  return byId(id, best.extra);
}

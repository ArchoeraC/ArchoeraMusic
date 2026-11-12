// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地搜索索引排行接入的**纯策略层**（可单测，无 FFI / 无 IO）。
///
/// 曲库列表分页与索引排行解耦：本层只回答两个问题——
/// 1. 该不该用索引（[shouldUseSearchIndex]）；
/// 2. 命中列表 → 有序 `trackId` 列表（[resolveRankedSearch]）。
///
/// 真正的索引查询由调用方经 `SearchService` 注入，确保**总开关关闭时完全
/// 不构造 SearchService / 不触碰 search.db**（设计文档 §2.4）。
library;

import '../search/search_models.dart';

/// 排行结果上限（分页只需有序 id，一次性取足够大覆盖常见曲库）。
///
/// 超出部分截断——大库极端宽泛查询（命中上万）下排行可能不全，属已知取舍。
///
/// **不要再靠调小该值来降延迟**（2026-11-12 量化）：降 limit 对排序**精度无损**
/// （`ORDER BY score LIMIT N` 是全排序前缀，top-N 逐条一致），但只省 20–30%——
/// pooled P50/P95 从 35.9/74.3ms（10000）到 28.9/58.4（900）、26.3/56.3（300），
/// 甚至 limit=50 的地板仍有 25.1/52.1ms。成本在「FTS5 给全部命中打分」，不在
/// 「取多少条」；而 `totalCount` = 命中 id 数，调小会让宽查询凭空少掉结果。
const int kSearchIndexRankLimit = 10000;

/// 索引查询函数签名（`SearchService.search` 的窄化子类型，便于注入替身）。
typedef RankedSearchFn =
    Future<List<LocalSearchHit>?> Function(String query, {int limit});

/// 是否走索引排行路径：**总开关开启**且**查询非空**才为真。
///
/// 关闭 / 空查询 / 纯空白一律 false → 调用方保持既有 `LIKE` 路径（等价现状）。
bool shouldUseSearchIndex(String query, bool masterEnabled) =>
    masterEnabled && query.trim().isNotEmpty;

/// 命中列表 → 有序 `trackId` 列表（保持 BM25 排序）。
///
/// [search] 返回 `null`（未开启 / 未就绪 / 失败）时原样返回 `null`，
/// 表示调用方应**回退** `LIKE`；返回空列表表示索引路径的**真实空结果**
/// （不回退，等于「索引说没有命中」）。
Future<List<String>?> resolveRankedSearch(
  String query,
  RankedSearchFn search, {
  int limit = kSearchIndexRankLimit,
}) async {
  final hits = await search(query, limit: limit);
  if (hits == null) return null;
  return [for (final hit in hits) hit.trackId];
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词命中**行内片段**的纯策略层（无 FFI / 无 Flutter 依赖，可单测）。
///
/// 索引排行只给出「命中哪几首」；当某行**标题 / 歌手 / 专辑都无字面高亮**
/// （说明命中来自歌词）时，用 [snippet] 取命中窗口文本，让用户看到「为什么
/// 命中」（设计文档 `docs/local-search-index-plan.md` §2.4 / §9.3）。
///
/// 计算发生在**页加载的异步路径**（`library_store` 的取页 / 重载），结果缓存到
/// `LibraryState.lyricSnippets`，行渲染只做同步查表——**不在 build 每帧**读歌词
/// 或算 snippet；关闭态（查询空 / 非索引排行路径）调用方根本不进入本层，零成本。
library;

import '../scanner/tracks_db.dart';
import 'search_highlight.dart';

/// 每页最多为多少行计算片段（与分页大小同阶；防止单页行数异常时放大开销）。
const int kLyricSnippetMaxRows = 300;

/// 歌词批量读取器：`trackId 列表 → (trackId → 非空歌词文本)`。
typedef LyricsBatchLoader = Map<String, String> Function(List<String> ids);

/// 为 [rows] 中「元数据无字面高亮」的行计算 `trackId → 歌词命中片段`。
///
/// [query] 为空 / [rows] 为空 → 返回空映射（零成本）。仅**字面**命中歌词时才有值；
/// **拼音 / 首字母命中歌词无字面片段**（[snippet] 为字面匹配，拉丁查询 + 汉字
/// 歌词返回 null）→ 该行不出现在结果中（边界见设计文档 §4.2 / §9.3）。
///
/// [loadLyrics] 由调用方注入（生产用 `TracksDb.lyricsByIds` 一次批量查询；
/// 测试可注入替身），避免本层依赖真实 DB。
Map<String, String> buildLyricSnippets(
  List<TrackRow> rows,
  String query, {
  required LyricsBatchLoader loadLyrics,
  int radius = 24,
  int maxRows = kLyricSnippetMaxRows,
}) {
  final keyword = query.trim();
  if (keyword.isEmpty || rows.isEmpty || maxRows <= 0) return const {};

  final candidates = <TrackRow>[];
  for (final row in rows) {
    if (candidates.length >= maxRows) break;
    // 命中来自元数据（标题 / 歌手 / 专辑字面高亮非空）：无需歌词片段。
    if (_hasMetadataHighlight(row, keyword)) continue;
    candidates.add(row);
  }
  if (candidates.isEmpty) return const {};

  final lyrics = loadLyrics([for (final row in candidates) row.id]);
  final out = <String, String>{};
  for (final row in candidates) {
    final text = lyrics[row.id];
    if (text == null || text.isEmpty) continue;
    final s = snippet(text, keyword, radius: radius);
    if (s != null) out[row.id] = s;
  }
  return out;
}

/// 该行标题 / 歌手 / 专辑是否有**字面**高亮（有则命中来自元数据，无需歌词片段）。
bool _hasMetadataHighlight(TrackRow row, String query) {
  if (highlightRanges(row.title, query).isNotEmpty) return true;
  for (final artist in row.artistNames) {
    if (highlightRanges(artist, query).isNotEmpty) return true;
  }
  final album = row.albumName;
  if (album != null && highlightRanges(album, query).isNotEmpty) return true;
  return false;
}

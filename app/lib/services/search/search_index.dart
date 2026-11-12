// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

import 'indexer_ffi.dart';
import 'query_log.dart';
import 'search_models.dart';

/// `search.db` 只读查询视图（**薄 FFI 客户端**）。
///
/// 查询能力（词法 / 拼音 / 首字母 / 日文读音 / 跨语言表达式编译、六段渐进兜底、
/// bm25 排序、`doc_id → track_id` 映射）全部在 C# 索引器内完成（`indexer_query`，
/// 见 `app/core/indexer/SearchSession.cs` / `SearchQuery.cs`）。Dart 只负责：
///   1. 组装查询请求 JSON（[search]）；
///   2. 把结果 JSON 映射为 [LocalSearchHit]；
///   3. 累加兜底趟计数器（诊断 / 测试接缝）；
///   4. 生命周期（[close] 释放 C# 侧缓存的只读会话）。
///
/// C# 侧按 `search.db` 路径缓存一个只读连接；重建 / 删除索引前必须 [close]
/// （Windows 上残留只读句柄会阻塞 `File.Move`）。
class SearchIndex {
  SearchIndex._(this._dbPath, this._lib);

  /// 期望的 `search_meta.schema_version`（与 C# `FtsStore.SchemaVersionValue` 一致；
  /// 不符则视为不可用，触发重建）。
  static const int expectedSchemaVersion = 7;

  /// **候选集上限**（历史参数，已不再裁剪候选；0 = 不限）。
  ///
  /// ⚠ 该机制在 2026-11-12 被撤销：原实现用 `rowid IN (子查询)` 限制候选，导致
  /// FTS5 的 `bm25()` 静默返回 0、相关性排序整体失效（详见
  /// `docs/local-search-index-plan.md` §4.5）。参数保留仅为 ABI / 请求 JSON 兼容，
  /// C# 侧 `FtsStore.Search` 已忽略它并直接全排序。
  static const int defaultCandidateCap = 5000;

  final String _dbPath;
  final IndexerLibrary _lib;
  bool _closed = false;

  /// 本连接已执行的**模糊**（拉丁编辑距离）查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int fuzzyQueries = 0;

  /// 本连接已执行的**中文 CJK 容错**查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int cjkFuzzyQueries = 0;

  /// 本连接已执行的**跨语言兜底**查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int crossLingualQueries = 0;

  /// 本连接已执行的**拼音宽松兜底**查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int pinyinLooseQueries = 0;

  /// 本连接已执行的**日文读音兜底**查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int readingQueries = 0;

  /// 当前**累加**的兜底趟计数器快照。
  ///
  /// 各字段是累加值（每查一次 `+=`），调用方若只想要「本次查询实际执行了哪些趟」，
  /// 需在查询前后各取一次并相减（见 `SearchService.search`）。
  PassCounts get passCounts => PassCounts(
    pinyinLoose: pinyinLooseQueries,
    reading: readingQueries,
    crossLingual: crossLingualQueries,
    fuzzy: fuzzyQueries,
    cjkFuzzy: cjkFuzzyQueries,
  );

  /// 打开 `search.db`（只读）。文件缺失 / schema 版本不符返回 null。
  ///
  /// 这里只做轻量探针（`search_meta` 版本）；真正的只读连接由 C# 在首次
  /// [search] 时建立并缓存。
  static SearchIndex? open(String dbPath, {required IndexerLibrary lib}) {
    if (!isAvailable(dbPath)) return null;
    return SearchIndex._(dbPath, lib);
  }

  /// `search.db` 是否存在且 schema 版本匹配。
  static bool isAvailable(String dbPath) {
    if (!File(dbPath).existsSync()) return false;
    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      return _hasExpectedSchema(db);
    } catch (_) {
      return false;
    } finally {
      db?.close();
    }
  }

  /// 当前视图是否可用（未关闭且库文件仍在）。
  bool get available => !_closed && File(_dbPath).existsSync();

  /// 执行一次搜索，返回按 BM25 相关度升序（最佳在前）的命中列表。
  ///
  /// 渐进兜底（[fuzzy] 为 true 时）：精确 → 拼音宽松 → 日文读音 → 跨语言 →
  /// 拉丁模糊 → 中文删除 / 换位容错，命中数达到 [minExact] 即短路。全部在 C# 内
  /// 完成；本方法只传参、解析结果并累加计数器。
  ///
  /// 空查询返回空列表；原生调用失败抛 [StateError]（调用方按既有约定降级）。
  List<LocalSearchHit> search(
    String query, {
    LocalSearchScope scope = LocalSearchScope.all,
    int limit = 200,
    int offset = 0,
    bool fuzzy = false,
    int minExact = 1,
    int candidateCap = defaultCandidateCap,
  }) {
    if (_closed) return const [];
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final request = jsonEncode({
      'query': keyword,
      'scope': scope == LocalSearchScope.metadata ? 'metadata' : 'all',
      'limit': limit,
      'offset': offset,
      'fuzzy': fuzzy,
      'minExact': minExact,
      'candidateCap': candidateCap,
    });
    final (code, text) = _lib.query(indexPath: _dbPath, requestJson: request);
    if (code != 0) {
      throw StateError(
        text.isEmpty ? 'indexer_query 失败（exit $code）' : text,
      );
    }

    final root = jsonDecode(text) as Map<String, dynamic>;
    final passes = root['passes'];
    if (passes is Map<String, dynamic>) {
      pinyinLooseQueries += _intOf(passes['pinyinLoose']);
      readingQueries += _intOf(passes['reading']);
      crossLingualQueries += _intOf(passes['crossLingual']);
      fuzzyQueries += _intOf(passes['fuzzy']);
      cjkFuzzyQueries += _intOf(passes['cjkFuzzy']);
    }

    final items = root['items'];
    if (items is! List) return const [];
    final hits = <LocalSearchHit>[];
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      final trackId = raw['trackId'];
      final score = raw['score'];
      if (trackId is! String || score is! num) continue;
      hits.add(LocalSearchHit(trackId: trackId, score: score.toDouble()));
    }
    return hits;
  }

  /// 释放 C# 侧缓存的只读查询会话（重建 / 删除索引前必须调用）。
  void close() {
    if (_closed) return;
    _closed = true;
    _lib.closeQuery();
  }

  static int _intOf(Object? value) => value is num ? value.toInt() : 0;

  static bool _hasExpectedSchema(Database db) {
    try {
      final rows = db.select(
        "SELECT value FROM search_meta WHERE key = 'schema_version'",
      );
      if (rows.isEmpty) return false;
      final version = int.tryParse(rows.first['value'] as String? ?? '');
      return version == expectedSchemaVersion;
    } catch (_) {
      return false;
    }
  }
}

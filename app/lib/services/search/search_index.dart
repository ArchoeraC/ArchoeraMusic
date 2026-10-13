// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

import 'search_cjk_fuzzy.dart';
import 'search_models.dart';
import 'search_query.dart';

/// 查询侧分析器签名：文本 → 与索引侧同构的词元（`indexer_analyze` FFI）。
typedef LocalSearchAnalyzer = AnalyzerTokens? Function(String text);

/// `search.db` 只读查询视图（`package:sqlite3` FTS5 `MATCH` + `bm25`）。
///
/// 与 `app/core/indexer`（P1/P2，C# NativeAOT）产物共享同一 schema（设计文档
/// §5.2）：`search_docs`（仅元数据：doc_id / track_id / mtime / 世代）/
/// `search_fts`（FTS5 **contentless**，列序 = bm25 权重序）/
/// `search_meta`（版本 / 世代）。查询只需 `rowid`↔`track_id` 映射，不读 token 文本列。
///
/// **只读多连接**（WAL）：indexer 独占写，Dart 只读查询，无需加载原生模块。
/// indexer 关闭时会 `wal_checkpoint(TRUNCATE)`，故干净状态下以
/// [OpenMode.readOnly] 打开即可（无需 `-shm`）。
class SearchIndex {
  SearchIndex._(this._db, [this._analyzer]);

  /// 期望的 `search_meta.schema_version`（与 C# `FtsStore.SchemaVersionValue` 一致；
  /// 不符则视为不可用，触发重建）。v2：contentless FTS（`search_docs` 仅元数据）。
  static const int expectedSchemaVersion = 2;

  /// bm25 权重（列序：title/artist/album/lyrics/lyrics_tr/lyrics_rom/pinyin/filename）。
  static const String _bm25Weights =
      '4.0, 3.0, 2.0, 1.5, 1.0, 0.5, 2.0, 1.0';

  final Database _db;
  final LocalSearchAnalyzer? _analyzer;
  bool _closed = false;

  /// 本连接已执行的**模糊**（第二趟）查询次数（诊断 / 测试接缝）。
  ///
  /// 两趟策略下用它验证「精确命中即短路、不触发模糊」（[minExact] 达标）。
  @visibleForTesting
  int fuzzyQueries = 0;

  /// 本连接已执行的**中文 CJK 容错**（第三趟）查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int cjkFuzzyQueries = 0;

  /// 打开 `search.db`（只读）。文件缺失 / 打开失败 / schema 版本不符返回 null。
  ///
  /// [analyzer] 用于把字符串查询经原生分析器（`indexer_analyze`）取得词元；
  /// 仅传入 [AnalyzerTokens] 时可为 null。
  static SearchIndex? open(String dbPath, {LocalSearchAnalyzer? analyzer}) {
    if (!File(dbPath).existsSync()) return null;
    Database db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    } catch (_) {
      return null;
    }
    if (!_hasExpectedSchema(db)) {
      db.close();
      return null;
    }
    return SearchIndex._(db, analyzer);
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

  /// 当前连接是否可用（未关闭且 schema 仍匹配）。
  bool get available => !_closed && _hasExpectedSchema(_db);

  /// 执行一次搜索，返回按 BM25 相关度升序（最佳在前）的命中列表。
  ///
  /// [query] 为 [AnalyzerTokens]（已分析）或 [String]（经 [_analyzer] 分析）。
  /// 空查询 / 无可用表达式返回空列表。rowid 经 `search_docs` 映射回 `track_id`。
  ///
  /// **分级容错**（[fuzzy] 为 true 时，设计文档 §4.6）：
  /// 1. 先跑精确 [compileMatch]；命中数 ≥ [minExact] 直接返回（短路，不触发后续）；
  /// 2. 查询含拉丁 / 数字词元（[hasFuzzyEligible]）时跑 [compileFuzzy]
  ///    （编辑距离 ≤ 1 变体）；结果与第 1 趟合并去重、精确优先；
  /// 3. 仍不足且查询含 **CJK** 时跑中文容错 [_runCjkVariants]：对 CJK 子序列生成
  ///    删除 / 相邻换位变体，经分析器（FFI，同构）逐个编译后合并为**单条** OR
  ///    表达式一次查询；结果再合并、前面趟次优先。
  ///
  /// 默认 [fuzzy]=false，语义与既有单趟精确一致。
  List<LocalSearchHit> search(
    Object query, {
    LocalSearchScope scope = LocalSearchScope.all,
    int limit = 200,
    int offset = 0,
    bool fuzzy = false,
    int minExact = 1,
  }) {
    if (_closed) return const [];

    final AnalyzerTokens? tokens;
    if (query is AnalyzerTokens) {
      tokens = query;
    } else if (query is String) {
      final analyzer = _analyzer;
      if (analyzer == null) throw StateError('SearchIndex 未配置分析器');
      tokens = analyzer(query);
    } else {
      return const [];
    }
    if (tokens == null || tokens.isEmpty) return const [];

    // 第一趟：精确表达。
    final exact = _runMatch(tokens, scope: scope, limit: limit, offset: offset);
    // 已达标（默认 ≥1）→ 短路，不做模糊（避免无谓放大召回 / 开销）。
    if (!fuzzy || exact.length >= minExact) return exact;

    var hits = exact;

    // 第二趟：拉丁 / 数字词元的编辑距离 ≤ 1（拼写容错）。
    if (hasFuzzyEligible(tokens)) {
      fuzzyQueries++;
      final expanded = _runMatch(
        tokens,
        scope: scope,
        limit: limit,
        offset: offset,
        useFuzzy: true,
      );
      if (expanded.isNotEmpty) hits = _mergeHits(hits, expanded);
    }

    if (hits.length >= minExact) return hits;

    // 第三趟：中文 CJK 漏字 / 换位容错（同音错字已由拼音分支覆盖）。
    if (query is String) {
      final cjk = _runCjkVariants(
        query,
        scope: scope,
        limit: limit,
        offset: offset,
      );
      if (cjk.isNotEmpty) hits = _mergeHits(hits, cjk);
    }
    return hits;
  }

  /// 编译并执行一次 `MATCH`；[useFuzzy] 时走 [compileFuzzy]，否则 [compileMatch]。
  List<LocalSearchHit> _runMatch(
    AnalyzerTokens tokens, {
    required LocalSearchScope scope,
    required int limit,
    required int offset,
    bool useFuzzy = false,
  }) {
    final expr = useFuzzy
        ? compileFuzzy(tokens, scope: scope)
        : compileMatch(tokens, scope: scope);
    if (expr == null) return const [];
    return _executeMatch(expr, limit: limit, offset: offset);
  }

  /// 第三趟：中文 CJK 容错的**单条 OR 查询**。
  ///
  /// 步骤（纯 Dart 变体生成 + 原生分析同构）：
  /// 1. [cjkVariants] 取 CJK 子序列的删除 / 相邻换位变体（预算上限）；
  /// 2. 每个变体经 [_analyzer]（`indexer_analyze` FFI）分析 → [compileMatch]；
  /// 3. 所有变体表达式以 `OR` 合并为**单个** `MATCH` 表达式，只查询一次
  ///    （[scope]=metadata 时对整个表达式施加列过滤）。
  ///
  /// 无分析器（仅传 [AnalyzerTokens] 的场景）/ 无变体 / 全部编译为空 → 返回空。
  List<LocalSearchHit> _runCjkVariants(
    String rawQuery, {
    required LocalSearchScope scope,
    required int limit,
    required int offset,
  }) {
    final analyzer = _analyzer;
    if (analyzer == null) return const [];
    final variants = cjkVariants(rawQuery);
    if (variants.isEmpty) return const [];

    cjkFuzzyQueries++;
    final parts = <String>[];
    for (final variant in variants) {
      AnalyzerTokens? variantTokens;
      try {
        variantTokens = analyzer(variant);
      } catch (_) {
        continue; // 单个变体分析失败不中断整体
      }
      if (variantTokens == null || variantTokens.isEmpty) continue;
      final expr = compileMatch(variantTokens);
      if (expr != null && expr.isNotEmpty) parts.add('($expr)');
    }
    if (parts.isEmpty) return const [];

    var expr = '(${parts.join(' OR ')})';
    if (scope == LocalSearchScope.metadata) {
      expr = '{$metadataColumns} : $expr';
    }
    return _executeMatch(expr, limit: limit, offset: offset);
  }

  /// 执行一条已编译好的 `MATCH` 表达式，返回 BM25 升序命中列表。
  List<LocalSearchHit> _executeMatch(
    String expr, {
    required int limit,
    required int offset,
  }) {
    final rows = _db.select(
      'SELECT rowid AS doc_id, bm25(search_fts, $_bm25Weights) AS score '
      'FROM search_fts WHERE search_fts MATCH ? ORDER BY score LIMIT ? OFFSET ?',
      [expr, limit <= 0 ? -1 : limit, offset < 0 ? 0 : offset],
    );
    if (rows.isEmpty) return const [];

    final docIds = <int>[for (final row in rows) row['doc_id'] as int];
    final placeholders = List.filled(docIds.length, '?').join(', ');
    final docs = _db.select(
      'SELECT doc_id, track_id FROM search_docs WHERE doc_id IN ($placeholders)',
      docIds,
    );
    final trackIds = <int, String>{
      for (final row in docs) row['doc_id'] as int: row['track_id'] as String,
    };

    final hits = <LocalSearchHit>[];
    for (final row in rows) {
      final trackId = trackIds[row['doc_id'] as int];
      if (trackId == null) continue;
      hits.add(LocalSearchHit(
        trackId: trackId,
        score: (row['score'] as num).toDouble(),
      ));
    }
    return hits;
  }

  /// 合并两趟结果：精确优先，按 trackId 去重（模糊补充精确之外的新命中）。
  List<LocalSearchHit> _mergeHits(
    List<LocalSearchHit> exact,
    List<LocalSearchHit> expanded,
  ) {
    final seen = <String>{for (final hit in exact) hit.trackId};
    final merged = <LocalSearchHit>[...exact];
    for (final hit in expanded) {
      if (seen.add(hit.trackId)) merged.add(hit);
    }
    return merged;
  }

  /// 关闭只读连接。
  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

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

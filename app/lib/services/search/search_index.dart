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
  /// 不符则视为不可用，触发重建）。v2：contentless FTS（`search_docs` 仅元数据）；
  /// v3：新增独立列 `initials_tok`（首字母从 `pinyin_tok` 拆出）。
  /// v4：拼音 / 首字母按**元数据段 / 歌词段**分列（`scope=metadata` 才真正成立）。
  /// v5：新增日文读音列 `reading_meta_tok`（假名 → 罗马字 bigram + Unihan 汉字音训读；仅元数据段）。
  static const int expectedSchemaVersion = 5;

  /// bm25 权重（列序：title/artist/album/lyrics/lyrics_tr/lyrics_rom/pinyin_meta/pinyin_lyrics/
  /// reading_meta/filename/initials_meta/initials_lyrics，与 C# `FtsStore.Bm25Weights` 严格一致）。
  static const String _bm25Weights =
      '4.0, 3.0, 2.0, 1.5, 1.0, 0.5, 2.0, 1.5, 2.0, 1.0, 2.0, 1.5';

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

  /// 本连接已执行的**跨语言兜底**（T1 第二趟）查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int crossLingualQueries = 0;

  /// 本连接已执行的**拼音宽松兜底**（第二趟）查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int pinyinLooseQueries = 0;

  /// 本连接已执行的**日文读音兜底**趟查询次数（诊断 / 测试接缝）。
  @visibleForTesting
  int readingQueries = 0;

  /// **候选集上限**（宽命中查询的工作量上界；0 = 不限，退回「给全部命中打分」）。
  ///
  /// FTS5 的 `ORDER BY bm25` 必须给**全部命中**打分，于是常见词元（拼音音节 / 首字母 /
  /// 高频英文词）会把成本推到 O(命中集) —— 30k 语料实测单条最慢 131ms（命中 29763/30000）。
  /// 做法：先用**无排序**子查询按 rowid 顺序取前 [defaultCandidateCap] 个候选（提前退出、成本有界），
  /// 再只对这批候选做 bm25 排序。效果（30k 实测）：最坏单条 131ms → ≈35–40ms，
  /// 且**窄命中查询完全不受影响**（候选数 < 上限时等价于原路径）。
  ///
  /// 取舍（明确记录）：命中集远超上限时（近乎整库命中，排序本就无意义）结果取自
  /// 「rowid 最小的那一批」而非全库相关性——宽查询下这是**有意**的降级；
  /// 上限取 5000 是「成本几乎不变（探针主导）而质量尽量高」的折中。
  static const int defaultCandidateCap = 5000;

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
  /// **分级容错**（[fuzzy] 为 true 时，设计文档 §4.6）——逐趟递进，命中足够即短路：
  /// 1. **精确** [compileMatch]（相邻短语拼音；**不含跨语言支**）；
  /// 2. **拼音宽松兜底** [compilePinyinLoose]（位置无关 `AND`）——恢复「漏字 / 换位」召回
  ///    （`周伦` → `周杰伦`、`爱我` → `我爱你`），代价是命中集可能很大，故仅在短语趟不足时跑；
  /// 2.5 **日文读音兜底** [compileReading]（拉丁词元 → 字母 bigram；日文曲库的罗马字检索）；
  /// 3. **跨语言兜底** [compileCrossLingual]（T1）——候选多为高频英文词（`愛` → `love`），
  ///    `OR` 进主表达式会把命中集放大到近乎整库（30k 实测单条 116ms），同样只在不足时跑；
  /// 4. 查询含拉丁 / 数字词元（[hasFuzzyEligible]）时跑 [compileFuzzy]（编辑距离 ≤ 1 变体）；
  /// 5. 仍不足且查询含 **CJK** 时跑中文容错 [_runCjkVariants]：对 CJK 子序列生成
  ///    删除 / 相邻换位变体，经分析器（FFI，同构）逐个编译后合并为**单条** OR
  ///    表达式一次查询。各趟结果合并去重、**前面的趟次优先**。
  ///
  /// 默认 [fuzzy]=false，语义与既有单趟精确一致。
  List<LocalSearchHit> search(
    Object query, {
    LocalSearchScope scope = LocalSearchScope.all,
    int limit = 200,
    int offset = 0,
    bool fuzzy = false,
    int minExact = 1,
    int candidateCap = defaultCandidateCap,
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

    // 第一趟：精确表达（短语拼音，不含跨语言支——该支是渐进兜底）。
    var hits = _runMatch(tokens,
        scope: scope, limit: limit, offset: offset, candidateCap: candidateCap);

    // 第二趟：拼音**宽松兜底**（位置无关 `AND`）——恢复「漏字 / 换位」召回
    // （`周伦` → `周杰伦`）。短语趟已命中时不必付这笔开销。
    if (hits.length < minExact) {
      final loose = _runPinyinLoose(tokens,
          scope: scope, limit: limit, offset: offset, candidateCap: candidateCap);
      if (loose.isNotEmpty) hits = _mergeHits(hits, loose);
    }

    // 第二趟半：**日文读音兜底**（罗马字查询 → 假名 / 汉字读音的字母 bigram）。
    if (hits.length < minExact) {
      final reading = _runReading(tokens,
          scope: scope, limit: limit, offset: offset, candidateCap: candidateCap);
      if (reading.isNotEmpty) hits = _mergeHits(hits, reading);
    }

    // 第三趟：跨语言兜底（仅当仍不足且有 T1 候选）。
    if (hits.length < minExact) {
      final crossLingual = _runCrossLingual(tokens,
          scope: scope, limit: limit, offset: offset, candidateCap: candidateCap);
      if (crossLingual.isNotEmpty) hits = _mergeHits(hits, crossLingual);
    }

    // 已达标（默认 ≥1）→ 短路，不做模糊（避免无谓放大召回 / 开销）。
    if (!fuzzy || hits.length >= minExact) return hits;

    // 第四趟：拉丁 / 数字词元的编辑距离 ≤ 1（拼写容错）。
    if (hasFuzzyEligible(tokens)) {
      fuzzyQueries++;
      final expanded = _runMatch(
        tokens,
        scope: scope,
        limit: limit,
        offset: offset,
        useFuzzy: true,
        candidateCap: candidateCap,
      );
      if (expanded.isNotEmpty) hits = _mergeHits(hits, expanded);
    }

    if (hits.length >= minExact) return hits;

    // 第五趟：中文 CJK 漏字 / 换位容错（同音错字已由拼音分支覆盖）。
    if (query is String) {
      final cjk = _runCjkVariants(
        query,
        scope: scope,
        limit: limit,
        offset: offset,
        candidateCap: candidateCap,
      );
      if (cjk.isNotEmpty) hits = _mergeHits(hits, cjk);
    }
    return hits;
  }

  /// 编译并执行一次 `MATCH`；[useFuzzy] 时走 [compileFuzzy]，否则 [compileMatch]。
  /// 拼音宽松兜底趟：只跑 [compilePinyinLoose] 单支（不重复主表达式），
  /// 返回命中（无可兜底音节 / 无命中返回空列表）。
  List<LocalSearchHit> _runPinyinLoose(
    AnalyzerTokens tokens, {
    required LocalSearchScope scope,
    required int limit,
    required int offset,
    int candidateCap = defaultCandidateCap,
  }) {
    final expr = compilePinyinLoose(tokens, scope: scope);
    if (expr == null || expr.isEmpty) return const [];
    pinyinLooseQueries++;
    return _executeMatch(expr,
        limit: limit, offset: offset, candidateCap: candidateCap);
  }

  /// 日文读音兜底趟（v5）：只跑 [compileReading] 单支（不重复主表达式），
  /// 返回命中（无可读音词元 / 无命中返回空列表）。
  List<LocalSearchHit> _runReading(
    AnalyzerTokens tokens, {
    required LocalSearchScope scope,
    required int limit,
    required int offset,
    int candidateCap = defaultCandidateCap,
  }) {
    final expr = compileReading(tokens, scope: scope);
    if (expr == null || expr.isEmpty) return const [];
    readingQueries++;
    return _executeMatch(expr,
        limit: limit, offset: offset, candidateCap: candidateCap);
  }

  /// 跨语言兜底趟（T1）：只跑 [compileCrossLingual] 单支（不重复主表达式），
  /// 返回命中（无候选 / 无命中返回空列表）。
  List<LocalSearchHit> _runCrossLingual(
    AnalyzerTokens tokens, {
    required LocalSearchScope scope,
    required int limit,
    required int offset,
    int candidateCap = defaultCandidateCap,
  }) {
    final expr = compileCrossLingual(tokens, scope: scope);
    if (expr == null || expr.isEmpty) return const [];
    crossLingualQueries++;
    return _executeMatch(expr,
        limit: limit, offset: offset, candidateCap: candidateCap);
  }

  List<LocalSearchHit> _runMatch(
    AnalyzerTokens tokens, {
    required LocalSearchScope scope,
    required int limit,
    required int offset,
    bool useFuzzy = false,
    int candidateCap = defaultCandidateCap,
  }) {
    final expr = useFuzzy
        ? compileFuzzy(tokens, scope: scope)
        : compileMatch(tokens, scope: scope);
    if (expr == null) return const [];
    return _executeMatch(expr,
        limit: limit, offset: offset, candidateCap: candidateCap);
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
    int candidateCap = defaultCandidateCap,
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
    return _executeMatch(expr,
        limit: limit, offset: offset, candidateCap: candidateCap);
  }

  /// 执行一条已编译好的 `MATCH` 表达式，返回 BM25 升序命中列表。
  List<LocalSearchHit> _executeMatch(
    String expr, {
    required int limit,
    required int offset,
    int candidateCap = defaultCandidateCap,
  }) {
    final lim = limit <= 0 ? -1 : limit;
    final off = offset < 0 ? 0 : offset;
    // candidateCap > 0：先按 rowid 顺序取有界候选（无排序子查询，可提前退出），再排序这批候选。
    // candidateCap == 0：原路径（给全部命中打分），供对照 / 测试。
    final rows = candidateCap > 0
        ? _db.select(
            'SELECT rowid AS doc_id, bm25(search_fts, $_bm25Weights) AS score '
            'FROM search_fts '
            'WHERE rowid IN (SELECT rowid FROM search_fts WHERE search_fts MATCH ? LIMIT ?) '
            'ORDER BY score LIMIT ? OFFSET ?',
            [expr, candidateCap, lim, off],
          )
        : _db.select(
            'SELECT rowid AS doc_id, bm25(search_fts, $_bm25Weights) AS score '
            'FROM search_fts WHERE search_fts MATCH ? ORDER BY score LIMIT ? OFFSET ?',
            [expr, lim, off],
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

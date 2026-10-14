// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地曲库搜索索引（indexer）Dart 侧共享数据模型。
///
/// 纯数据（无 FFI / 无 IO）：供查询表达式编译（`search_query.dart`）、原生
/// 绑定（`indexer_ffi.dart`）与服务编排（`search_service.dart`）复用。
/// 字段语义对齐 `app/core/indexer` 的 C ABI / JSON（设计文档
/// `docs/local-search-index-plan.md` §9.2 / §9.3）。
library;

/// 查询侧分析词元：与索引侧同构的分析结果（`indexer_analyze`）。
///
/// 由原生分析器（C# `Analyzer.AnalyzeQuery`）产出：CJK 段输出 bigram + unigram
/// 词元与逐字主读音拼音，拉丁 / 数字段整词进入三列；查询侧另对纯拉丁词做
/// **连写全拼切分**（P4：`woaini` → 拼音 `wo ai ni`，词法仍为整词）。FFI JSON 的
/// `tokens` / `pinyin`（空格分隔串）在此解析为列表，`initials` 保留原串
/// （空串归一为 null）；`defs`（T1 跨语言候选，空格分隔）解析为 [crossLingual]。
class AnalyzerTokens {
  const AnalyzerTokens({
    this.lexical = const [],
    this.pinyin = const [],
    this.initials,
    this.crossLingual = const [],
  });

  /// 词法词元（CJK bigram/unigram + 拉丁/数字整词）。
  final List<String> lexical;

  /// 全拼音节（拉丁/数字段为其整词）。
  final List<String> pinyin;

  /// 首字母串（无有效内容时为 null）。
  final String? initials;

  /// 跨语言候选（T1，仅查询侧；`indexer_analyze` 的 `defs`）：拉丁/数字词 → 候选汉字，
  /// CJK 字 → 英文释义词。默认空（向后兼容旧库 / 手建 tokens）。
  final List<String> crossLingual;

  /// 无可匹配内容（三列皆空）。
  bool get isEmpty =>
      lexical.isEmpty &&
      pinyin.isEmpty &&
      (initials == null || initials!.trim().isEmpty);
}

/// 本地搜索范围（对齐 FTS5 列过滤，设计文档 §4.5）。
enum LocalSearchScope {
  /// 全部列（标题 / 歌手 / 专辑 / 歌词 / 译文 / 音译 / 拼音 / 文件名）。
  all,

  /// 仅元数据列（标题 / 歌手 / 专辑 / 文件名 / 拼音；不触歌词段）。
  metadata,
}

/// 单条本地搜索命中（`track_id` = `tracks.id`，与 UI 曲目 id 一致）。
class LocalSearchHit {
  const LocalSearchHit({required this.trackId, required this.score});

  /// 曲目 id（`search_docs.track_id` / `tracks.id`）。
  final String trackId;

  /// BM25 相关度（FTS5 `bm25()` 原始值；越负越相关，升序即最佳在前）。
  final double score;

  @override
  String toString() => 'LocalSearchHit($trackId, $score)';
}

/// 索引器运行结果摘要（对齐 C# `IndexerResult` JSON：type=done）。
class IndexerRunResult {
  const IndexerRunResult({
    required this.total,
    required this.indexed,
    required this.deleted,
    required this.skipped,
    required this.full,
    required this.generation,
    required this.durationMs,
  });

  final int total;
  final int indexed;
  final int deleted;
  final int skipped;
  final bool full;
  final int generation;
  final int durationMs;

  factory IndexerRunResult.fromJson(Map<String, dynamic> json) =>
      IndexerRunResult(
        total: (json['total'] as num?)?.toInt() ?? 0,
        indexed: (json['indexed'] as num?)?.toInt() ?? 0,
        deleted: (json['deleted'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        full: json['full'] as bool? ?? false,
        generation: (json['generation'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() =>
      'IndexerRunResult(total=$total, indexed=$indexed, deleted=$deleted, '
      'skipped=$skipped, full=$full, generation=$generation, '
      'durationMs=$durationMs)';
}

/// 索引进度帧（对齐 C# `IndexerProgress` JSON：type=progress）。
class IndexerProgress {
  const IndexerProgress({
    required this.phase,
    required this.total,
    required this.processed,
    required this.indexed,
    required this.deleted,
    required this.current,
  });

  /// 阶段：collect | index | delete | commit | done。
  final String phase;
  final int total;
  final int processed;
  final int indexed;
  final int deleted;
  final String current;

  factory IndexerProgress.fromJson(Map<String, dynamic> json) =>
      IndexerProgress(
        phase: json['phase'] as String? ?? '',
        total: (json['total'] as num?)?.toInt() ?? 0,
        processed: (json['processed'] as num?)?.toInt() ?? 0,
        indexed: (json['indexed'] as num?)?.toInt() ?? 0,
        deleted: (json['deleted'] as num?)?.toInt() ?? 0,
        current: json['current'] as String? ?? '',
      );

  /// 进度比例（0~1；total 未知时为 0）。
  double get fraction =>
      total <= 0 ? 0.0 : (processed / total).clamp(0.0, 1.0).toDouble();

  @override
  String toString() =>
      'IndexerProgress($phase $processed/$total, indexed=$indexed, '
      'deleted=$deleted)';
}

/// 本地搜索索引状态机取值。
enum LocalSearchState { disabled, ready, building, error }

/// 本地搜索索引状态（总开关门控 + 构建态；`message` 携带失败原因）。
class LocalSearchStatus {
  const LocalSearchStatus(this.state, {this.message = ''});

  final LocalSearchState state;

  /// 诊断消息（error 态为失败原因；其余通常为空）。
  final String message;

  static const LocalSearchStatus disabled =
      LocalSearchStatus(LocalSearchState.disabled);
  static const LocalSearchStatus ready =
      LocalSearchStatus(LocalSearchState.ready);
  static const LocalSearchStatus building =
      LocalSearchStatus(LocalSearchState.building);

  factory LocalSearchStatus.error(String message) =>
      LocalSearchStatus(LocalSearchState.error, message: message);

  bool get isDisabled => state == LocalSearchState.disabled;
  bool get isReady => state == LocalSearchState.ready;
  bool get isBuilding => state == LocalSearchState.building;
  bool get isError => state == LocalSearchState.error;

  @override
  bool operator ==(Object other) =>
      other is LocalSearchStatus &&
      other.state == state &&
      other.message == message;

  @override
  int get hashCode => Object.hash(state, message);

  @override
  String toString() =>
      'LocalSearchStatus(${state.name}${message.isEmpty ? '' : ': $message'})';
}

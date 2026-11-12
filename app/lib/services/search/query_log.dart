// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地搜索**查询日志**的纯策略层（无 FFI / 无 IO / 无 Flutter 依赖，可单测）。
///
/// 目的：为设计文档 `docs/cross-lingual-search-upgrade-plan.md` 的 **T2-7 助词容错矩阵**
/// 提供数据前提——该项要求「T1-2 上线后用**真实查询日志**确认 は/へ/を 双写是否足够」，
/// 而此前代码里**没有任何查询日志**，闭环缺失。
///
/// 采集范围与隐私边界（对齐 `docs/privacy.md` §二「本地运行日志」与 §一「最小必要」）：
/// - 只记录**查询串本身**与命中数、兜底趟计数；不记录曲目 / 路径 / 账号 / 设备信息；
/// - 只落**本机**文件，随「日志落盘」开关一起关闭时不写；
/// - 用户可在设置页一键清除。
///
/// 本层只负责「该不该记、记成什么形状」；落盘由 [QueryLogSink] 侧的 IO 实现完成，
/// 便于测试注入替身而不触碰真实文件系统。
library;

/// 单条查询记录的字段（写入 JSONL，一行一条）。
///
/// 字段刻意保持精简：`q`（查询串）、`n`（命中数）、`p`（触发的兜底趟，见 [passesOf]）、
/// `ms`（耗时）、`sc`（scope：`a`=all / `m`=metadata）。查询串按**原样**保存——
/// 助词容错矩阵分析需要的正是用户真实键入的罗马字形态（如 `kimi wa` / `kimi ha`）。
class QueryLogEntry {
  const QueryLogEntry({
    required this.query,
    required this.hitCount,
    this.passes = const <String>[],
    this.elapsedMs,
    this.metadataOnly = false,
  });

  final String query;
  final int hitCount;

  /// 本次查询**实际执行过**的兜底趟标识（如 `pinyinLoose` / `reading` / `crossLingual`）。
  final List<String> passes;

  final int? elapsedMs;
  final bool metadataOnly;

  Map<String, Object?> toJson() => {
    'q': query,
    'n': hitCount,
    if (passes.isNotEmpty) 'p': passes,
    if (elapsedMs != null) 'ms': elapsedMs,
    if (metadataOnly) 'sc': 'm',
  };

  @override
  String toString() => toJson().toString();
}

/// 一次查询的原始计数（来自 `indexer_query` 的 `passes` 对象）。
///
/// 计数器是**累加值**（`SearchIndex` 里 `+=`），所以调用方必须先取**差值**
/// 再交给 [passesOf]，否则同一条查询会带上此前所有查询的趟次。
class PassCounts {
  const PassCounts({
    this.pinyinLoose = 0,
    this.reading = 0,
    this.crossLingual = 0,
    this.fuzzy = 0,
    this.cjkFuzzy = 0,
  });

  final int pinyinLoose;
  final int reading;
  final int crossLingual;
  final int fuzzy;
  final int cjkFuzzy;

  /// 逐字段相减（`this - earlier`），用于把累加计数器还原成单次查询的趟次。
  PassCounts operator -(PassCounts earlier) => PassCounts(
    pinyinLoose: pinyinLoose - earlier.pinyinLoose,
    reading: reading - earlier.reading,
    crossLingual: crossLingual - earlier.crossLingual,
    fuzzy: fuzzy - earlier.fuzzy,
    cjkFuzzy: cjkFuzzy - earlier.cjkFuzzy,
  );

  /// 本次实际执行的兜底趟名（顺序与查询层的渐进趟一致，便于对照文档）。
  ///
  /// 只保留**非零**项：值为 0 表示该趟未执行（命中已足够而短路）。
  List<String> get labels => [
    if (pinyinLoose > 0) 'pinyinLoose',
    if (reading > 0) 'reading',
    if (crossLingual > 0) 'crossLingual',
    if (fuzzy > 0) 'fuzzy',
    if (cjkFuzzy > 0) 'cjkFuzzy',
  ];
}

/// 把（已求差值的）计数器转成趟名列表；全为 0（主趟即命中）返回空列表。
List<String> passesOf(PassCounts counts) => counts.labels;

/// 查询串是否值得记录。
///
/// 过滤掉不可能提供助词容错信息、却会污染日志的输入：
/// - 空白 / 空串；
/// - **单个拉丁字符**（`a` / `k` 这种边打边搜的逐键中间态）；
/// - 纯**数字 / 标点**（无语言信息）。
///
/// 注意：
/// - **单个汉字 / 假名 / 谚文照记**——`愛` 是有意义的中文单字查询，不是输入中间态；
/// - 长度 ≥2 的纯拉丁串照记——`wa` / `ha` / `wo` 正是助词矩阵要看的目标形态。
bool shouldLogQuery(String query) {
  final q = query.trim();
  if (q.isEmpty) return false;
  final runes = q.runes.toList();
  if (runes.length == 1 && _isLatinLetter(runes.single)) return false;
  return runes.any(_isLanguageRune);
}

bool _isLatinLetter(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

/// 拉丁字母 / 汉字 / 假名 / 谚文——即「含语言信息」的码点。
bool _isLanguageRune(int rune) =>
    _isLatinLetter(rune) ||
    (rune >= 0x3040 && rune <= 0x30FF) || // 假名
    (rune >= 0x3400 && rune <= 0x4DBF) || // 汉字扩展 A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // 汉字主区
    (rune >= 0xAC00 && rune <= 0xD7AF) || // 谚文音节
    (rune >= 0xF900 && rune <= 0xFAFF); // 兼容表意

/// 查询日志的**落盘接口**（生产用文件实现，测试注入内存实现）。
abstract class QueryLogSink {
  /// 追加一条记录。**必须**吞掉自身 IO 异常——查询日志是诊断增强，
  /// 绝不能因为它失败而影响搜索主路径。
  void append(QueryLogEntry entry);
}

/// 内存实现（测试 / 预览用）。
class MemoryQueryLogSink implements QueryLogSink {
  final List<QueryLogEntry> entries = <QueryLogEntry>[];

  @override
  void append(QueryLogEntry entry) => entries.add(entry);
}

/// 把一条查询归一成**可用于聚合的键**（小写 + 折叠连续空白）。
///
/// 助词矩阵关心的是「同一形态被搜了多少次」，大小写与多余空格不构成区分，
/// 故聚合前归一；原始串仍由 [QueryLogEntry.query] 保留。
String normalizeQueryKey(String query) =>
    query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

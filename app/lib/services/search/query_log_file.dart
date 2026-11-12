// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 查询日志的**文件实现**（JSONL，单文件有上限，超出原地轮转）。
///
/// 与 `query_log.dart` 的纯策略层分离：本文件承担 IO，策略（该不该记、记成什么）
/// 全在纯函数里，便于单测而不触碰真实文件系统。
///
/// 设计取舍：
/// - **同步追加**：查询本身已是原生 FFI 同步调用，追加一行 JSON 的耗时远小于一次
///   FTS 查询；异步排队会引入生命周期与顺序问题（且查询日志必须反映真实顺序）。
/// - **单文件上限 512 KiB**：查询日志只用于诊断（T2-7 助词矩阵），不是审计日志；
///   超出后**原地轮转到 `.1`**（保留上一代），避免无界增长。
/// - **失败静默**：任何 IO 异常都吞掉——查询日志绝不阻断搜索。
library;

import 'dart:convert';
import 'dart:io';

import '../../stores/app_prefs.dart';
import 'query_log.dart';

/// 查询日志文件（`<数据目录>/logs/search_queries.jsonl`）。
class FileQueryLogSink implements QueryLogSink {
  FileQueryLogSink({required this.path, this.maxBytes = defaultMaxBytes});

  /// 默认单文件上限（512 KiB，约数千条记录）。
  static const int defaultMaxBytes = 512 * 1024;

  final String path;
  final int maxBytes;

  int _writesSinceCheck = 0;

  @override
  void append(QueryLogEntry entry) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      // 体积检查：`lengthSync()` 是一次 stat，相对一次 FTS 查询可忽略；
      // 但为热路径留余地，仍按批检查（每 16 条）。上限很小时（测试）逐条检查。
      final everyWrite = maxBytes < 4096;
      if (everyWrite || _writesSinceCheck++ % 16 == 0) {
        if (file.existsSync() && file.lengthSync() > maxBytes) _rotate(file);
      }
      file.writeAsStringSync(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 诊断增强功能：绝不影响搜索主路径。
    }
  }

  void _rotate(File file) {
    try {
      final backup = File('$path.1');
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    } catch (_) {
      // 轮转失败就继续追加（宁可文件偏大，也不丢新记录）。
    }
  }

  /// 删除当前与上一代日志文件（设置页「清除查询日志」）。
  void clear() {
    for (final f in [File(path), File('$path.1')]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 读取全部记录（诊断 / 测试用；跨两代合并，旧代在前）。
  ///
  /// **逐行**容错：某一行损坏只跳过该行，不影响同文件后续记录
  /// （整个循环包在 try 里会让一行坏数据吃掉后面全部有效行）。
  List<QueryLogEntry> readAll() {
    final out = <QueryLogEntry>[];
    for (final p in ['$path.1', path]) {
      final f = File(p);
      if (!f.existsSync()) continue;
      List<String> lines;
      try {
        lines = f.readAsLinesSync();
      } catch (_) {
        continue; // 整个文件读不出来（权限 / 编码）才放弃这一代
      }
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final parsed = jsonDecode(trimmed);
          if (parsed is! Map<String, dynamic>) continue;
          final q = parsed['q'];
          if (q is! String) continue;
          out.add(
            QueryLogEntry(
              query: q,
              hitCount: parsed['n'] is num ? (parsed['n'] as num).toInt() : 0,
              passes:
                  (parsed['p'] is List)
                  ? (parsed['p'] as List).whereType<String>().toList()
                  : const <String>[],
              elapsedMs: parsed['ms'] is num ? (parsed['ms'] as num).toInt() : null,
              metadataOnly: parsed['sc'] == 'm',
            ),
          );
        } catch (_) {
          // 该行损坏：跳过，继续解析后续行。
        }
      }
    }
    return out;
  }
}

/// 查询日志总闸：**只有日志落盘开着时才记录**（对齐 `docs/privacy.md`「本地运行日志」）。
///
/// 与 `Log.setFileEnabled` 同一偏好（`app.logToFile`）——用户关掉日志落盘，
/// 查询日志一并停写，无需再单独给一个开关（避免设置项膨胀）。
class QueryLogger {
  QueryLogger._();

  static QueryLogSink? _sink;

  /// 日志文件路径：**与开关无关**地记住，`clear()` 才可能在开关关闭时照样生效。
  ///
  /// 关闭日志落盘只表示「不再写入」，不等于「已记录的内容已删除」；用户关掉日志后
  /// 往往更想清掉既有记录（隐私预期），故清除动作不得依赖 [_sink]。
  static String? _logPath;

  static String _pathFor(String dataDir) =>
      '$dataDir/logs/search_queries.jsonl';

  /// 装配 sink（`main` 启动时按偏好调用；[prefs] 关闭落盘则不装配）。
  static void configure({required String dataDir, required AppPrefs prefs}) {
    _logPath = _pathFor(dataDir);
    if (!prefs.logToFile) {
      _sink = null;
      return;
    }
    _sink = _sink ?? FileQueryLogSink(path: _logPath!);
  }

  /// 运行期开关（与「日志落盘」开关联动；关闭即停止记录）。
  static void setEnabled(bool enabled, {required String dataDir}) {
    _logPath = _pathFor(dataDir);
    if (!enabled) {
      _sink = null;
      return;
    }
    _sink ??= FileQueryLogSink(path: _logPath!);
  }

  static bool get enabled => _sink != null;

  /// 记录一次查询（未装配 sink 时是 no-op，零成本）。
  static void record(QueryLogEntry entry) => _sink?.append(entry);

  /// 清除日志（设置页动作）。
  ///
  /// **不依赖 [_sink]**：开关关闭时也要能删掉此前落盘的记录（否则「可随时清除」不成立）。
  static void clear() {
    final sink = _sink;
    if (sink is FileQueryLogSink) {
      sink.clear();
      return;
    }
    final path = _logPath;
    if (path != null) FileQueryLogSink(path: path).clear();
  }

  /// 测试接缝：注入替身 / 复位。
  static void debugSetSink(QueryLogSink? sink) => _sink = sink;
}

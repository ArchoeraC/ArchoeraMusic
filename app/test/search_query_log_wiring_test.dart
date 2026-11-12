// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/query_log.dart';
import 'package:archoera_music/services/search/query_log_file.dart';

/// 查询日志**接线**测试：确认 `QueryLogger` 总闸与 sink 生命周期正确。
///
/// 不测 `SearchService.search` 的真实记录路径（那需要加载 indexer 原生库，
/// 由 `search_index_ffi_smoke_test.dart` 覆盖）；这里只守住「关掉日志就绝不写」
/// 这条隐私边界（`docs/privacy.md` §二）。
void main() {
  tearDown(() => QueryLogger.debugSetSink(null));

  test('未装配 sink 时 record 是 no-op（不崩溃、不写盘）', () {
    QueryLogger.debugSetSink(null);
    expect(QueryLogger.enabled, isFalse);
    expect(
      () => QueryLogger.record(const QueryLogEntry(query: 'wo', hitCount: 1)),
      returnsNormally,
    );
  });

  test('装配后 enabled 为真且记录进入 sink', () {
    final sink = MemoryQueryLogSink();
    QueryLogger.debugSetSink(sink);
    expect(QueryLogger.enabled, isTrue);
    QueryLogger.record(const QueryLogEntry(query: 'kimi wa', hitCount: 2));
    expect(sink.entries.single.query, 'kimi wa');
  });

  test('关闭日志（setEnabled false）后不再记录', () {
    final sink = MemoryQueryLogSink();
    QueryLogger.debugSetSink(sink);
    QueryLogger.record(const QueryLogEntry(query: 'wo', hitCount: 1));
    QueryLogger.setEnabled(false, dataDir: '/tmp/archoera-nonexistent');
    expect(QueryLogger.enabled, isFalse);
    QueryLogger.record(const QueryLogEntry(query: 'wo', hitCount: 1));
    expect(sink.entries.length, 1, reason: '关闭后不应再有新记录');
  });
}

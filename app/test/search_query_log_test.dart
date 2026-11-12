// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/search/query_log.dart';
import 'package:archoera_music/services/search/query_log_file.dart';

/// 查询日志（T2-7 助词容错矩阵的数据前提）纯策略层测试。
///
/// 只测**纯函数与内存 sink**：文件 IO 由 `FileQueryLogSink` 覆盖（见下一组），
/// 这里不碰真实数据目录。
void main() {
  group('shouldLogQuery（过滤噪声，但保留助词分析要看的形态）', () {
    test('空 / 纯空白 / 单拉丁字符不记', () {
      expect(shouldLogQuery(''), isFalse);
      expect(shouldLogQuery('   '), isFalse);
      expect(shouldLogQuery('a'), isFalse, reason: '边打边搜的逐键中间态');
      expect(shouldLogQuery('  w '), isFalse, reason: 'trim 后仍是单拉丁字符');
    });

    test('单个汉字 / 假名照记（不是输入中间态）', () {
      expect(shouldLogQuery(' 我 '), isTrue);
      expect(shouldLogQuery('愛'), isTrue);
      expect(shouldLogQuery('あ'), isTrue);
    });

    test('纯数字 / 标点不记（无语言信息）', () {
      expect(shouldLogQuery('123'), isFalse);
      expect(shouldLogQuery('!!'), isFalse);
      expect(shouldLogQuery('12 34'), isFalse);
    });

    test('助词形态的双假名 / 长词照记', () {
      expect(shouldLogQuery('kimi wa'), isTrue);
      expect(shouldLogQuery('kimi ha'), isTrue);
      expect(shouldLogQuery('wo'), isTrue);
      expect(shouldLogQuery('ha'), isTrue);
      expect(shouldLogQuery('愛'), isTrue);
      expect(shouldLogQuery('米津'), isTrue);
      expect(shouldLogQuery('사랑'), isTrue, reason: '谚文也算语言信息');
    });

    test('中英混排照记', () {
      expect(shouldLogQuery('月亮 love'), isTrue);
    });
  });

  group('PassCounts 差值（累加计数器 → 单次查询趟次）', () {
    test('相减得到本次增量', () {
      const before = PassCounts(pinyinLoose: 3, reading: 1, fuzzy: 2);
      const after = PassCounts(pinyinLoose: 4, reading: 1, fuzzy: 2);
      final delta = after - before;
      expect(delta.pinyinLoose, 1);
      expect(delta.reading, 0);
      expect(delta.fuzzy, 0);
    });

    test('无变化 → 空趟列表（主趟即命中）', () {
      const counts = PassCounts();
      expect(passesOf(counts), isEmpty);
    });

    test('趟名按查询层的渐进顺序输出', () {
      const counts = PassCounts(
        pinyinLoose: 1,
        reading: 1,
        crossLingual: 0,
        fuzzy: 1,
        cjkFuzzy: 0,
      );
      expect(passesOf(counts), const ['pinyinLoose', 'reading', 'fuzzy']);
    });
  });

  group('normalizeQueryKey（聚合键归一）', () {
    test('小写 + 折叠空白', () {
      expect(normalizeQueryKey('  Kimi   WA  '), 'kimi wa');
    });

    test('CJK 不受影响', () {
      expect(normalizeQueryKey('米津 玄師'), '米津 玄師');
    });
  });

  group('MemoryQueryLogSink', () {
    test('append 保序累积', () {
      final sink = MemoryQueryLogSink();
      sink.append(const QueryLogEntry(query: 'kimi wa', hitCount: 2));
      sink.append(const QueryLogEntry(query: 'kimi ha', hitCount: 2));
      expect(sink.entries.map((e) => e.query), const ['kimi wa', 'kimi ha']);
    });
  });

  group('QueryLogEntry 序列化', () {
    test('省略空可选字段（日志保持精简）', () {
      const entry = QueryLogEntry(query: 'wo', hitCount: 5);
      expect(entry.toJson(), {'q': 'wo', 'n': 5});
    });

    test('带趟次 / 耗时 / scope', () {
      const entry = QueryLogEntry(
        query: 'kimi wa',
        hitCount: 1,
        passes: ['reading'],
        elapsedMs: 7,
        metadataOnly: true,
      );
      expect(entry.toJson(), {
        'q': 'kimi wa',
        'n': 1,
        'p': ['reading'],
        'ms': 7,
        'sc': 'm',
      });
    });

    test('JSONL 一行可解析回同样字段', () {
      const entry = QueryLogEntry(
        query: '愛',
        hitCount: 3,
        passes: ['crossLingual'],
      );
      final line = jsonEncode(entry.toJson());
      expect(line.contains('\n'), isFalse, reason: 'JSONL 必须单行');
      final back = jsonDecode(line) as Map<String, dynamic>;
      expect(back['q'], '愛');
      expect(back['n'], 3);
      expect((back['p'] as List).cast<String>(), ['crossLingual']);
    });
  });

  group('FileQueryLogSink（真实文件，临时目录）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('query_log_test'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('写入后可按行读回', () {
      final path = '${tmp.path}/logs/search_queries.jsonl';
      final sink = FileQueryLogSink(path: path);
      sink.append(const QueryLogEntry(query: 'kimi wa', hitCount: 1));
      sink.append(const QueryLogEntry(query: 'wo', hitCount: 9));

      final all = sink.readAll();
      expect(all.length, 2);
      expect(all[0].query, 'kimi wa');
      expect(all[1].hitCount, 9);
      expect(File(path).existsSync(), isTrue);
      expect(File(path).parent.path.endsWith('/logs'), isTrue, reason: '目录自动创建');
    });

    test('超过上限后轮转到 .1，且新记录不丢', () {
      final path = '${tmp.path}/search_queries.jsonl';
      final sink = FileQueryLogSink(path: path, maxBytes: 10);
      // 每次写都会触发体积检查（maxBytes 极小），轮转后继续追加。
      for (var i = 0; i < 5; i++) {
        sink.append(QueryLogEntry(query: 'query$i', hitCount: i));
      }
      expect(File('$path.1').existsSync(), isTrue, reason: '发生过轮转');
      final all = sink.readAll();
      expect(all.isNotEmpty, isTrue);
      expect(all.last.query, 'query4', reason: '最新记录必须保留');
    });

    test('clear 删除当前与上一代', () {
      final path = '${tmp.path}/q.jsonl';
      final sink = FileQueryLogSink(path: path, maxBytes: 10);
      for (var i = 0; i < 5; i++) {
        sink.append(QueryLogEntry(query: 'query$i', hitCount: i));
      }
      expect(File(path).existsSync() || File('$path.1').existsSync(), isTrue);
      sink.clear();
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.1').existsSync(), isFalse);
    });

    test('损坏行被跳过，不影响后续解析', () {
      final path = '${tmp.path}/q.jsonl';
      File(path).writeAsStringSync('not json\n{"q":"ok","n":1}\n');
      final all = FileQueryLogSink(path: path).readAll();
      expect(all.length, 1);
      expect(all.single.query, 'ok');
    });

    test('IO 失败静默（不向搜索主路径抛异常）', () {
      // 用一个非法路径（父级是文件）触发 IO 异常。
      final blocker = File('${tmp.path}/blocked');
      blocker.writeAsStringSync('x');
      final sink = FileQueryLogSink(path: '${blocker.path}/sub/q.jsonl');
      expect(() => sink.append(const QueryLogEntry(query: 'wo', hitCount: 1)),
          returnsNormally);
    });
  });

  group('QueryLogger.clear（关闭落盘后仍可清除既有记录）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('query_log_gate'));
    tearDown(() {
      QueryLogger.setEnabled(false, dataDir: tmp.path);
      QueryLogger.debugSetSink(null);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('sink 为 null（日志关闭）时 clear 仍删除文件', () {
      final path = '${tmp.path}/logs/search_queries.jsonl';
      FileQueryLogSink(path: path)
          .append(const QueryLogEntry(query: 'woaini', hitCount: 3));
      expect(File(path).existsSync(), isTrue);

      // 关闭落盘：只停止写入，不应顺手删掉既有记录（否则用户无从取证 / 也无法预期）。
      QueryLogger.setEnabled(false, dataDir: tmp.path);
      expect(QueryLogger.enabled, isFalse);
      expect(File(path).existsSync(), isTrue, reason: '关开关不应静默删除记录');

      // 「可随时清除」必须在关闭态成立——这正是 privacy.md 的承诺。
      QueryLogger.clear();
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.1').existsSync(), isFalse);
    });

    test('未配置路径时 clear 不抛异常', () {
      QueryLogger.debugSetSink(null);
      expect(() => QueryLogger.clear(), returnsNormally);
    });
  });
}

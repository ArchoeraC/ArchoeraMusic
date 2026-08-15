import 'dart:io';

import 'package:archoera_music/services/history/history_store.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/scanner/sqlite_preload.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放历史数据层测试：UI 线程同步直写 + 上限裁剪 / 不限制 / 去重置顶。
///
/// 前置：与生产一致，任何 sqlite3.open 之前先预加载与 scanner 共享的
/// libe_sqlite3（hooks 配置 dart sqlite3 从进程符号表解析该系统库，同实例）。
void main() {
  preloadBundledSqlite();

  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('history_store_test');
    HistoryStore.overrideDbPath = '${tmpDir.path}/history.db';
  });

  tearDown(() {
    HistoryStore.overrideDbPath = null;
    tmpDir.deleteSync(recursive: true);
  });

  Track track(String id, String title, {String source = 'local'}) =>
      Track(id: id, title: title, source: source);

  test('记录与去重置顶', () async {
    final store = HistoryStore.shared;
    store.record(track('a', 'A'));
    // 同步直写极快，多次记录可能落在同一毫秒（played_at 相同由 rowid
    // 决胜，UPDATE 去重不改 rowid 会排后）；加微小间隔模拟真实播放间距
    await Future<void>.delayed(const Duration(milliseconds: 5));
    store.record(track('b', 'B'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // 重复播放 a：应去重置顶（时间刷新）
    store.record(track('a', 'A'));

    final entries = store.entries();
    expect(entries.length, 2);
    expect(entries.first.track.id, 'a'); // 最近播放的在前
    expect(entries.last.track.id, 'b');
    expect(store.count(), 2);
  });

  test('上限裁剪：超限只保留最新', () {
    final store = HistoryStore.shared;
    for (var i = 1; i <= 5; i++) {
      store.record(track('t$i', 'T$i'), limit: 3);
    }
    final entries = store.entries();
    expect(entries.length, 3);
    expect(entries.map((e) => e.track.id).toList(), ['t5', 't4', 't3']);
  });

  test('不限制：limit=null 不裁剪', () {
    final store = HistoryStore.shared;
    for (var i = 1; i <= 10; i++) {
      store.record(track('t$i', 'T$i'), limit: null);
    }
    expect(store.entries().length, 10);
  });

  test('trim 按新上限立即裁剪', () {
    final store = HistoryStore.shared;
    for (var i = 1; i <= 5; i++) {
      store.record(track('t$i', 'T$i'));
    }
    store.trim(2);
    final entries = store.entries();
    expect(entries.length, 2);
    expect(entries.map((e) => e.track.id).toList(), ['t5', 't4']);
  });

  test('remove 与 clear', () {
    final store = HistoryStore.shared;
    store.record(track('a', 'A'));
    store.record(track('b', 'B'));
    store.remove(track('a', 'A'));
    expect(store.entries().single.track.id, 'b');
    store.clear();
    expect(store.count(), 0);
  });
}

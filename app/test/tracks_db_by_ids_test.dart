// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:archoera_music/services/scanner/sqlite_preload.dart';
import 'package:archoera_music/services/scanner/tracks_db.dart';

/// [TracksDb.listTracksByIds] / [TracksDb.existingTrackIds] 单测：
/// 索引排行分页按排名切片取行，必须**保持输入顺序**且跳过缺失 id。
///
/// 前置：与生产一致，任何 `sqlite3.open` 之前先预加载与 scanner 共享的
/// `libe_sqlite3`（hooks 配置从进程符号表解析，同实例）。
void main() {
  preloadBundledSqlite();

  late Directory tmpDir;
  late String dbPath;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('tracks_db_by_ids');
    dbPath = '${tmpDir.path}/library.db';
    final db = sqlite3.open(dbPath);
    db.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT NOT NULL,
        track INTEGER, artists TEXT, album TEXT, duration INTEGER,
        cover TEXT, codec TEXT, sample_rate INTEGER, bit_rate INTEGER,
        channels INTEGER, bits_per_sample INTEGER, file_size INTEGER,
        file_mtime INTEGER, loudness_lufs REAL, loudness_peak REAL
      )
    ''');
    void insert(String id, String title) {
      db.execute(
        'INSERT INTO tracks (id, path, title, artists, album, duration, '
        'file_size, file_mtime) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [id, '/m/$id.wav', title, '[]', null, 1000, 0, 0],
      );
    }

    insert('a', 'Alpha');
    insert('b', 'Beta');
    insert('c', 'Gamma');
    db.close();
  });

  tearDown(() => tmpDir.deleteSync(recursive: true));

  test('listTracksByIds 保持输入顺序并跳过缺失 id', () {
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    final rows = db.listTracksByIds(['c', 'missing', 'a', 'b']);
    expect(rows.map((r) => r.id).toList(), ['c', 'a', 'b']);
    expect(rows.map((r) => r.title).toList(), ['Gamma', 'Alpha', 'Beta']);
  });

  test('listTracksByIds 空输入返回空', () {
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    expect(db.listTracksByIds(const []), isEmpty);
  });

  test('existingTrackIds 保持顺序并剔除不存在 id', () {
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    expect(db.existingTrackIds(['b', 'zzz', 'a', 'c']), ['b', 'a', 'c']);
    expect(db.existingTrackIds(const []), isEmpty);
  });

  test('listTracksByIds 分批查询（> 400 仍保序）', () {
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    // 造 900 条，按倒序请求，验证跨批次仍严格保序。
    final all = <String>['a', 'b', 'c'];
    final writer = sqlite3.open(dbPath);
    for (var i = 0; i < 900; i++) {
      final id = 'x$i';
      writer.execute(
        'INSERT INTO tracks (id, path, title, file_size, file_mtime) '
        'VALUES (?, ?, ?, 0, 0)',
        [id, '/m/$id.wav', id],
      );
      all.add(id);
    }
    writer.close();
    final reversed = all.reversed.toList();
    expect(db.listTracksByIds(reversed).map((r) => r.id).toList(), reversed);
  });
}

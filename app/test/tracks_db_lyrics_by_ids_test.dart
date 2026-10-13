// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:archoera_music/services/scanner/sqlite_preload.dart';
import 'package:archoera_music/services/scanner/tracks_db.dart';

/// [TracksDb.lyricsByIds] 单测：批量懒查歌词，仅返回**非空**歌词的 id，跳过缺失 /
/// 无歌词 / 空串 id（供搜索结果歌词命中片段在页加载时一次取回整页歌词）。
void main() {
  preloadBundledSqlite();

  late Directory tmpDir;
  late String dbPath;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('tracks_db_lyrics_by_ids');
    dbPath = '${tmpDir.path}/library.db';
    final db = sqlite3.open(dbPath);
    db.execute(
      'CREATE TABLE tracks (id TEXT PRIMARY KEY, path TEXT NOT NULL, '
      'title TEXT NOT NULL, lyrics TEXT)',
    );
    void insert(String id, String? lyrics) {
      db.execute(
        'INSERT INTO tracks (id, path, title, lyrics) VALUES (?, ?, ?, ?)',
        [id, '/m/$id.mp3', id, lyrics],
      );
    }

    insert('a', '我爱你中国');
    insert('b', ''); // 空串：不算有效歌词
    insert('c', null); // 无歌词
    insert('d', '我们都有一个家');
    db.close();
  });

  tearDown(() => tmpDir.deleteSync(recursive: true));

  test('仅返回非空歌词的 id（跳过缺失 / 空串 / null）', () {
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    final out = db.lyricsByIds(['a', 'b', 'c', 'd', 'missing']);
    expect(out.keys.toSet(), {'a', 'd'});
    expect(out['a'], '我爱你中国');
    expect(out['d'], '我们都有一个家');
  });

  test('空输入返回空映射', () {
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    expect(db.lyricsByIds(const []), isEmpty);
  });
}

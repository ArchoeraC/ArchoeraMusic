// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:archoera_music/services/scanner/sqlite_preload.dart';
import 'package:archoera_music/services/scanner/tracks_db.dart';

/// `TracksDb` 歌词读取的**侧车回退**（v3）：内嵌 `tracks.lyrics` 为空时回退
/// scanner 写入的 `.lrc` 侧车原始文本 `tracks.lyrics_lrc`——播放侧因此也能拿到 `.lrc`
/// 歌词（此前 `.lrc` 只有索引器消费，导致「搜索得到、播放没词」）。
/// 旧库（无该列）必须照常可用（退回只读 `lyrics`）。
void main() {
  preloadBundledSqlite();

  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('tracks_db_lyrics'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 建一个最小 library.db（含 / 不含 `lyrics_lrc` 列）。
  String buildDb({required bool withLrcColumn}) {
    final path = '${tmp.path}/library.db';
    final db = sqlite3.open(path);
    db.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
        artists TEXT NOT NULL DEFAULT '[]', album TEXT, duration INTEGER NOT NULL,
        cover TEXT, codec TEXT, sample_rate INTEGER, bit_rate INTEGER, channels INTEGER,
        bits_per_sample INTEGER, file_size INTEGER NOT NULL, file_mtime INTEGER,
        loudness_lufs REAL, loudness_peak REAL, lyrics TEXT
        ${withLrcColumn ? ', lyrics_lrc TEXT' : ''}
      )
    ''');
    void insert(String id, String title, String? embedded, String? sidecar) {
      final cols = withLrcColumn
          ? 'id, path, title, duration, file_size, lyrics, lyrics_lrc'
          : 'id, path, title, duration, file_size, lyrics';
      final vals = withLrcColumn
          ? [id, '/m/$id.mp3', title, 1000, 10, embedded, sidecar]
          : [id, '/m/$id.mp3', title, 1000, 10, embedded];
      final marks = List.filled(vals.length, '?').join(', ');
      db.execute('INSERT INTO tracks ($cols) VALUES ($marks)', vals);
    }

    // t1 内嵌优先；t2 只有 .lrc 侧车（回退）；t3 都没有。
    insert('t1', '内嵌', '[00:01.00]内嵌歌词\n', '[00:01.00]侧车歌词\n');
    insert('t2', '侧车', null, '[00:01.00]侧车独有\n');
    insert('t3', '都没有', '   ', null);
    db.close();
    return path;
  }

  test('内嵌优先，空则回退 .lrc 侧车原始文本（保时间轴）', () {
    final db = TracksDb.open(buildDb(withLrcColumn: true));
    addTearDown(db.close);

    expect(db.lyricsById('t1'), '[00:01.00]内嵌歌词\n');
    expect(db.lyricsById('t2'), '[00:01.00]侧车独有\n', reason: '内嵌为空 → 回退 lyrics_lrc');
    expect(db.lyricsById('t3'), isNull, reason: '两者皆空 → null（空白也算空）');
    expect(db.lyricsById('missing'), isNull);
  });

  test('按路径同样回退；批量查询包含侧车独有曲目', () {
    final db = TracksDb.open(buildDb(withLrcColumn: true));
    addTearDown(db.close);

    expect(db.lyricsByPath('/m/t2.mp3'), '[00:01.00]侧车独有\n');

    final batch = db.lyricsByIds(['t1', 't2', 't3', 'missing']);
    expect(batch['t1'], '[00:01.00]内嵌歌词\n');
    expect(batch['t2'], '[00:01.00]侧车独有\n', reason: '歌词片段 / 播放取词都要看到侧车');
    expect(batch.containsKey('t3'), isFalse, reason: '空歌词不入结果');
  });

  test('旧库（无 lyrics_lrc 列）不报错：退回只读 lyrics', () {
    final db = TracksDb.open(buildDb(withLrcColumn: false));
    addTearDown(db.close);

    expect(db.lyricsById('t1'), '[00:01.00]内嵌歌词\n');
    expect(db.lyricsById('t2'), isNull, reason: '旧库没有侧车列 → 无歌词');
    expect(db.lyricsByIds(['t1']), {'t1': '[00:01.00]内嵌歌词\n'});
  });
}

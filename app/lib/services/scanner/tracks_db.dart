// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'library_scanner.dart';

/// 本地曲目行（对应 tracks 表 schema）。
class TrackRow {
  const TrackRow({
    required this.id,
    required this.path,
    required this.title,
    required this.track,
    required this.artistNames,
    required this.albumName,
    required this.albumYear,
    required this.durationMs,
    required this.cover,
    required this.codec,
    required this.sampleRate,
    required this.bitRate,
    required this.channels,
    required this.bitsPerSample,
    required this.fileSize,
    required this.fileMtime,
    required this.lyrics,
  });

  final String id;
  final String path;
  final String title;
  final int? track;
  final List<String> artistNames;
  final String? albumName;
  final int? albumYear;
  final int durationMs;
  final String? cover;
  final String? codec;
  final int? sampleRate;
  final int? bitRate;
  final int? channels;
  final int? bitsPerSample;
  final int fileSize;
  final int fileMtime;
  final String? lyrics;

  /// 从查询行构造。列表/查询路径**默认不读 `lyrics`**（内嵌歌词文本可能是
  /// 每曲数 KB 的大字符串），仅按需经 [TracksDb.lyricsById] / [TracksDb.lyricsByPath]
  /// 懒加载；需要时经 [lyrics] 显式传入。
  factory TrackRow.fromRow(Row row, {String? lyrics}) {
    final artistsJson = row['artists'] as String? ?? '[]';
    final albumJson = row['album'] as String?;
    List<String> artistNames;
    try {
      artistNames = (jsonDecode(artistsJson) as List<dynamic>)
          .map((e) => (e as Map<String, dynamic>)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      artistNames = const [];
    }
    String? albumName;
    int? albumYear;
    if (albumJson != null && albumJson.isNotEmpty) {
      try {
        final album = jsonDecode(albumJson) as Map<String, dynamic>;
        albumName = album['name'] as String?;
        albumYear = (album['year'] as num?)?.toInt();
      } catch (_) {}
    }
    return TrackRow(
      id: row['id'] as String,
      path: row['path'] as String,
      title: row['title'] as String,
      track: row['track'] as int?,
      artistNames: artistNames,
      albumName: albumName,
      albumYear: albumYear,
      durationMs: row['duration'] as int? ?? 0,
      cover: row['cover'] as String?,
      codec: row['codec'] as String?,
      sampleRate: row['sample_rate'] as int?,
      bitRate: row['bit_rate'] as int?,
      channels: row['channels'] as int?,
      bitsPerSample: row['bits_per_sample'] as int?,
      fileSize: row['file_size'] as int? ?? 0,
      fileMtime: row['file_mtime'] as int? ?? 0,
      lyrics: lyrics,
    );
  }
}

/// 本地曲库查询 + 管理层（sqlite3 FFI 直连，与 scanner 直写同一 library.db）。
///
/// 职责：读 tracks 表供 UI 展示；**写入分两路**——扫描建库/更新由
/// scanner（NativeAOT 直写）负责，曲目删除由本类直接执行（Dart 侧
/// 管理操作，C# 不承担删除）。
class TracksDb {
  TracksDb._(this._db);

  final Database _db;

  /// 打开曲库。默认 [LibraryScanner.defaultDbPath]。
  /// 文件不存在时抛出（需先运行扫描建库）。
  static TracksDb open([String? dbPath]) {
    final path = dbPath ?? LibraryScanner.defaultDbPath();
    final db = sqlite3.open(path);
    return TracksDb._(db);
  }

  /// 列表查询显式列（**不含 `lyrics`**）：避免把每曲数 KB 的内嵌歌词
  /// 随全量/分页结果一起读入内存。歌词按需经 [lyricsById] / [lyricsByPath] 懒查。
  static const String _trackColumns =
      'id, path, title, track, artists, album, duration, cover, codec, '
      'sample_rate, bit_rate, channels, bits_per_sample, file_size, file_mtime';

  /// 搜索条件（与 UI 的 title/artist/album 过滤语义一致）。
  static const String _searchWhere =
      'title LIKE ?1 OR artists LIKE ?1 OR album LIKE ?1';

  /// 曲目总数。
  int count() {
    final res = _db.select('SELECT COUNT(*) AS c FROM tracks');
    return res.first['c'] as int? ?? 0;
  }

  /// 匹配关键字（title/artist/album）的曲目数；无关键字时等于总数。
  int countTracks({String? query}) {
    final hasQuery = query != null && query.isNotEmpty;
    final sql = hasQuery
        ? 'SELECT COUNT(*) AS c FROM tracks WHERE $_searchWhere'
        : 'SELECT COUNT(*) AS c FROM tracks';
    final res = hasQuery
        ? _db.select(sql, ['%$query%'])
        : _db.select(sql);
    return res.first['c'] as int? ?? 0;
  }

  /// 分页查询曲目（按标题排序），支持可选关键字过滤。
  List<TrackRow> listTracks({
    int limit = 200,
    int offset = 0,
    String? query,
  }) {
    final hasQuery = query != null && query.isNotEmpty;
    final sql = hasQuery
        ? 'SELECT $_trackColumns FROM tracks WHERE $_searchWhere '
            'ORDER BY title LIMIT ?2 OFFSET ?3'
        : 'SELECT $_trackColumns FROM tracks ORDER BY title LIMIT ?1 OFFSET ?2';
    final params = hasQuery ? <Object?>['%$query%', limit, offset] : <Object?>[limit, offset];
    return _db.select(sql, params).map(TrackRow.fromRow).toList();
  }

  /// 全量曲目（**不含 lyrics**，供「播放全部」建队列一次性取全）。
  List<TrackRow> allTracks({String? query}) {
    final hasQuery = query != null && query.isNotEmpty;
    final sql = hasQuery
        ? 'SELECT $_trackColumns FROM tracks WHERE $_searchWhere ORDER BY title'
        : 'SELECT $_trackColumns FROM tracks ORDER BY title';
    final rows = hasQuery ? _db.select(sql, ['%$query%']) : _db.select(sql);
    return rows.map(TrackRow.fromRow).toList();
  }

  /// 按路径查单曲（watcher/播放定位用，不含 lyrics）。
  TrackRow? trackByPath(String path) {
    final rows =
        _db.select('SELECT $_trackColumns FROM tracks WHERE path = ?', [path]);
    return rows.isEmpty ? null : TrackRow.fromRow(rows.first);
  }

  /// 按 id 查单曲（不含 lyrics）。
  TrackRow? trackById(String id) {
    final rows =
        _db.select('SELECT $_trackColumns FROM tracks WHERE id = ?', [id]);
    return rows.isEmpty ? null : TrackRow.fromRow(rows.first);
  }

  /// 按 id 懒查内嵌歌词（列表查询不再携带；仅在需要歌词时调用）。
  String? lyricsById(String id) {
    final rows = _db.select('SELECT lyrics FROM tracks WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['lyrics'] as String?;
  }

  /// 按路径懒查内嵌歌词。
  String? lyricsByPath(String path) {
    final rows = _db.select('SELECT lyrics FROM tracks WHERE path = ?', [path]);
    return rows.isEmpty ? null : rows.first['lyrics'] as String?;
  }

  /// 从曲库移除曲目（按路径；仅删库记录，不删源文件；返回是否命中）。
  bool deleteByPath(String path) {
    _db.execute('DELETE FROM tracks WHERE path = ?', [path]);
    return _db.updatedRows > 0;
  }

  /// 从曲库移除曲目（按 id；仅删库记录，不删源文件；返回是否命中）。
  bool deleteById(String id) {
    _db.execute('DELETE FROM tracks WHERE id = ?', [id]);
    return _db.updatedRows > 0;
  }

  /// 曲库统计（总数 / 总文件大小字节 / 总时长毫秒）。
  ({int count, int totalSize, int totalDurationMs}) stats() {
    final res = _db.select(
      'SELECT COUNT(*) AS c, COALESCE(SUM(file_size), 0) AS sz, '
      'COALESCE(SUM(duration), 0) AS du FROM tracks',
    );
    final r = res.first;
    return (
      count: r['c'] as int? ?? 0,
      totalSize: r['sz'] as int? ?? 0,
      totalDurationMs: r['du'] as int? ?? 0,
    );
  }

  void close() => _db.close();
}

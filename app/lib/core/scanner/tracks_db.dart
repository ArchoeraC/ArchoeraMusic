import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'library_scanner.dart';

/// 本地曲目行（对应 tracks 表 schema，与 SPlayer-Next 对齐）。
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

  factory TrackRow.fromRow(Row row) {
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
      lyrics: row['lyrics'] as String?,
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

  /// 曲目总数。
  int count() {
    final res = _db.select('SELECT COUNT(*) AS c FROM tracks');
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
        ? 'SELECT * FROM tracks WHERE title LIKE ?1 OR path LIKE ?1 '
            'ORDER BY title LIMIT ?2 OFFSET ?3'
        : 'SELECT * FROM tracks ORDER BY title LIMIT ?1 OFFSET ?2';
    final params = hasQuery ? <Object?>['%$query%', limit, offset] : <Object?>[limit, offset];
    return _db.select(sql, params).map(TrackRow.fromRow).toList();
  }

  /// 按路径查单曲（watcher/播放定位用）。
  TrackRow? trackByPath(String path) {
    final rows =
        _db.select('SELECT * FROM tracks WHERE path = ?', [path]);
    return rows.isEmpty ? null : TrackRow.fromRow(rows.first);
  }

  /// 按 id 查单曲。
  TrackRow? trackById(String id) {
    final rows = _db.select('SELECT * FROM tracks WHERE id = ?', [id]);
    return rows.isEmpty ? null : TrackRow.fromRow(rows.first);
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

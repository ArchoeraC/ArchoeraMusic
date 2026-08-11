/// 「我喜欢」收藏列表本地缓存（sqlite3 FFI 直连，独立库 liked.db）。
///
/// 借鉴 SPlayer-Next IndexedDB 缓存语义：进收藏页先读本地缓存「立即
/// 渲染」（秒开），后台再按需拉取最新分页回写。缓存按曲目单行存储
/// （track_json + 全局 sort_order），读时 LIMIT/OFFSET 分页解码——
/// 不一次性把全量 JSON 载入内存，配合收藏页按需加载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../netease/track.dart';
import '../scanner/library_scanner.dart';

/// 「我喜欢」缓存数据层。
class LikedCacheStore {
  LikedCacheStore._(this._db);

  final Database _db;

  /// 缓存库默认路径（独立于曲库 library.db / 历史 history.db）。
  static String defaultDbPath() =>
      '${LibraryScanner.defaultDataDir()}/database/liked.db';

  static LikedCacheStore? _shared;

  /// 进程级共享实例（收藏页 loader 与缓存管理面板共用同一连接，
  /// 避免对同一文件开多个连接）。
  static LikedCacheStore get shared => _shared ??= LikedCacheStore.open();

  /// 打开（默认 [defaultDbPath]）。文件不存在时自动创建并建表（幂等）。
  static LikedCacheStore open([String? dbPath]) {
    final path = dbPath ?? defaultDbPath();
    File(path).parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('''
      CREATE TABLE IF NOT EXISTS liked_cache (
        platform   TEXT NOT NULL,
        user_key   TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        track_json TEXT NOT NULL,
        PRIMARY KEY (platform, user_key, sort_order)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS liked_meta (
        platform   TEXT NOT NULL,
        user_key   TEXT NOT NULL,
        total      INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (platform, user_key)
      )
    ''');
    return LikedCacheStore._(db);
  }

  /// 读缓存分页（按 sort_order 升序；limit 为 null 时读至末尾）。
  /// 返回空列表表示无缓存；单条 JSON 损坏静默跳过。
  List<Track> loadRange(
    String platform,
    String userKey, {
    int offset = 0,
    int? limit,
  }) {
    final rows = limit == null
        ? _db.select(
            'SELECT track_json FROM liked_cache '
            'WHERE platform = ? AND user_key = ? '
            'ORDER BY sort_order ASC LIMIT -1 OFFSET ?',
            [platform, userKey, offset],
          )
        : _db.select(
            'SELECT track_json FROM liked_cache '
            'WHERE platform = ? AND user_key = ? '
            'ORDER BY sort_order ASC LIMIT ? OFFSET ?',
            [platform, userKey, limit, offset],
          );
    final out = <Track>[];
    for (final row in rows) {
      final json = row['track_json'] as String?;
      if (json == null || json.isEmpty) continue;
      try {
        out.add(Track.fromJson(jsonDecode(json) as Map<String, dynamic>));
      } catch (_) {
        // 单条损坏跳过
      }
    }
    return out;
  }

  /// 缓存总数（meta.total；无缓存返回 null）。
  int? total(String platform, String userKey) {
    final res = _db.select(
      'SELECT total FROM liked_meta WHERE platform = ? AND user_key = ?',
      [platform, userKey],
    );
    return res.isEmpty ? null : res.first['total'] as int?;
  }

  /// 全量替换缓存（事务；刷新首页后写，替代旧快照）。
  void replace(
    String platform,
    String userKey,
    List<Track> tracks, {
    int? total,
    int? updatedAt,
  }) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        'DELETE FROM liked_cache WHERE platform = ? AND user_key = ?',
        [platform, userKey],
      );
      for (var i = 0; i < tracks.length; i++) {
        _insertTrack(platform, userKey, i, tracks[i]);
      }
      _upsertMeta(
        platform,
        userKey,
        total ?? tracks.length,
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
    }
  }

  /// 追加缓存段（分页增量写；[startIndex] 为该段在全局顺序中的起始下标）。
  /// 只写新段、不触碰已缓存行——触底加载后同步落盘，重启可续。
  void append(
    String platform,
    String userKey,
    List<Track> tracks, {
    required int startIndex,
    int? total,
  }) {
    _db.execute('BEGIN');
    try {
      for (var i = 0; i < tracks.length; i++) {
        _insertTrack(platform, userKey, startIndex + i, tracks[i]);
      }
      _upsertMeta(
        platform,
        userKey,
        total ?? startIndex + tracks.length,
        DateTime.now().millisecondsSinceEpoch,
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
    }
  }

  /// 删除某平台缓存（退出登录时清理，防串号）。
  void invalidate(String platform, String userKey) {
    try {
      _db.execute(
        'DELETE FROM liked_cache WHERE platform = ? AND user_key = ?',
        [platform, userKey],
      );
      _db.execute(
        'DELETE FROM liked_meta WHERE platform = ? AND user_key = ?',
        [platform, userKey],
      );
    } catch (_) {}
  }

  /// 缓存曲目总条数（全平台合计，缓存管理统计用）。
  int rowCount() {
    final res = _db.select('SELECT COUNT(*) AS c FROM liked_cache');
    return (res.first['c'] as int?) ?? 0;
  }

  /// 清空全部缓存（缓存管理「清空」用；保留库文件，下次读写自动重建）。
  void clearAll() {
    try {
      _db.execute('DELETE FROM liked_cache');
      _db.execute('DELETE FROM liked_meta');
    } catch (_) {}
  }

  void _insertTrack(String platform, String userKey, int order, Track track) {
    if (track.id.isEmpty) return;
    _db.execute(
      'INSERT OR REPLACE INTO liked_cache '
      '(platform, user_key, sort_order, track_json) VALUES (?, ?, ?, ?)',
      [platform, userKey, order, jsonEncode(track.toJson())],
    );
  }

  void _upsertMeta(String platform, String userKey, int total, int updatedAt) {
    _db.execute(
      'INSERT INTO liked_meta (platform, user_key, total, updated_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(platform, user_key) DO UPDATE SET '
      'total = excluded.total, updated_at = excluded.updated_at',
      [platform, userKey, total, updatedAt],
    );
  }

  void close() => _db.close();
}

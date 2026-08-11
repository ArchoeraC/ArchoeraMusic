/// 播放历史本地存储（sqlite3 FFI 直连，独立库 history.db，与本地曲库
/// library.db 分库——历史包含在线媒体与本地媒体，不应混入曲库）。
///
/// 对齐 SPlayer-Next `src/stores/history.ts` 语义：
/// - 同源同 id 去重（key = `source:track_id`），重复播放刷新时间置顶；
/// - 上限 [maxEntries]（500）条，超出按时间倒序裁掉最旧；
/// - 记录完整 Track 快照（JSON），离线可用、列表直接可播。
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../netease/track.dart';
import '../scanner/library_scanner.dart';

/// 播放历史条目。
class HistoryEntry {
  const HistoryEntry({required this.track, required this.playedAt});

  /// 曲目快照（fromJson 还原，可直接播放）。
  final Track track;

  /// 最近一次播放时间（unix 毫秒）。
  final int playedAt;
}

/// 播放历史数据层。
class HistoryStore {
  HistoryStore._(this._db);

  final Database _db;

  /// 历史条数上限（对齐 SPlayer-Next MAX_HISTORY）。
  static const int maxEntries = 500;

  /// 历史库默认路径（独立于曲库 library.db）。
  static String defaultDbPath() =>
      '${LibraryScanner.defaultDataDir()}/database/history.db';

  /// 打开（默认 [defaultDbPath]，与曲库分库）。
  /// 文件不存在时自动创建，并建表（幂等）；首次打开时从旧库
  /// （0.8.3 前混储于 library.db 的 play_history 表）一次性迁移历史。
  static HistoryStore open([String? dbPath]) {
    final path = dbPath ?? defaultDbPath();
    File(path).parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    // 扫描器（NativeAOT 直写同库）进行中时可能锁表，短暂等待避免 SQLITE_BUSY
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('''
      CREATE TABLE IF NOT EXISTS play_history (
        source     TEXT NOT NULL,
        track_id   TEXT NOT NULL,
        track_json TEXT NOT NULL,
        played_at  INTEGER NOT NULL,
        PRIMARY KEY (source, track_id)
      )
    ''');
    _migrateLegacy(db, path);
    return HistoryStore._(db);
  }

  /// 一次性迁移：旧版本历史曾混储于曲库 library.db 的 play_history 表，
  /// 将其搬入独立历史库（仅读取旧库，迁移失败静默，不影响启动）。
  static void _migrateLegacy(Database db, String newPath) {
    final legacyPath = LibraryScanner.defaultDbPath();
    if (legacyPath == newPath || !File(legacyPath).existsSync()) return;
    try {
      final legacy = sqlite3.open(legacyPath);
      try {
        legacy.execute('PRAGMA busy_timeout = 2000');
        final hasTable = legacy.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='play_history'",
        );
        if (hasTable.isEmpty) return;
        final rows = legacy.select('SELECT * FROM play_history');
        for (final row in rows) {
          try {
            db.execute(
              'INSERT OR IGNORE INTO play_history '
              '(source, track_id, track_json, played_at) '
              'VALUES (?, ?, ?, ?)',
              [
                row['source'],
                row['track_id'],
                row['track_json'],
                row['played_at'],
              ],
            );
          } catch (_) {
            // 单条迁移失败跳过
          }
        }
      } finally {
        legacy.close();
      }
    } catch (_) {
      // 迁移失败静默（不影响启动）
    }
  }

  /// 记录一次播放：同源同 id 去重置顶（INSERT ... ON CONFLICT UPDATE）。
  /// 同步执行（单行 upsert，微秒级）；失败静默（不影响播放）。
  void record(Track track) {
    if (track.id.isEmpty) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      _db.execute(
        'INSERT INTO play_history (source, track_id, track_json, played_at) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(source, track_id) DO UPDATE SET '
        'track_json = excluded.track_json, played_at = excluded.played_at',
        [track.source, track.id, jsonEncode(track.toJson()), now],
      );
      // 超上限：按时间倒序保留最新 maxEntries 条
      _db.execute(
        'DELETE FROM play_history WHERE (source, track_id) NOT IN ('
        'SELECT source, track_id FROM play_history '
        'ORDER BY played_at DESC, rowid DESC LIMIT ?)',
        [maxEntries],
      );
    } catch (_) {
      // 历史记录失败不影响播放主流程
    }
  }

  /// 播放历史（按时间倒序，最近在前）。
  List<HistoryEntry> entries() {
    final rows = _db.select(
      'SELECT * FROM play_history ORDER BY played_at DESC, rowid DESC',
    );
    final out = <HistoryEntry>[];
    for (final row in rows) {
      try {
        final json = row['track_json'] as String?;
        if (json == null || json.isEmpty) continue;
        final track = Track.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
        out.add(HistoryEntry(
          track: track,
          playedAt: row['played_at'] as int? ?? 0,
        ));
      } catch (_) {
        // 单条损坏跳过
      }
    }
    return out;
  }

  /// 条目总数。
  int count() {
    final res = _db.select('SELECT COUNT(*) AS c FROM play_history');
    return res.first['c'] as int? ?? 0;
  }

  /// 移除单条历史。
  void remove(Track track) {
    try {
      _db.execute(
        'DELETE FROM play_history WHERE source = ? AND track_id = ?',
        [track.source, track.id],
      );
    } catch (_) {}
  }

  /// 清空全部历史。
  void clear() {
    try {
      _db.execute('DELETE FROM play_history');
    } catch (_) {}
  }

  void close() => _db.close();
}

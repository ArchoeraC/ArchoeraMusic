/// 「我喜欢」收藏列表本地缓存（sqlite3 FFI 直连，独立库 liked.db）。
///
/// 借鉴 SPlayer-Next IndexedDB 缓存语义：进收藏页先读本地缓存「立即
/// 渲染」（秒开），后台再全量拉取最新列表回写。缓存按曲目单行存储
/// （track_json + 全局 sort_order），全量替换写入（replace）——行数与
/// meta.total 始终一致，不存在「标记总数但数据不完整」的分页残留。
///
/// 线程模型：sqlite3 同步 API 会阻塞所在 isolate 的事件循环，直接在
/// UI isolate 做千级全量读写会造成卡顿；因此**所有操作都在后台 isolate
/// （[Isolate.run]）内执行**——每次操作重开临时连接、批量写入后关闭，
/// UI isolate 全程无感。实例无状态，[shared] 仅作命名空间。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../netease/track.dart';
import '../scanner/library_scanner.dart';

/// 「我喜欢」缓存数据层（无状态：每次操作在后台 isolate 重开连接）。
class LikedCacheStore {
  const LikedCacheStore._();

  /// 进程级共享实例（无共享连接，无跨 isolate 状态）。
  static const LikedCacheStore shared = LikedCacheStore._();

  /// 缓存库默认路径（独立于曲库 library.db / 历史 history.db）。
  static String defaultDbPath() =>
      '${LibraryScanner.defaultDataDir()}/database/liked.db';

  /// 在后台 isolate 打开并初始化（幂等建表），回调内使用后关闭。
  static T _withDb<T>(T Function(Database db) action) {
    final path = defaultDbPath();
    File(path).parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    try {
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
      return action(db);
    } finally {
      db.close();
    }
  }

  /// 读缓存全量（按 sort_order 升序，即收藏先后）。
  /// 返回空列表表示无缓存；单条 JSON 损坏静默跳过。
  /// JSON 解码在后台 isolate 完成，UI 只做轻量对象构造。
  Future<List<Track>> loadAll(String platform, String userKey) async {
    final rows = await Isolate.run(() {
      return _withDb<List<Map<String, dynamic>>>((db) {
        final out = <Map<String, dynamic>>[];
        final res = db.select(
          'SELECT track_json FROM liked_cache '
          'WHERE platform = ? AND user_key = ? '
          'ORDER BY sort_order ASC',
          [platform, userKey],
        );
        for (final row in res) {
          final json = row['track_json'] as String?;
          if (json == null || json.isEmpty) continue;
          try {
            out.add(jsonDecode(json) as Map<String, dynamic>);
          } catch (_) {
            // 单条损坏跳过
          }
        }
        return out;
      });
    });
    return rows.map(Track.fromJson).toList();
  }

  /// 缓存总数（meta.total；无缓存返回 null）。
  Future<int?> total(String platform, String userKey) async {
    return Isolate.run(() {
      return _withDb<int?>((db) {
        final res = db.select(
          'SELECT total FROM liked_meta WHERE platform = ? AND user_key = ?',
          [platform, userKey],
        );
        return res.isEmpty ? null : res.first['total'] as int?;
      });
    });
  }

  /// 全量替换缓存（后台 isolate 事务 + 批量插入；刷新后写，替代旧快照）。
  Future<void> replace(
    String platform,
    String userKey,
    List<Track> tracks, {
    int? total,
    int? updatedAt,
  }) async {
    // 主 isolate 只做纯内存 Map 构造（可发送）；SQLite 事务/编码在后台
    final payload = tracks.map((t) => t.toJson()).toList();
    final totalNow = total ?? tracks.length;
    final updatedAtNow = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
    await Isolate.run(() {
      _withDb((db) {
        db.execute('BEGIN');
        try {
          db.execute(
            'DELETE FROM liked_cache WHERE platform = ? AND user_key = ?',
            [platform, userKey],
          );
          // 批量插入：prepare 一次 + 逐行 execute（sqlite3 包 execute 只
          // 接受单行扁平参数，嵌套列表会抛「Expected N parameters」导致
          // 事务回滚、写入静默失效——这是历史上「缓存永远 0 行」的根因）
          final stmt = db.prepare(
            'INSERT OR REPLACE INTO liked_cache '
            '(platform, user_key, sort_order, track_json) '
            'VALUES (?, ?, ?, ?)',
          );
          try {
            for (var i = 0; i < payload.length; i++) {
              stmt.execute([platform, userKey, i, jsonEncode(payload[i])]);
            }
          } finally {
            stmt.close();
          }
          db.execute(
            'INSERT INTO liked_meta (platform, user_key, total, updated_at) '
            'VALUES (?, ?, ?, ?) '
            'ON CONFLICT(platform, user_key) DO UPDATE SET '
            'total = excluded.total, updated_at = excluded.updated_at',
            [platform, userKey, totalNow, updatedAtNow],
          );
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      });
    });
  }

  /// 删除某平台缓存（退出登录时清理，防串号）。
  Future<void> invalidate(String platform, String userKey) async {
    await Isolate.run(() {
      _withDb((db) {
        db.execute(
          'DELETE FROM liked_cache WHERE platform = ? AND user_key = ?',
          [platform, userKey],
        );
        db.execute(
          'DELETE FROM liked_meta WHERE platform = ? AND user_key = ?',
          [platform, userKey],
        );
      });
    });
  }

  /// 缓存曲目总条数（全平台合计，缓存管理统计用）。
  Future<int> rowCount() async {
    return Isolate.run(() {
      return _withDb<int>((db) {
        final res = db.select('SELECT COUNT(*) AS c FROM liked_cache');
        return (res.first['c'] as int?) ?? 0;
      });
    });
  }

  /// 清空全部缓存（缓存管理「清空」用；保留库文件，下次读写自动重建）。
  Future<void> clearAll() async {
    await Isolate.run(() {
      _withDb((db) {
        db.execute('DELETE FROM liked_cache');
        db.execute('DELETE FROM liked_meta');
      });
    });
  }
}

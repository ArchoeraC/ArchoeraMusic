/// 播放历史本地存储（sqlite3 直连，独立库 history.db，与本地曲库
/// library.db 分库——历史包含在线媒体与本地媒体，不应混入曲库）。
///
/// 对齐 SPlayer-Next `src/stores/history.ts` 语义：
/// - 同源同 id 去重（key = `source:track_id`），重复播放刷新时间置顶；
/// - 条数上限可配置（[record]/[trim] 的 limit 参数，null = 不限制；
///   默认 [defaultLimit] 500），超出按时间倒序裁掉最旧；
/// - 记录完整 Track 快照（JSON），离线可用、列表直接可播。
///
/// 线程模型：**UI isolate 直接同步读写**。历史写入量极小（单条 INSERT +
/// 至多一次上限裁剪 DELETE），WAL 模式下微秒级完成，不会造成可感知卡顿；
/// 因此不使用 Isolate.run 后台 isolate——每操作现开 isolate 开销大，且
/// sqlite3 包 native assets 在 AOT 产物子 isolate 中不可靠，真实环境曾
/// 导致历史写入静默失败。写入失败不抛给调用方，经 [_log] 记日志
/// （播放流程落库失败不影响播放）。
library;

import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../stores/event_bus.dart';
import '../netease/track.dart';
import '../scanner/library_scanner.dart';

/// 历史变更事件（记录 / 移除 / 清空 / 裁剪后广播）。
///
/// 异步投递（sync:false）：历史页 / 设置页经 [HistoryStore.changes] 订阅
/// 即时刷新，且不阻塞写入方调用链（播放事件处理中 record 时，不把整表
/// 重读塞进播放路径）。
class HistoryChangedEvent {}

/// 播放历史条目。
class HistoryEntry {
  const HistoryEntry({required this.track, required this.playedAt});

  /// 曲目快照（fromJson 还原，可直接播放）。
  final Track track;

  /// 最近一次播放时间（unix 毫秒）。
  final int playedAt;
}

/// 播放历史数据层（无状态：每次操作重开连接、用后即关）。
class HistoryStore {
  const HistoryStore._();

  /// 进程级共享实例（无共享连接，无跨 isolate 状态）。
  static const HistoryStore shared = HistoryStore._();

  /// 历史变更事件总线（异步投递，见 [HistoryChangedEvent]）。
  ///
  /// 历史页 / 设置页订阅即时刷新；写入方无需感知 UI。
  static final EventBus changes = EventBus(sync: false);

  /// 默认历史条数上限（对齐 SPlayer-Next MAX_HISTORY）。
  static const int defaultLimit = 500;

  /// 历史库默认路径（独立于曲库 library.db）。
  static String defaultDbPath() =>
      '${LibraryScanner.defaultDataDir()}/database/history.db';

  /// 数据库路径覆盖（仅测试注入用）。
  static String? overrideDbPath;

  /// 旧库迁移是否已执行（进程级一次性，见 [_migrateLegacy]）。
  static bool _legacyMigrated = false;

  static void _log(String line) {
    dev.log(line, name: 'HistoryStore');
  }

  /// 打开并初始化（幂等建表 + 一次性旧库迁移），回调内使用后关闭。
  /// 失败记录日志后原样抛出；读取类方法在内部回退默认值，写入类方法
  /// 在内部静默——调用方（播放流程/设置 UI）无需感知 DB 细节。
  static T _withDb<T>(T Function(Database db) action) {
    final migrate = !_legacyMigrated;
    _legacyMigrated = true;
    final path = overrideDbPath ?? defaultDbPath();
    Database? db;
    try {
      File(path).parent.createSync(recursive: true);
      db = sqlite3.open(path);
      // 防御性等待：单线程直写下本库无竞争，此处主要兜底异常场景
      db.execute('PRAGMA busy_timeout = 1000');
      db.execute('''
        CREATE TABLE IF NOT EXISTS play_history (
          source     TEXT NOT NULL,
          track_id   TEXT NOT NULL,
          track_json TEXT NOT NULL,
          played_at  INTEGER NOT NULL,
          PRIMARY KEY (source, track_id)
        )
      ''');
      if (migrate) _migrateLegacy(db, path);
      return action(db);
    } catch (e, s) {
      _log('操作失败: $e\n$s');
      rethrow;
    } finally {
      db?.close();
    }
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
  ///
  /// [limit] 为条数上限（null = 不限制，不执行裁剪）。失败静默
  /// （记日志，不影响播放）。成功经 [changes] 广播变更事件。
  void record(Track track, {int? limit}) {
    if (track.id.isEmpty) return;
    try {
      _withDb((db) {
        final now = DateTime.now().millisecondsSinceEpoch;
        db.execute(
          'INSERT INTO play_history (source, track_id, track_json, played_at) '
          'VALUES (?, ?, ?, ?) '
          'ON CONFLICT(source, track_id) DO UPDATE SET '
          'track_json = excluded.track_json, played_at = excluded.played_at',
          [track.source, track.id, jsonEncode(track.toJson()), now],
        );
        if (limit != null && limit > 0) {
          // 仅在超限时才裁剪：绝大多数写入远低于上限，先数后删避免
          // 每次记录都做全表 ORDER BY + DELETE（大库下正是播放开播瞬间
          // 卡顿的来源之一）。
          final count = db.select(
            'SELECT COUNT(*) AS c FROM play_history',
          ).first['c'] as int? ?? 0;
          if (count > limit) {
            // 超上限：按时间倒序保留最新 limit 条
            db.execute(
              'DELETE FROM play_history WHERE (source, track_id) NOT IN ('
              'SELECT source, track_id FROM play_history '
              'ORDER BY played_at DESC, rowid DESC LIMIT ?)',
              [limit],
            );
          }
        }
      });
      changes.emit(HistoryChangedEvent());
    } catch (_) {
      // 失败已由 _withDb 记日志
    }
  }

  /// 按新上限立即裁剪（设置变更时调用；null = 不限制，不裁剪）。
  void trim(int? limit) {
    if (limit == null || limit <= 0) return;
    try {
      _withDb((db) {
        db.execute(
          'DELETE FROM play_history WHERE (source, track_id) NOT IN ('
          'SELECT source, track_id FROM play_history '
          'ORDER BY played_at DESC, rowid DESC LIMIT ?)',
          [limit],
        );
      });
      changes.emit(HistoryChangedEvent());
    } catch (_) {}
  }

  /// 播放历史（按时间倒序，最近在前）。
  List<HistoryEntry> entries() {
    try {
      return _withDb((db) {
        final rows = db.select(
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
      });
    } catch (_) {
      return const [];
    }
  }

  /// 条目总数。
  int count() {
    try {
      return _withDb((db) {
        final res = db.select('SELECT COUNT(*) AS c FROM play_history');
        return res.first['c'] as int? ?? 0;
      });
    } catch (_) {
      return 0;
    }
  }

  /// 移除单条历史。
  void remove(Track track) {
    try {
      _withDb((db) {
        db.execute(
          'DELETE FROM play_history WHERE source = ? AND track_id = ?',
          [track.source, track.id],
        );
      });
      changes.emit(HistoryChangedEvent());
    } catch (_) {}
  }

  /// 清空全部历史。
  void clear() {
    try {
      _withDb((db) {
        db.execute('DELETE FROM play_history');
      });
      changes.emit(HistoryChangedEvent());
    } catch (_) {}
  }
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 每日推荐「书架」：按**逻辑日**归档各账号的每日推荐曲目。
///
/// - 逻辑日以 [kDailyRolloverHour] 为界（凌晨未睡仍算前一天，与首页问候一致）；
/// - 每个账号保留最近 [kDailyShelfCap] 天（今日在前），供「今天 / 历史」切换；
/// - JSON 文件覆盖式持久化（`daily_shelf.json`），失败静默不影响播放。
///
/// 与「随机聚光」（`services/spotlight`）配合：聚光的每日来源直接取今日书架。
library;

import 'dart:convert';
import 'dart:io';

import '../../stores/data_dir.dart';
import '../netease/track.dart';

/// 逻辑日切换时刻（本地时间）。与首页「凌晨<5 点算深夜」一致。
const int kDailyRolloverHour = 5;

/// 每个账号保留的每日推荐天数。
const int kDailyShelfCap = 21;

/// 逻辑日 key（`yyyy-MM-dd`）：`now` 减去 [kDailyRolloverHour] 小时后的日期。
String dailyShelfDayKey(DateTime now) {
  final d = now.subtract(const Duration(hours: kDailyRolloverHour));
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// 某天的每日推荐。
class DailyShelfDay {
  const DailyShelfDay({
    required this.key,
    required this.savedAtMs,
    required this.tracks,
  });

  /// 逻辑日 key（[dailyShelfDayKey]）。
  final String key;

  /// 拉取时刻（毫秒）。
  final int savedAtMs;

  final List<Track> tracks;

  Map<String, dynamic> toJson() => {
    'key': key,
    'savedAt': savedAtMs,
    'tracks': [for (final t in tracks) t.toJson()],
  };

  static DailyShelfDay? fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    if (key is! String || key.isEmpty) return null;
    final raw = json['tracks'];
    final tracks = <Track>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          try {
            tracks.add(Track.fromJson(Map<String, dynamic>.from(item)));
          } catch (_) {
            // 单曲损坏跳过，不影响整档
          }
        }
      }
    }
    return DailyShelfDay(
      key: key,
      savedAtMs: (json['savedAt'] as num?)?.toInt() ?? 0,
      tracks: tracks,
    );
  }
}

/// 每日推荐书架持久化（JSON 文件，覆盖式写入）。
class DailyShelfStore {
  const DailyShelfStore();

  /// 测试用路径覆盖（非空时替代默认数据目录文件）。
  static String? overridePath;

  /// 书架文件路径（数据目录 `~/.local/share/ArchoeraMusic`）。
  static String get filePath =>
      overridePath ?? '${resolveDataDir()}/daily_shelf.json';

  /// 读取全部账号的书架；无文件 / 损坏时返回空表。
  Map<String, List<DailyShelfDay>> readAll() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return {};
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return {};
      final users = json['users'];
      if (users is! Map) return {};
      final out = <String, List<DailyShelfDay>>{};
      users.forEach((uid, list) {
        if (uid is! String || list is! List) return;
        final days = <DailyShelfDay>[];
        for (final item in list) {
          if (item is! Map) continue;
          final day = DailyShelfDay.fromJson(Map<String, dynamic>.from(item));
          if (day != null) days.add(day);
        }
        if (days.isNotEmpty) out[uid] = days;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  /// 某账号的归档（今日在前，最新在前）；无则空表。
  List<DailyShelfDay> days(String uid) => readAll()[uid] ?? const [];

  /// 写入某账号某天的推荐（同日覆盖并前插，超出 [kDailyShelfCap] 截断）。
  void put(String uid, DailyShelfDay day) {
    if (uid.isEmpty || day.tracks.isEmpty) return;
    try {
      final all = readAll();
      final list = <DailyShelfDay>[
        day,
        ...(all[uid] ?? const <DailyShelfDay>[]).where((d) => d.key != day.key),
      ];
      all[uid] = list.length > kDailyShelfCap
          ? list.sublist(0, kDailyShelfCap)
          : list;
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'v': 1,
          'users': {
            for (final e in all.entries)
              e.key: [for (final d in e.value) d.toJson()],
          },
        }),
      );
    } catch (_) {
      // 持久化失败不阻塞（重启后重新拉取即可）
    }
  }

  /// 清空全部账号书架。
  void clear() {
    try {
      final file = File(filePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// 清空某账号书架。
  void clearUser(String uid) {
    if (uid.isEmpty) return;
    try {
      final all = readAll()..remove(uid);
      if (all.isEmpty) {
        clear();
        return;
      }
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'v': 1,
          'users': {
            for (final e in all.entries)
              e.key: [for (final d in e.value) d.toJson()],
          },
        }),
      );
    } catch (_) {}
  }
}

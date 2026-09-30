// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 每日推荐书架测试：逻辑日边界、按账号归档、去重与容量。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/daily/daily_shelf.dart';
import 'package:archoera_music/services/netease/track.dart';

Track _t(String id) =>
    Track(id: id, title: 'T$id', source: 'netease', artists: const []);

void main() {
  group('dailyShelfDayKey（逻辑日以 kDailyRolloverHour 为界）', () {
    test('切换时刻之前算前一天、之后算当天', () {
      expect(
        dailyShelfDayKey(DateTime(2026, 9, 30, kDailyRolloverHour - 1, 59)),
        '2026-09-29',
      );
      expect(
        dailyShelfDayKey(DateTime(2026, 9, 30, kDailyRolloverHour, 0)),
        '2026-09-30',
      );
      expect(dailyShelfDayKey(DateTime(2026, 9, 30, 23, 59)), '2026-09-30');
    });
  });

  group('DailyShelfStore', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('daily_shelf_test');
      DailyShelfStore.overridePath = '${tmp.path}/daily_shelf.json';
    });

    tearDown(() {
      DailyShelfStore.overridePath = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('写入 / 读取 / 同日覆盖前插', () {
      const store = DailyShelfStore();
      store.put('u1', DailyShelfDay(key: '2026-09-29', savedAtMs: 1, tracks: [_t('a')]));
      store.put('u1', DailyShelfDay(key: '2026-09-30', savedAtMs: 2, tracks: [_t('b'), _t('c')]));
      // 同日覆盖：应替换而非新增。
      store.put('u1', DailyShelfDay(key: '2026-09-30', savedAtMs: 3, tracks: [_t('d')]));

      final days = store.days('u1');
      expect(days.length, 2);
      expect(days.first.key, '2026-09-30');
      expect(days.first.tracks.single.id, 'd');
      expect(days[1].key, '2026-09-29');
    });

    test('按账号隔离', () {
      const store = DailyShelfStore();
      store.put('u1', DailyShelfDay(key: '2026-09-30', savedAtMs: 1, tracks: [_t('a')]));
      store.put('u2', DailyShelfDay(key: '2026-09-30', savedAtMs: 1, tracks: [_t('b')]));
      expect(store.days('u1').single.tracks.single.id, 'a');
      expect(store.days('u2').single.tracks.single.id, 'b');
      store.clearUser('u1');
      expect(store.days('u1'), isEmpty);
      expect(store.days('u2'), isNotEmpty);
    });

    test('容量上限截断（保留最新）', () {
      const store = DailyShelfStore();
      for (var i = 0; i < kDailyShelfCap + 5; i++) {
        store.put(
          'u1',
          DailyShelfDay(
            key: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
            savedAtMs: i,
            tracks: [_t('$i')],
          ),
        );
      }
      final days = store.days('u1');
      expect(days.length, kDailyShelfCap);
      // 最新写入在最前。
      expect(days.first.tracks.single.id, '${kDailyShelfCap + 4}');
    });

    test('空曲目不写入；损坏文件安全返回空', () {
      const store = DailyShelfStore();
      store.put('u1', DailyShelfDay(key: '2026-09-30', savedAtMs: 1, tracks: const []));
      expect(store.days('u1'), isEmpty);

      File(DailyShelfStore.filePath).writeAsStringSync('{ not json');
      expect(store.days('u1'), isEmpty);
    });

    test('DailyShelfDay JSON 往返（含 Track）', () {
      final day = DailyShelfDay(
        key: '2026-09-30',
        savedAtMs: 123,
        tracks: [_t('x')],
      );
      final back = DailyShelfDay.fromJson(day.toJson())!;
      expect(back.key, '2026-09-30');
      expect(back.savedAtMs, 123);
      expect(back.tracks.single.id, 'x');
    });
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放模式回归测试：新增的「顺序播放」（'off'，队列到尾自动暂停）、三态轮换、
/// 以及会话快照对播放模式的校验回落。
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_session.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/services/playback/shuffle_bag.dart';

/// 无引擎的假控制器：只验证播放模式状态机。
class _FakePlaybackNotifier extends PlaybackNotifier {
  _FakePlaybackNotifier([this.initial = const PlaybackState()]);

  final PlaybackState initial;

  @override
  PlaybackState build() => initial;
}

({ProviderContainer container, _FakePlaybackNotifier playback}) _setupPlayback([
  PlaybackState? initial,
]) {
  final fake = _FakePlaybackNotifier(initial ?? const PlaybackState());
  final c = ProviderContainer(
    overrides: [playbackProvider.overrideWith(() => fake)],
  );
  addTearDown(c.dispose);
  c.read(playbackProvider); // 初始化 notifier
  return (container: c, playback: fake);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('播放模式常量', () {
    test('三态：顺序 / 列表循环 / 单曲循环，且每态都有中文文案', () {
      expect(repeatModeCycle, ['off', 'list', 'one']);
      for (final mode in repeatModeCycle) {
        expect(repeatModeLabels[mode], isNotNull, reason: '$mode 缺少文案');
      }
      expect(repeatModeLabels['off'], '顺序播放');
    });

    test('isSequentialQueueEnd：仅顺序播放且位于队尾为真', () {
      expect(isSequentialQueueEnd('off', 4, 5), isTrue);
      expect(isSequentialQueueEnd('off', 0, 1), isTrue);
      expect(isSequentialQueueEnd('off', 3, 5), isFalse, reason: '未到队尾');
      expect(isSequentialQueueEnd('list', 4, 5), isFalse, reason: '列表循环回绕');
      expect(isSequentialQueueEnd('one', 4, 5), isFalse, reason: '单曲循环');
      expect(isSequentialQueueEnd('off', 0, 0), isFalse, reason: '空队列');
    });
  });

  group('cycleRepeatMode / setRepeatMode', () {
    test('默认列表循环，按 列表 → 单曲 → 顺序 → 列表 轮换', () {
      final s = _setupPlayback();
      final pb = s.playback;
      expect(pb.state.repeatMode, 'list');
      pb.cycleRepeatMode();
      expect(pb.state.repeatMode, 'one');
      pb.cycleRepeatMode();
      expect(pb.state.repeatMode, 'off');
      pb.cycleRepeatMode();
      expect(pb.state.repeatMode, 'list');
    });

    test('setRepeatMode 接受三态、拒绝未知值', () {
      final s = _setupPlayback();
      final pb = s.playback;
      pb.setRepeatMode('off');
      expect(pb.state.repeatMode, 'off');
      pb.setRepeatMode('bogus');
      expect(pb.state.repeatMode, 'off', reason: '非法模式应被忽略');
    });
  });

  group('随机播放', () {
    List<Track> tracks(int n) => [
      for (var i = 0; i < n; i++)
        Track(id: '$i', title: 'T$i', source: 'local'),
    ];

    test('待播袋一轮内不重复，取完后为空', () {
      final bag = ShuffleBag(math.Random(7))..reset(['a', 'b', 'c', 'd']);
      final seen = <String>{};
      while (!bag.isEmpty) {
        final key = bag.take();
        expect(key, isNotNull);
        expect(seen.add(key!), isTrue, reason: '同一轮不应重复取到 $key');
      }
      expect(seen, {'a', 'b', 'c', 'd'});
      expect(bag.take(), isNull, reason: '空袋应返回 null');
    });

    test('开启随机不重排队列，next 在整个队列内随机跳转且一轮不重复', () {
      final queue = tracks(6);
      final s = _setupPlayback(PlaybackState(queue: queue, queueIndex: 2));
      final pb = s.playback;

      pb.setShuffle(true);
      expect(pb.state.shuffle, isTrue);
      expect(pb.state.queue, queue, reason: '队列曲目位置必须保持原样');
      expect(pb.state.queueIndex, 2, reason: '开启随机不应改变当前曲目');

      final seen = <int>{2};
      for (var i = 0; i < queue.length - 1; i++) {
        pb.debugAdvanceNext();
        expect(pb.state.queue, queue, reason: '随机切歌不得重排队列');
        final idx = pb.state.queueIndex;
        expect(idx, inInclusiveRange(0, queue.length - 1));
        expect(seen.add(idx), isTrue, reason: '一轮内不应重复播放同一位置');
      }
      expect(seen.length, queue.length, reason: '一轮应覆盖整个队列');

      // 第二轮重新装填：仍不重排队列，且不立即重复当前曲。
      final before = pb.state.queueIndex;
      pb.debugAdvanceNext();
      expect(pb.state.queue, queue);
      expect(pb.state.queueIndex, isNot(before));

      final current = pb.state.queueIndex;
      pb.setShuffle(false);
      expect(pb.state.queue, queue, reason: '关闭随机也不应改变队列顺序');
      expect(pb.state.queueIndex, current);
    });
  });

  group('会话快照播放模式校验', () {
    test('保留合法三态', () {
      for (final mode in repeatModeCycle) {
        final snap = PlaybackSnapshot.fromJson({'repeatMode': mode});
        expect(snap.repeatMode, mode);
      }
    });

    test('缺失/未知一律回落 list', () {
      expect(PlaybackSnapshot.fromJson(const {}).repeatMode, 'list');
      expect(
        PlaybackSnapshot.fromJson({'repeatMode': 'bogus'}).repeatMode,
        'list',
      );
    });
  });

  group('「已播完」提示文案', () {
    test('各语言均有非空 queueFinished', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        expect(
          l.queueFinished.trim(),
          isNotEmpty,
          reason: '$locale 缺 queueFinished',
        );
      }
    });
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放模式回归测试：新增的「顺序播放」（'off'，队列到尾自动暂停）、三态轮换、
/// 以及会话快照对播放模式的校验回落。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_session.dart';
import 'package:archoera_music/services/playback/playback_state.dart';

/// 无引擎的假控制器：只验证播放模式状态机。
class _FakePlaybackNotifier extends PlaybackNotifier {
  @override
  PlaybackState build() => const PlaybackState();
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
    ({ProviderContainer container, _FakePlaybackNotifier playback}) setup() {
      final fake = _FakePlaybackNotifier();
      final c = ProviderContainer(
        overrides: [playbackProvider.overrideWith(() => fake)],
      );
      addTearDown(c.dispose);
      c.read(playbackProvider); // 初始化 notifier
      return (container: c, playback: fake);
    }

    test('默认列表循环，按 列表 → 单曲 → 顺序 → 列表 轮换', () {
      final s = setup();
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
      final s = setup();
      final pb = s.playback;
      pb.setRepeatMode('off');
      expect(pb.state.repeatMode, 'off');
      pb.setRepeatMode('bogus');
      expect(pb.state.repeatMode, 'off', reason: '非法模式应被忽略');
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

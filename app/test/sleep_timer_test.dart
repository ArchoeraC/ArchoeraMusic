// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 睡眠定时器回归测试：显式暂停（不 toggle 翻转）、到时「播完当前曲再暂停」
/// 开关、以及切歌/缓冲过渡瞬间触发时不丢暂停动作（挂起待出声再暂停）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/services/playback/sleep_timer.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 内存偏好（不落盘），仅覆盖本测试用到的 setter。
class _TestPrefs extends AppPrefsNotifier {
  _TestPrefs(this._initial);
  final AppPrefs _initial;

  @override
  AppPrefs build() => _initial;

  @override
  void setSleepFinishTrack(bool value) {
    state = state.copyWithSleepFinishTrack(value);
  }
}

/// 假播放控制器：无引擎、可编程 playing / trackId，记录暂停调用次数。
class _FakePlaybackNotifier extends PlaybackNotifier {
  int pauseCalls = 0;

  @override
  PlaybackState build() => const PlaybackState();

  void setPlaying(bool v) => state = state.copyWith(playing: v);

  void setTrackId(String? id) => state = state.copyWith(trackId: id);

  /// 模拟引擎在当前曲末帧收尾（睡眠定时到点原地暂停、不切下一曲）。
  void simulateTrackEndStop() {
    state = state.copyWith(
      playing: false,
      buffering: false,
      trackEndStopCount: state.trackEndStopCount + 1,
    );
  }

  @override
  void pause() {
    pauseCalls++;
    super.pause();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({ProviderContainer container, _FakePlaybackNotifier playback}) setup({
    bool finishTrack = true,
  }) {
    final fake = _FakePlaybackNotifier();
    final c = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _TestPrefs(AppPrefs().copyWithSleepFinishTrack(finishTrack)),
        ),
        playbackProvider.overrideWith(() => fake),
      ],
    );
    addTearDown(c.dispose);
    // 实例化 sleepTimerProvider，确保其监听已注册。
    c.read(sleepTimerProvider);
    return (container: c, playback: fake);
  }

  test('pause() 为显式暂停：已暂停时不翻转、播放中才暂停', () {
    final s = setup();
    final notifier = s.container.read(playbackProvider.notifier);

    // 已暂停：幂等，不产生副作用。
    notifier.pause();
    expect(s.playback.pauseCalls, 1);
    expect(s.container.read(playbackProvider).playing, isFalse);

    // 播放中：暂停（绝不像 toggle 那样反而恢复播放）。
    s.playback.setPlaying(true);
    notifier.pause();
    expect(s.playback.pauseCalls, 2);
    expect(s.container.read(playbackProvider).playing, isFalse);
  });

  test('到时「播完当前曲再暂停」：按曲尾时间停住，不等下一曲起播', () async {
    final s = setup(finishTrack: true);
    s.playback.setTrackId('a');
    s.playback.setPlaying(true);

    final timer = s.container.read(sleepTimerProvider.notifier);
    timer.startDuration(Duration.zero);
    // 等周期 ticker 触发（1s）。
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    // 进入等待态：已请求「曲尾原地暂停」，尚未暂停、也未切歌。
    expect(s.container.read(sleepTimerProvider).mode, SleepMode.endOfTrack);
    expect(s.playback.stopAtTrackEnd, isTrue);
    expect(s.playback.pauseCalls, 0);
    expect(s.container.read(playbackProvider).trackId, 'a');

    // 引擎在当前曲末帧收尾（原地暂停、不切下一曲）→ 定时复位。
    s.playback.simulateTrackEndStop();
    expect(s.container.read(playbackProvider).playing, isFalse);
    expect(s.container.read(sleepTimerProvider).active, isFalse);
    expect(s.playback.stopAtTrackEnd, isFalse);
  });

  test('手动「播完当前曲」置位曲尾暂停，取消即复位', () {
    final s = setup();
    final timer = s.container.read(sleepTimerProvider.notifier);

    timer.startEndOfTrack();
    expect(s.container.read(sleepTimerProvider).mode, SleepMode.endOfTrack);
    expect(s.playback.stopAtTrackEnd, isTrue);

    timer.cancel();
    expect(s.container.read(sleepTimerProvider).active, isFalse);
    expect(s.playback.stopAtTrackEnd, isFalse);
  });

  test('关闭开关：到时立即暂停', () async {
    final s = setup(finishTrack: false);
    s.playback.setTrackId('a');
    s.playback.setPlaying(true);

    s.container.read(sleepTimerProvider.notifier).startDuration(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(s.container.read(sleepTimerProvider).active, isFalse);
    expect(s.playback.pauseCalls, 1);
    expect(s.container.read(playbackProvider).playing, isFalse);
  });

  test('触发瞬间尚未出声（切歌/缓冲）：挂起待开始播放再暂停', () async {
    final s = setup(finishTrack: false);
    s.playback.setTrackId('a');
    s.playback.setPlaying(false); // 过渡态：本曲已结束、下曲尚未起播

    s.container.read(sleepTimerProvider.notifier).startDuration(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    // 尚未出声：不立即暂停，但定时已结束。
    expect(s.container.read(sleepTimerProvider).active, isFalse);
    expect(s.playback.pauseCalls, 0);

    // 下一曲真正开始播放 → 补一次暂停（旧实现此处会「暂停丢失」）。
    s.playback.setPlaying(true);
    expect(s.playback.pauseCalls, 1);
    expect(s.container.read(playbackProvider).playing, isFalse);
  });
}

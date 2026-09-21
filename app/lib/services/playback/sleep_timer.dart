// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 睡眠定时器：N 分钟后或「播完当前曲」自动暂停播放。
///
/// 会话级运行时状态（不落盘）：应用重启 / ProviderScope 释放即失效。
///
/// 倒计时到点有两种收尾方式（偏好 `player.sleepTimerFinishTrack`）：
/// - 开（默认）：切到「播完当前曲」等待态——按歌曲时间表在当前曲**自然
///   到达末帧**（引擎 `player:ended`）时原地暂停，**不续播下一曲**；
/// - 关：立即暂停。
///
/// ⚠ 暂停一律走 [PlaybackNotifier.pause]（显式暂停），绝不用 `toggle`：
/// 定时触发瞬间可能正处于切歌 / 缓冲过渡（`playing` 恰为 false），`toggle`
/// 会把「本应暂停」翻成恢复播放，表现为「定时无法暂停」。若触发时尚未出声，
/// 则挂起 [_pendingPause]，待真正开始播放的首帧再暂停，保证不丢动作。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../stores/app_prefs.dart';
import '../../widgets/common/toast.dart';
import 'playback_notifier.dart';

/// 睡眠模式：off 关闭 / duration 倒计时 / endOfTrack 播完当前曲。
enum SleepMode { off, duration, endOfTrack }

class SleepTimerState {
  const SleepTimerState({
    this.mode = SleepMode.off,
    this.remaining = Duration.zero,
  });

  final SleepMode mode;

  /// 倒计时剩余（仅 [SleepMode.duration] 有意义）。
  final Duration remaining;

  bool get active => mode != SleepMode.off;
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerNotifier, SleepTimerState>(
      SleepTimerNotifier.new,
    );

class SleepTimerNotifier extends Notifier<SleepTimerState> {
  Timer? _ticker;
  DateTime? _deadline;

  /// 触发瞬间尚未出声（切歌 / 缓冲）时挂起：待播放真正开始的首帧立即暂停。
  bool _pendingPause = false;

  @override
  SleepTimerState build() {
    ref.onDispose(() {
      _ticker?.cancel();
      _pendingPause = false;
    });
    // 「播完当前曲」收尾：播放器按歌曲时间表在曲尾**原地暂停**并递增
    // trackEndStopCount（不经过 trackId 变化，故下一曲不会起播）→ 复位等待态。
    ref.listen(playbackProvider.select((s) => s.trackEndStopCount), (
      prev,
      next,
    ) {
      if (state.mode != SleepMode.endOfTrack) return;
      if (prev == null || next == prev) return;
      _onStoppedAtTrackEnd();
    });
    // 挂起的暂停：切歌过渡结束、新曲真正开始播放时补一次暂停。
    ref.listen(playbackProvider.select((s) => s.playing), (prev, next) {
      if (!next || !_pendingPause) return;
      _pendingPause = false;
      ref.read(playbackProvider.notifier).pause();
    });
    return const SleepTimerState();
  }

  /// 启动倒计时（[d] 之后按偏好暂停）。
  void startDuration(Duration d) {
    _ticker?.cancel();
    _pendingPause = false;
    _setStopAtTrackEnd(false);
    _deadline = DateTime.now().add(d);
    state = SleepTimerState(mode: SleepMode.duration, remaining: d);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 播完当前曲后暂停。
  void startEndOfTrack() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    _pendingPause = false;
    _setStopAtTrackEnd(true);
    state = const SleepTimerState(mode: SleepMode.endOfTrack);
  }

  /// 取消睡眠定时。
  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    _pendingPause = false;
    _setStopAtTrackEnd(false);
    state = const SleepTimerState();
  }

  void _tick() {
    final dl = _deadline;
    if (dl == null) return;
    final left = dl.difference(DateTime.now());
    if (left <= Duration.zero) {
      _expire();
      return;
    }
    state = SleepTimerState(mode: SleepMode.duration, remaining: left);
  }

  /// 倒计时归零：按开关决定「等当前曲播完」还是「立即暂停」。
  void _expire() {
    final finish = ref.read(appPrefsProvider).sleepFinishTrack;
    if (finish && ref.read(playbackProvider).playing) {
      // 切到「播完当前曲」等待态：置位后播放器在曲尾原地暂停（不切下一曲）。
      _ticker?.cancel();
      _ticker = null;
      _deadline = null;
      _setStopAtTrackEnd(true);
      state = const SleepTimerState(mode: SleepMode.endOfTrack);
      toast(
        ref.read(l10nProvider).sleepTimerWaitingTrackEnd,
        type: ToastType.info,
      );
      return;
    }
    _fire();
  }

  /// 曲尾已按时间表停住：复位定时态并提示（播放器已完成暂停）。
  void _onStoppedAtTrackEnd() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    _pendingPause = false;
    _setStopAtTrackEnd(false);
    state = const SleepTimerState();
    toast(ref.read(l10nProvider).sleepTimerFired, type: ToastType.info);
  }

  void _fire() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    _setStopAtTrackEnd(false);
    state = const SleepTimerState();
    _requestPause();
    toast(ref.read(l10nProvider).sleepTimerFired, type: ToastType.info);
  }

  /// 请求暂停：已出声则立即暂停；尚未出声（切歌 / 缓冲过渡）则挂起，
  /// 等播放真正开始时补暂停，避免定时动作在过渡瞬间被丢掉。
  void _requestPause() {
    if (ref.read(playbackProvider).playing) {
      _pendingPause = false;
      ref.read(playbackProvider.notifier).pause();
      return;
    }
    _pendingPause = true;
  }

  /// 置位/复位播放器的「曲尾原地暂停」开关（仅写标志，无当前曲也安全）。
  void _setStopAtTrackEnd(bool value) {
    ref.read(playbackProvider.notifier).stopAtTrackEnd = value;
  }
}

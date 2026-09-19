// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 睡眠定时器：N 分钟后或「播完当前曲」自动暂停播放。
///
/// 会话级运行时状态（不落盘）：应用重启 / ProviderScope 释放即失效。
/// 「播完当前曲」通过监听曲目切换（trackId 变化）判定当前曲结束。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
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

  @override
  SleepTimerState build() {
    ref.onDispose(() => _ticker?.cancel());
    // 「播完当前曲」：trackId 变化即视为当前曲结束 → 暂停（停在下一曲开头）。
    ref.listen(playbackProvider.select((s) => s.trackId), (prev, next) {
      if (state.mode != SleepMode.endOfTrack) return;
      if (prev == null || next == null || prev == next) return;
      _fire();
    });
    return const SleepTimerState();
  }

  /// 启动倒计时（[d] 之后暂停）。
  void startDuration(Duration d) {
    _ticker?.cancel();
    _deadline = DateTime.now().add(d);
    state = SleepTimerState(mode: SleepMode.duration, remaining: d);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 播完当前曲后暂停。
  void startEndOfTrack() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    state = const SleepTimerState(mode: SleepMode.endOfTrack);
  }

  /// 取消睡眠定时。
  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    state = const SleepTimerState();
  }

  void _tick() {
    final dl = _deadline;
    if (dl == null) return;
    final left = dl.difference(DateTime.now());
    if (left <= Duration.zero) {
      _fire();
      return;
    }
    state = SleepTimerState(mode: SleepMode.duration, remaining: left);
  }

  void _fire() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
    state = const SleepTimerState();
    if (ref.read(playbackProvider).playing) {
      // 暂停（toggle 在播放中即暂停）。
      ref.read(playbackProvider.notifier).toggle();
    }
    toast(ref.read(l10nProvider).sleepTimerFired, type: ToastType.info);
  }
}

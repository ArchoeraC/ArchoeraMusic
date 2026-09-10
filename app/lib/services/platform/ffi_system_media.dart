// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemMedia 的 FFI 实现（能力位图含 MEDIA_SESSION 位时由工厂启用）。
library;

import 'dart:async';

import 'platform_bindings.dart';
import 'platform_failure.dart';
import 'system_media.dart';

class FfiSystemMedia implements SystemMedia {
  FfiSystemMedia(this._b) {
    _cmdSub = _b.commandEvents.listen((e) => _cmdCtrl.add(e));
    _seekSub = _b.seekEvents.listen((e) {
      if (e.relMs != 0) {
        _cmdCtrl.add(MediaSeekEvent(e.relMs));
      } else {
        _cmdCtrl.add(MediaSeekToEvent(e.absMs));
      }
    });
    _backendSub = _b.backendEvents.listen((e) {
      if (e.lost) {
        _failures.add(
          PlatformCapabilityFailure(
            capability: 'media',
            code: aplErrBackend,
            message: aplErrorMessage(aplErrBackend),
            lost: true,
          ),
        );
      }
    });
  }

  final PlatformBindings _b;

  late final StreamSubscription<MediaCommandEvent> _cmdSub;
  late final StreamSubscription<AplSeekEvent> _seekSub;
  late final StreamSubscription<AplBackendEvent> _backendSub;

  final _cmdCtrl = StreamController<MediaEvent>.broadcast();
  final _failures = StreamController<PlatformCapabilityFailure>.broadcast();

  @override
  Future<bool> setNowPlaying(NowPlayingTrack? track) async {
    return _b.setTrack(
          track?.title,
          track?.artist,
          track?.album,
          track?.durationMs,
          track?.artUrl,
        ) ==
        aplOk;
  }

  @override
  Future<bool> clearNowPlaying() async =>
      _b.setTrack(null, null, null, null, null) == aplOk;

  @override
  Future<bool> setPlaybackState(
    MediaPlaybackState state, {
    int positionMs = 0,
    double speed = 1.0,
    double? volume,
    bool? loopOne,
    bool? shuffle,
  }) async {
    if (volume != null) _volume = volume;
    if (loopOne != null) _loop = loopOne ? 1 : 0;
    if (shuffle != null) _shuffle = shuffle ? 1 : 0;
    return _b.setPlayback(
          state.index,
          positionMs,
          speed,
          _volume,
          _loop,
          _shuffle,
        ) ==
        aplOk;
  }

  /// MPRIS 属性缓存（随下一次 setPlaybackState 一并推送）。
  double _volume = 1.0;
  int _loop = 0;
  int _shuffle = 0;

  /// 关联顶层窗口句柄（Windows SMTC 必需；Linux/macOS 忽略）。
  Future<bool> setWindow(int window) async => _b.setWindow(window) == aplOk;

  @override
  Stream<MediaEvent> get commands => _cmdCtrl.stream;

  @override
  Stream<PlatformCapabilityFailure> get failures => _failures.stream;

  @override
  Future<void> dispose() async {
    await clearNowPlaying();
    await _cmdSub.cancel();
    await _seekSub.cancel();
    await _backendSub.cancel();
    await _cmdCtrl.close();
    await _failures.close();
  }
}

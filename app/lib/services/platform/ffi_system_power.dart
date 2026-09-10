// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemPower 的 FFI 实现（能力位图含 POWER_* 位时由工厂启用）。
library;

import 'dart:async';

import 'platform_bindings.dart';
import 'platform_failure.dart';
import 'system_power.dart';

class FfiSystemPower implements SystemPower {
  FfiSystemPower(this._b) {
    _screenSub = _b.screenEvents.listen((e) => _screenCtrl.add(e.active));
    _backendSub = _b.backendEvents.listen((e) {
      if (e.lost) {
        _failures.add(PlatformCapabilityFailure(
          capability: 'power',
          code: aplErrBackend,
          message: aplErrorMessage(aplErrBackend),
          lost: true,
        ));
      }
    });
  }

  final PlatformBindings _b;

  late final StreamSubscription<AplScreenEvent> _screenSub;
  late final StreamSubscription<AplBackendEvent> _backendSub;

  final _screenCtrl = StreamController<bool>.broadcast();
  final _failures = StreamController<PlatformCapabilityFailure>.broadcast();

  @override
  Future<bool> setSleepInhibit(bool on, {String reason = 'playback'}) async {
    return _b.setSleepInhibit(on) == aplOk;
  }

  @override
  Stream<bool> get screenState => _screenCtrl.stream;

  @override
  Stream<PlatformCapabilityFailure> get failures => _failures.stream;

  @override
  Future<bool> setScreenEvents(bool on) async => _b.setScreenEvents(on) == aplOk;

  @override
  Future<void> dispose() async {
    _b.setScreenEvents(false);
    _b.setSleepInhibit(false);
    await _screenSub.cancel();
    await _backendSub.cancel();
    await _screenCtrl.close();
    await _failures.close();
  }
}

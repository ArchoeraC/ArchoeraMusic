// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemWindow 的 FFI 实现（能力位图含 WINDOW_STATE 位时由工厂启用；
/// 纯 Wayland 等场景位图不含该位 → Noop 回退 window_manager）。
library;

import 'dart:async';

import 'platform_bindings.dart';
import 'platform_failure.dart';
import 'system_window.dart';

class FfiSystemWindow implements SystemWindow {
  FfiSystemWindow(this._b) {
    _winSub = _b.windowEvents.listen((e) {
      final snap = SystemWindowState(minimized: e.minimized, focused: e.focused);
      _state = snap;
      _stateCtrl.add(snap);
    });
    _backendSub = _b.backendEvents.listen((e) {
      if (e.lost) {
        _failures.add(PlatformCapabilityFailure(
          capability: 'window',
          code: aplErrBackend,
          message: aplErrorMessage(aplErrBackend),
          lost: true,
        ));
      }
    });
  }

  final PlatformBindings _b;

  late final StreamSubscription<AplWindowEvent> _winSub;
  late final StreamSubscription<AplBackendEvent> _backendSub;

  final _stateCtrl = StreamController<SystemWindowState>.broadcast();
  final _failures = StreamController<PlatformCapabilityFailure>.broadcast();

  SystemWindowState _state =
      const SystemWindowState(minimized: false, focused: true);

  @override
  Future<bool> setEvents(bool on) async => _b.setWindowEvents(on) == aplOk;

  @override
  Stream<SystemWindowState> get state => _stateCtrl.stream;

  /// 最近一次已知状态（新订阅者可用作初值；桥接事件到达前为前台默认值）。
  SystemWindowState get current => _state;

  @override
  Stream<PlatformCapabilityFailure> get failures => _failures.stream;

  @override
  Future<void> dispose() async {
    _b.setWindowEvents(false);
    await _winSub.cancel();
    await _backendSub.cancel();
    await _stateCtrl.close();
    await _failures.close();
  }
}

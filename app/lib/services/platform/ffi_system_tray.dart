// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemTray 的 FFI 实现（能力位图含 TRAY 位时由工厂启用）。
library;

import 'dart:async';

import 'platform_bindings.dart';
import 'platform_failure.dart';
import 'system_tray.dart';

class FfiSystemTray implements SystemTray {
  FfiSystemTray(this._b) {
    _clickSub = _b.trayClickEvents.listen((_) => _clicks.add(null));
    _doubleSub = _b.trayDoubleClickEvents.listen((_) => _doubleClicks.add(null));
    _rightSub = _b.trayRightClickEvents.listen((_) => _rightClicks.add(null));
    _menuSub = _b.trayMenuEvents.listen((e) => _menuCommands.add(e.id));
    _backendSub = _b.backendEvents.listen((e) {
      if (e.lost) {
        _failures.add(
          PlatformCapabilityFailure(
            capability: 'tray',
            code: aplErrBackend,
            message: aplErrorMessage(aplErrBackend),
            lost: true,
          ),
        );
      }
    });
  }

  final PlatformBindings _b;

  late final StreamSubscription<AplTrayClickEvent> _clickSub;
  late final StreamSubscription<AplTrayDoubleClickEvent> _doubleSub;
  late final StreamSubscription<AplTrayRightClickEvent> _rightSub;
  late final StreamSubscription<AplTrayMenuCommandEvent> _menuSub;
  late final StreamSubscription<AplBackendEvent> _backendSub;

  final _clicks = StreamController<void>.broadcast();
  final _doubleClicks = StreamController<void>.broadcast();
  final _rightClicks = StreamController<void>.broadcast();
  final _menuCommands = StreamController<int>.broadcast();
  final _failures = StreamController<PlatformCapabilityFailure>.broadcast();

  @override
  int create(String iconPath) => _b.trayCreate(iconPath);

  @override
  int destroy() => _b.trayDestroy();

  @override
  int setIcon(String iconPath) => _b.traySetIcon(iconPath);

  @override
  int setTooltip(String tooltip) => _b.traySetTooltip(tooltip);

  @override
  int setVisible(bool visible) => _b.traySetVisible(visible);

  @override
  int setMenu(List<SystemTrayMenuItem> items) => _b.traySetMenu([
        for (final it in items)
          AplTrayMenuItem(
            id: it.id,
            label: it.label,
            enabled: it.enabled,
            checked: it.checked,
          ),
      ]);

  @override
  int setMenuTrigger(bool leftClick) => _b.traySetMenuTrigger(leftClick);

  @override
  Stream<void> get clicks => _clicks.stream;

  @override
  Stream<void> get doubleClicks => _doubleClicks.stream;

  @override
  Stream<void> get rightClicks => _rightClicks.stream;

  @override
  Stream<int> get menuCommands => _menuCommands.stream;

  @override
  Stream<PlatformCapabilityFailure> get failures => _failures.stream;

  @override
  Future<void> dispose() async {
    _b.trayDestroy();
    await _clickSub.cancel();
    await _doubleSub.cancel();
    await _rightSub.cancel();
    await _menuSub.cancel();
    await _backendSub.cancel();
    await _clicks.close();
    await _doubleClicks.close();
    await _rightClicks.close();
    await _menuCommands.close();
    await _failures.close();
  }
}

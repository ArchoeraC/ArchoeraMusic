// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemOsSession 的 FFI 实现（能力位含 OS_SESSION 且原生符号存在时启用）。
library;

import 'platform_bindings.dart';
import 'system_os.dart';

class FfiSystemOsSession implements SystemOsSession {
  FfiSystemOsSession(this._b);

  final PlatformBindings _b;

  @override
  bool get available => _b.osSessionSymbolsAvailable;

  @override
  int setEvents(bool on) => _b.osSetEvents(on);

  @override
  int setBrightness(int percent) => _b.osSetBrightness(percent);

  @override
  int setVolume(int percent) => _b.osSetVolume(percent);

  @override
  int setScreenEnabled(bool on) => _b.osSetScreenEnabled(on);

  @override
  int powerOff() => _b.osPowerOff();

  @override
  int reboot() => _b.osReboot();

  @override
  int suspend() => _b.osSuspend();

  @override
  int hibernate() => _b.osHibernate();

  @override
  int setOutputScale(int scaleMilli) => _b.osSetOutputScale(scaleMilli);

  @override
  int setOutputMode(int width, int height) => _b.osSetOutputMode(width, height);

  @override
  int setOutputTransform(int transform) => _b.osSetOutputTransform(transform);

  @override
  List<OsDisplayOutput> displayOutputs() => _b.osDisplayOutputs();

  @override
  int setDisplayOutputMode(int outputId, int index) =>
      _b.osSetDisplayOutputMode(outputId, index);

  @override
  int setDisplayOutputScale(int outputId, int scaleMilli) =>
      _b.osSetDisplayOutputScale(outputId, scaleMilli);

  @override
  int setDisplayOutputTransform(int outputId, int transform) =>
      _b.osSetDisplayOutputTransform(outputId, transform);

  @override
  int key(int keycode, int state) => _b.osKey(keycode, state);

  @override
  Stream<int> get capabilities => _b.osCapabilitiesEvents.map((e) => e.caps);

  @override
  Stream<int> get brightness => _b.osBrightnessEvents.map((e) => e.percent);

  @override
  Stream<int> get volume => _b.osVolumeEvents.map((e) => e.percent);

  @override
  Stream<OsBatteryState> get battery => _b.osBatteryEvents.map(
    (e) => OsBatteryState(
      present: e.present,
      percent: e.percent,
      charging: e.charging,
    ),
  );

  @override
  Stream<OsSessionState> get session =>
      _b.osSessionEvents.map((e) => _sessionFromNative(e.state));

  @override
  Stream<bool> get screenEnabled => _b.osScreenEvents.map((e) => e.enabled);

  @override
  Stream<OsPowerKey> get powerKey =>
      _b.osPowerKeyEvents.map((e) => _powerKeyFromNative(e.key));

  @override
  Stream<OsOutputState> get output => _b.osOutputEvents.map(
    (e) => OsOutputState(
      width: e.width,
      height: e.height,
      scaleMilli: e.scaleMilli,
      transform: e.transform,
      refreshMillihz: e.refreshMillihz,
    ),
  );

  static OsSessionState _sessionFromNative(int raw) => switch (raw) {
    2 => OsSessionState.shuttingDown,
    3 => OsSessionState.suspending,
    _ => OsSessionState.ready,
  };

  static OsPowerKey _powerKeyFromNative(int raw) => switch (raw) {
    1 => OsPowerKey.sleep,
    2 => OsPowerKey.suspend,
    _ => OsPowerKey.power,
  };
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemStatus 的 FFI 实现（能力位含 SYS_STATS / BLUETOOTH 时启用）。
library;

import 'platform_bindings.dart';
import 'system_status.dart';

class FfiSystemStatus implements SystemStatus {
  FfiSystemStatus(this._b);

  final PlatformBindings _b;

  @override
  bool get statsAvailable => _b.sysStatsSymbolsAvailable;

  @override
  bool get bluetoothAvailable => _b.bluetoothSymbolsAvailable;

  @override
  SysStats? stats() => _b.sysStats();

  @override
  BluetoothState? bluetooth() => _b.bluetoothState();
}

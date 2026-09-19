// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemDeepLink 的 FFI 实现：订阅桥接 deep link 信号并即时取回 URI。
library;

import 'dart:async';

import 'platform_bindings.dart';
import 'platform_failure.dart';
import 'system_deep_link.dart';

class FfiSystemDeepLink implements SystemDeepLink {
  FfiSystemDeepLink(this._b) {
    _sub = _b.deepLinkEvents.listen((_) => _drain());
    // 冷启动：apl_init 已把命令行 URI 存入桥接缓冲，这里立即取。
    _drain();
  }

  final PlatformBindings _b;
  StreamSubscription<AplDeepLinkEvent>? _sub;
  final _ctrl = StreamController<Uri>.broadcast();
  final _failCtrl = StreamController<PlatformCapabilityFailure>.broadcast();
  bool _disposed = false;

  /// 取空桥接缓冲中的所有待处理 URI（事件仅作信号，URI 另行取回）。
  void _drain() {
    if (_disposed) return;
    while (true) {
      final raw = _b.deepLinkTake();
      if (raw == null) break;
      final uri = Uri.tryParse(raw);
      if (uri != null && !_ctrl.isClosed) _ctrl.add(uri);
    }
  }

  @override
  Stream<Uri> get uris => _ctrl.stream;

  @override
  Stream<PlatformCapabilityFailure> get failures => _failCtrl.stream;

  @override
  Future<bool> register(String scheme) async =>
      _b.protocolRegister(scheme) == aplOk;

  @override
  Future<void> unregister(String scheme) async {
    _b.protocolUnregister(scheme);
  }

  @override
  Future<void> activateWindow() async {
    _b.activateWindow();
  }

  @override
  Future<int> forward() async => _b.deepLinkForward();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    await _ctrl.close();
    await _failCtrl.close();
  }
}

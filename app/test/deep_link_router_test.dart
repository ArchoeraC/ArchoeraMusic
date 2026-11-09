// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 深链路由回归：
/// - 启动期（`markReady` 之前）到达的 `archoera://` 先缓冲；
/// - 已移除的 `nekomusic://` 登录回调不再被派发（未知 scheme 一律忽略）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/deeplink/deep_link_router.dart';
import 'package:archoera_music/services/platform/platform_failure.dart';
import 'package:archoera_music/services/platform/system_deep_link.dart';

class _FakeDeepLink implements SystemDeepLink {
  final _uris = StreamController<Uri>.broadcast();

  int activated = 0;

  void emit(Uri uri) => _uris.add(uri);

  @override
  Stream<Uri> get uris => _uris.stream;

  @override
  Stream<PlatformCapabilityFailure> get failures => const Stream.empty();

  @override
  Future<bool> register(String scheme) async => true;

  @override
  Future<void> unregister(String scheme) async {}

  @override
  Future<void> activateWindow() async {
    activated += 1;
  }

  @override
  Future<int> forward() async => 0;

  @override
  Future<void> dispose() async {
    await _uris.close();
  }
}

void main() {
  test('markReady 之前收到 archoera:// 保持缓冲', () async {
    final fake = _FakeDeepLink();
    addTearDown(fake.dispose);
    final router = DeepLinkRouter(fake);
    addTearDown(router.dispose);
    router.start();

    fake.emit(Uri.parse('archoera://player'));
    await Future<void>.delayed(Duration.zero);
    expect(fake.activated, 0, reason: '启动完成前不派发页面路由');
  });

  test('nekomusic:// 登录回调已移除：不置前窗口、不派发', () async {
    final fake = _FakeDeepLink();
    addTearDown(fake.dispose);
    final router = DeepLinkRouter(fake);
    addTearDown(router.dispose);
    router.start();
    router.markReady();

    fake.emit(Uri.parse('nekomusic://sso/complete?handoff=stale'));
    await Future<void>.delayed(Duration.zero);
    expect(fake.activated, 0);
  });

  test('启动前缓冲的未知 scheme 在 markReady 后安全丢弃', () async {
    final fake = _FakeDeepLink();
    addTearDown(fake.dispose);
    final router = DeepLinkRouter(fake);
    addTearDown(router.dispose);
    router.start();

    fake.emit(Uri.parse('nekomusic://sso/complete?handoff=early'));
    await Future<void>.delayed(Duration.zero);
    expect(fake.activated, 0);

    router.markReady();
    await Future<void>.delayed(Duration.zero);
    expect(fake.activated, 0);
  });
}

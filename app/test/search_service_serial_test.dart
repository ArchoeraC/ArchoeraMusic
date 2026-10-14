// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 构建门串行化回归（`SearchService`，纯 Dart 编排；不触碰 FFI / search.db）。
//
// 覆盖要求：
//   - 并发 rebuild + reindex：严格串行、**不重叠**（同一 `search.db` 上并发
//     `indexer_run` 会互相破坏）；
//   - rebuild 与 search→ensureIndex 串行；
//   - deleteIndex 不与构建并发（构建结束前不得动 `search.db`）；
//   - search 在构建中不抛异常（回退 LIKE 返回 null）；
//   - dispose 后不再触达构建 / 查询。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_service.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 让已排队的微任务跑完（**不是** sleep 轮询）：显式让出事件循环，
/// 使任何（错误地）并发的关键段有机会执行，从而暴露重叠。
Future<void> _drainMicrotasks() => Future<void>.value();

/// 「可控构建执行器」：记录进入次数 / 峰值并发，并阻塞在 [release] 上。
/// 测试可在第一个关键段进行中触发第二个入口，验证是否发生重叠。
class _ControlledExecutor {
  _ControlledExecutor(this.service) {
    service.debugBuildExecutor = ({required bool full}) async {
      count++;
      active++;
      if (active > peak) peak = active;
      if (!started.isCompleted) started.complete();
      await release.future;
      active--;
      return null;
    };
  }

  final SearchService service;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int count = 0;
  int peak = 0;
  int active = 0;
}

void main() {
  final service = SearchService.instance;

  setUp(() {
    service.debugReset();
    appPrefsSnapshot = null;
    SearchService.debugSearchDbPathOverride = null;
  });

  tearDown(() {
    service.debugReset();
    appPrefsSnapshot = null;
    SearchService.debugSearchDbPathOverride = null;
  });

  test('并发 rebuild + reindex：严格串行、不重叠（后到者排队）', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    final ex = _ControlledExecutor(service);

    final first = service.rebuild();
    final second = service.reindex();

    // 第一个关键段已进入并在 release 上阻塞；第二个必须排队等待。
    await ex.started.future;
    ex.release.complete();
    await Future.wait<void>([first, second]);

    expect(ex.count, 2, reason: '两个请求都应执行（排队而非丢弃）');
    expect(ex.peak, 1, reason: '构建关键段不得重叠');
  });

  test('rebuild 与 search→ensureIndex：串行、不重叠', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    final ex = _ControlledExecutor(service);

    final rebuildFuture = service.rebuild();
    await ex.started.future;
    // 构建门被占用：search 不排队阻塞，直接回退 LIKE。
    expect(await service.search('周杰伦'), isNull);
    final ensureFuture = service.ensureIndex();

    ex.release.complete();
    await rebuildFuture;
    await ensureFuture;

    expect(ex.peak, 1, reason: 'ensureIndex 与 rebuild 不得并发');
  });

  test('deleteIndex 与构建不冲突：构建结束前不删除 search.db', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    final tmp = await Directory.systemTemp.createTemp('search_gate_delete');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dbPath = '${tmp.path}/search.db';
    SearchService.debugSearchDbPathOverride = dbPath;
    File(dbPath).writeAsStringSync('stub');

    final ex = _ControlledExecutor(service);
    final buildFuture = service.rebuild();
    await ex.started.future;

    final deleteFuture = service.deleteIndex();
    await _drainMicrotasks();
    expect(
      File(dbPath).existsSync(),
      isTrue,
      reason: '构建未结束时 deleteIndex 不得运行（避免并发删写）',
    );

    ex.release.complete();
    await Future.wait<void>([buildFuture, deleteFuture]);
    expect(File(dbPath).existsSync(), isFalse, reason: '构建结束后再删除');
  });

  test('search 在构建中不抛异常（回退 LIKE 返回 null）', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    final ex = _ControlledExecutor(service);

    final buildFuture = service.rebuild();
    await ex.started.future;

    // 总开关开启 + 构建进行中：search 必须安全降级（不抛到 UI）。
    expect(await service.search('周杰伦'), isNull);
    expect(await service.search(' hello '), isNull);

    ex.release.complete();
    await buildFuture;
  });

  test('总开关关闭：构建门空闲也立即回退 null（不构建）', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: false});
    var calls = 0;
    service.debugBuildExecutor = ({required bool full}) async {
      calls++;
      return null;
    };
    expect(await service.search('周杰伦'), isNull);
    await service.rebuild();
    await service.reindex();
    expect(calls, 0, reason: '总开关关闭：零成本，不触达构建');
  });

  test('dispose 后不再触达构建 / 查询', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    var calls = 0;
    service.debugBuildExecutor = ({required bool full}) async {
      calls++;
      return null;
    };

    await service.rebuild();
    expect(calls, 1);

    service.dispose();

    await service.rebuild();
    await service.reindex();
    await service.deleteIndex();
    expect(await service.search('周杰伦'), isNull);

    expect(calls, 1, reason: 'dispose 后不得再启动任何构建');
    expect(service.status.isDisabled, isTrue);
  });
}

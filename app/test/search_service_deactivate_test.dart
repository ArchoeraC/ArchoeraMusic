// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// `SearchService.deactivate()`（总开关 开→关）语义回归：
//   - **取消在途构建**（走 `cancel()` / `indexer_cancel`，经测试接缝观测）；
//   - 在途构建段 await 后因 `!enabled` **不重开连接**，状态回到 disabled；
//   - 不破坏串行门：取消只是信号，排队的关键段仍串行、不并发，且因总开关已关
//     而早退（不再触达构建）。
//
// 纯 Dart 编排：不触碰 FFI / search.db（`debugBuildExecutor` / `debugCancelOverride`
// 双接缝）。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_models.dart';
import 'package:archoera_music/services/search/search_service.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 可控构建执行器：阻塞在 [release] 上，记录进入次数 / 峰值并发。
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

  test('deactivate：取消在途构建，构建段 await 后不重开、状态归 disabled', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    var cancelCalls = 0;
    service.debugCancelOverride = () {
      cancelCalls++;
      return true;
    };
    final ex = _ControlledExecutor(service);

    final buildFuture = service.ensureIndex();
    await ex.started.future;

    // 模拟设置页：先写偏好关闭，再 deactivate。
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: false});
    service.deactivate();

    expect(cancelCalls, 1, reason: 'deactivate 应请求取消在途构建');
    expect(service.status.isDisabled, isTrue, reason: '立即回到 disabled');

    ex.release.complete();
    await buildFuture;

    expect(service.status.isDisabled, isTrue, reason: '构建段结束后不得复活连接');
    expect(ex.count, 1);
  });

  test('deactivate：取消不绕过构建门（排队的关键段串行且早退）', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    var cancelCalls = 0;
    service.debugCancelOverride = () {
      cancelCalls++;
      return true;
    };
    final ex = _ControlledExecutor(service);

    final first = service.ensureIndex();
    await ex.started.future;
    // 门被占用时排入第二个关键段（reindex）——它必须等待而非并发。
    final second = service.reindex();

    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: false});
    service.deactivate();
    expect(cancelCalls, 1);

    ex.release.complete();
    await Future.wait<void>([first, second]);

    expect(ex.peak, 1, reason: '取消不得造成并发（门语义不变）');
    expect(
      ex.count,
      1,
      reason: '总开关已关：排队的 reindex 关键段早退，不触达构建',
    );
    expect(service.status.isDisabled, isTrue);
  });

  test('deactivate：无在途构建也安全（cancel no-op，关闭连接、状态 disabled）', () {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    var cancelCalls = 0;
    service.debugCancelOverride = () {
      cancelCalls++;
      return false; // 无进行中构建
    };

    service.deactivate();

    expect(cancelCalls, 1);
    expect(service.status, LocalSearchStatus.disabled);
  });
}

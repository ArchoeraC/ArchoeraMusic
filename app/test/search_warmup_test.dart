// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// `SearchService.warmUpOnStartup()`（应用启动后台预构建）门控 / 幂等回归：
//   - 总开关关闭：不触发构建、不触碰 search.db（零成本）；
//   - 总开关开启：触发一次 `ensureIndex`（经测试接缝，不触碰真实 FFI）；
//   - 幂等：重复 / 并发触发只生效一次。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_service.dart';
import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  final service = SearchService.instance;
  late Directory tmp;
  late String dbPath;

  setUp(() {
    service.debugReset();
    appPrefsSnapshot = null;
    tmp = Directory.systemTemp.createTempSync('search_warmup');
    dbPath = '${tmp.path}/search.db'; // 不存在 → 需要全量构建。
    SearchService.debugSearchDbPathOverride = dbPath;
  });

  tearDown(() {
    service.debugReset();
    appPrefsSnapshot = null;
    SearchService.debugSearchDbPathOverride = null;
    tmp.deleteSync(recursive: true);
  });

  test('总开关关闭：不触发构建、不触碰 search.db', () async {
    var calls = 0;
    service.debugBuildExecutor = ({required bool full}) async {
      calls++;
      return null;
    };
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: false});

    await service.warmUpOnStartup();
    await service.warmUpOnStartup();

    expect(calls, 0, reason: '关闭态零成本：不加载模块 / 不建库');
    expect(File(dbPath).existsSync(), isFalse, reason: '关闭态不得创建 search.db');
  });

  test('快照缺失：同样不触发（默认关）', () async {
    var calls = 0;
    service.debugBuildExecutor = ({required bool full}) async {
      calls++;
      return null;
    };
    appPrefsSnapshot = null;

    await service.warmUpOnStartup();

    expect(calls, 0);
  });

  test('总开关开启：触发一次 ensureIndex 且幂等', () async {
    var calls = 0;
    service.debugBuildExecutor = ({required bool full}) async {
      calls++;
      return null; // 测试接缝：不触碰真实 FFI / search.db 内容
    };
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});

    await service.warmUpOnStartup();
    expect(calls, 1, reason: '开启态后台触发一次预构建');

    // 再次触发（如壳层重建 / 重入）不得重复构建。
    await service.warmUpOnStartup();
    expect(calls, 1, reason: '幂等：重复触发被门控吸收');
  });

  test('并发触发只生效一次（同步置位幂等门）', () async {
    var calls = 0;
    service.debugBuildExecutor = ({required bool full}) async {
      calls++;
      return null;
    };
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});

    await Future.wait<void>([
      service.warmUpOnStartup(),
      service.warmUpOnStartup(),
    ]);

    expect(calls, 1);
  });
}

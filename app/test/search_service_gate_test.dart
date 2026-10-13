// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/search_models.dart';
import 'package:archoera_music/services/search/search_service.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 总开关门控：**关闭时不加载 indexer / 不触碰 search.db**，搜索返回 null
/// （调用方回退 `LIKE`）。这里不提供真实 indexer，仅验证门控短路。
void main() {
  setUp(() => appPrefsSnapshot = null);
  tearDown(() {
    appPrefsSnapshot = null;
    SearchService.instance.debugReindexOverride = null;
  });

  test('快照缺失 / 总开关关：enabled=false，search 返回 null（回退 LIKE）', () async {
    final service = SearchService.instance;
    expect(service.enabled, isFalse);
    expect(await service.search('周杰伦'), isNull);

    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: false});
    expect(service.enabled, isFalse);
    expect(await service.search('周杰伦'), isNull);
  });

  test('空查询：即使总开关开启也返回 null（等于原列表）', () async {
    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    final service = SearchService.instance;
    expect(service.enabled, isTrue);
    // 空 / 纯空白在门控处短路，不触碰模块 / search.db。
    expect(await service.search(''), isNull);
    expect(await service.search('   '), isNull);
  });

  test('增量重建：总开关关 → no-op（不加载模块 / 不抛异常）', () async {
    final service = SearchService.instance;
    expect(service.enabled, isFalse);
    await service.reindex();
    expect(service.status, LocalSearchStatus.disabled);

    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: false});
    await service.reindex();
    expect(service.status, LocalSearchStatus.disabled);
  });

  test('增量重建：测试接缝直通（不触碰 FFI / search.db）', () async {
    var calls = 0;
    SearchService.instance.debugReindexOverride = () async {
      calls++;
    };
    await SearchService.instance.reindex();
    expect(calls, 1);
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 索引构建的**子 isolate 传输**回归。
//
// 背景：构建必须在子 isolate 里跑阻塞的 `indexer_run`。`Isolate.run` 发送的是
// 「闭包 + 其上下文」的深拷贝；调用方 `SearchService` 持有 `_gateTail`（`Future`，
// **不可发送**）等现场。若 isolate 入口写在实例方法内（尤其同函数里还有
// `NativeCallable.listener(某实例方法)` 这类 tear-off），`this` 就会进入闭包上下文
// 被一并发送，发送**立即**失败：
//   `Illegal argument in isolate message: object is unsendable`
// 症状是构建永远起不来、日志反复刷这条异常（索引服务因此完全失效）。
// 故 isolate 入口必须落在**静态**函数里：`IndexerLibrary.runInIsolate`
//（见 `lib/services/search/indexer_ffi.dart` 该方法的注释）。
//
// 覆盖：
//   1) 消息可发送性 —— 传**不存在的**库路径：失败必须发生在子 isolate 内部
//      （加载动态库失败），而非 isolate 消息发送阶段。不依赖任何原生产物。
//   2) 真实构建路径 —— `SearchService.ensureIndex()` 走真实 indexer：失败原因
//      必须来自 indexer 自身（源曲库不存在），而不是 isolate 传输。
//      （需要 indexer 产物：本地未构建时跳过。）

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/search/indexer_ffi.dart';
import 'package:archoera_music/services/search/search_service.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// isolate 消息不可发送的报错特征（回归判定）。
const String _unsendableMarker = 'unsendable';

/// indexer 产物路径；未构建（如 CI 无原生模块）时返回 null → 真实路径用例跳过。
String? _realIndexerSoPath() {
  try {
    return IndexerLibrary.resolveSoPath();
  } catch (_) {
    return null;
  }
}

void main() {
  final realSoPath = _realIndexerSoPath();

  test('isolate 入口：消息可发送（不连带捕获调用方现场）', () async {
    final tmp = await Directory.systemTemp.createTemp('search_isolate_send');
    addTearDown(() => tmp.deleteSync(recursive: true));

    Object? error;
    try {
      await IndexerLibrary.runInIsolate(
        soPath: '${tmp.path}/no-such-indexer-ffi.so',
        dbPath: '${tmp.path}/library.db',
        indexPath: '${tmp.path}/search.db',
        full: true,
        optionsJson: '{"pinyin":true}',
        onProgress: nullptr.cast<Void>(),
      );
    } catch (err) {
      error = err;
    }

    // 消息已送达子 isolate：失败来自库加载，而非发送阶段。
    expect(error, isNotNull, reason: '库不存在，必须在子 isolate 内加载失败');
    final text = '$error';
    expect(
      text,
      isNot(contains('Illegal argument in isolate message')),
      reason: 'isolate 消息不得含不可发送对象（曾因连带捕获实例现场而必然失败）',
    );
    expect(text, isNot(contains(_unsendableMarker)));
    expect(
      text,
      contains('indexer-ffi.so'),
      reason: '失败应指向真实加载错误（证明子 isolate 确实执行）',
    );
  });

  test('真实构建路径：失败原因来自 indexer 本身（而非 isolate 传输）', () async {
    final tmp = await Directory.systemTemp.createTemp('search_isolate_real');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final service = SearchService.instance;
    addTearDown(() {
      service.debugReset();
      appPrefsSnapshot = null;
    });

    appPrefsSnapshot = AppPrefs(initialData: {enableLocalSearchIndexKey: true});
    SearchService.debugSearchDbPathOverride = '${tmp.path}/search.db';
    // 源库不存在：indexer 立即报错退出（不索引真实曲库、不写真实 search.db）。
    SearchService.debugLibraryDbPathOverride = '${tmp.path}/library.db';

    final index = await service.ensureIndex();

    expect(index, isNull, reason: '源曲库缺失：构建失败');
    expect(service.status.isError, isTrue);
    expect(
      service.status.message,
      contains('library.db'),
      reason: '状态须反映 indexer 的具体失败原因（源曲库不存在）',
    );
    expect(
      service.status.message,
      isNot(contains(_unsendableMarker)),
      reason: '不得因 isolate 消息不可发送而失败',
    );
  }, skip: realSoPath == null ? '缺少 indexer-ffi 产物（本地未构建）' : null);
}

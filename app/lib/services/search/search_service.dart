// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import '../../stores/app_prefs.dart';
import '../log/log.dart';
import '../scanner/library_scanner.dart';
import 'indexer_ffi.dart';
import 'search_index.dart';
import 'search_models.dart';

/// 本地曲库搜索索引服务（单例编排器，**总开关门控**）。
///
/// 设计文档 `docs/local-search-index-plan.md` §2.4 / §9.3：
///   - 总开关 `enableLocalSearchIndex` **默认关**；关闭时**不解析 / 不加载**
///     indexer 模块、**不建库**、**不查询**，[search] 直接返回 null（调用方
///     回退现有 `LIKE`），零成本；
///   - 开启时按需加载 indexer（NativeAOT 常驻、不 unload），`search.db` 缺失或
///     schema 版本不符时在**后台 isolate** 跑 `indexer_run`（全量 / 增量），
///     完成后以只读连接打开 [SearchIndex]；
///   - 任何失败（模块缺失 / 构建失败 / 查询异常）都降级为返回 null，**绝不抛到
///     UI**（索引是派生数据，可随时重建）。
///
/// **构建串行化（build gate）**：`rebuild` / `reindex` / `deleteIndex` 以及
/// [ensureIndex] 的「构建 + 重开」关键段都是**互斥**的——全部经单一异步门
/// [_serialize] 排队，后到者等待而非并发执行。并发调用 NativeAOT `indexer_run`
/// （同一 `search.db` / `-wal` / `-shm`）会互相破坏，故必须串行。
/// 该门只是 Dart 侧 `Future` 链式串行（不是内核等待式竞态判定），门内**绝不**
/// 调用会再次取门的公开方法，避免自锁。
///
/// 路径：`search.db` = `<数据目录>/database/search.db`；`library.db` 走
/// [LibraryScanner.defaultDbPath]（与 scanner 同一真值库）。
class SearchService {
  SearchService._();

  /// 全局单例（进程内一个 indexer 句柄 / 一份只读连接）。
  static final SearchService instance = SearchService._();

  /// `search.db` 缺省路径（与 `library.db` 同目录）。
  static String defaultSearchDbPath() {
    final override = debugSearchDbPathOverride;
    if (override != null && override.isNotEmpty) return override;
    return '${LibraryScanner.defaultDataDir()}/database/search.db';
  }

  /// 测试接缝：非空时覆盖 [defaultSearchDbPath]（让单测不触碰真实数据目录）。
  @visibleForTesting
  static String? debugSearchDbPathOverride;

  /// 构建进度（主 isolate 消费；无进行中构建时为 null）。
  ///
  /// 非 `final`：便于测试重置（见 [debugReset]）后重新绑定监听。生产代码
  /// 只读访问，不重新赋值。
  ValueNotifier<IndexerProgress?> progress =
      ValueNotifier<IndexerProgress?>(null);

  IndexerLibrary? _lib;
  String? _soPath;
  SearchIndex? _index;
  bool _disposed = false;
  bool _progressDisposed = false;

  // ------------------------------------------------------- 构建门（build gate）

  /// 门尾：所有经门的关键段串行链在其后。**永不携带错误**（见 [_serialize]）。
  Future<void> _gateTail = Future<void>.value();

  /// 门内「已排队 + 执行中」的关键段数量。>0 即门被占用（构建/重开/删除）。
  int _gateOccupancy = 0;

  bool get _gateBusy => _gateOccupancy > 0;

  /// 把 [action] 排入构建门，严格串行执行并返回其结果。
  ///
  /// FIFO：后到者链在前一关键段完成之后；**不并发、不丢弃**。
  /// [action] **不得**调用任何会再次取门的公开方法（否则自锁）——内部关键段
  /// （`_buildAndOpenLocked` / 删除逻辑）只使用无门私有原语。
  Future<T> _serialize<T>(Future<T> Function() action) {
    _gateOccupancy++;
    final previous = _gateTail;
    final result = previous.then((_) => action());
    // 门尾吞掉错误：门链本身不会因单段失败而断裂；占用计数在段结束后回落。
    _gateTail = result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      _gateOccupancy--;
    });
    return result;
  }

  /// 测试接缝：非空时 [reindex] 直接委托之（**不触碰 FFI / search.db**）。
  ///
  /// 单测用它验证「`.lrc` 子开关切换 → 触发增量重建」的接线，避免真实原生调用。
  @visibleForTesting
  Future<void> Function()? debugReindexOverride;

  /// 测试接缝：非空时替代 [ensureIndex] / [rebuild] / [reindex] 的**真实构建 +
  /// 开库**关键段（仍在构建门内被调用，故可用于验证串行化）。返回就绪索引
  /// （测试可返回 null，不触碰 FFI / search.db）。
  @visibleForTesting
  Future<SearchIndex?> Function({required bool full})? debugBuildExecutor;

  /// 测试接缝：非空时 [cancel] 委托之（**不触碰 FFI**），供单测验证
  /// 「关闭总开关 → 取消在途构建」的接线。
  @visibleForTesting
  bool Function()? debugCancelOverride;

  /// 启动预构建是否已触发（幂等门：仅首次 [warmUpOnStartup] 真正生效）。
  bool _startupWarmUpTriggered = false;

  LocalSearchStatus _status = LocalSearchStatus.disabled;
  LocalSearchStatus get status => _status;

  /// 最近一次构建结果摘要（诊断 / 设置页展示用）。
  IndexerRunResult? lastResult;

  /// 总开关是否开启（默认 false；关闭时整套能力零成本）。
  bool get enabled => appPrefsSnapshot?.enableLocalSearchIndex ?? false;

  /// `.lrc` 侧车歌词子开关（仅总开关开启时才有意义）。
  bool get indexLrc => appPrefsSnapshot?.indexLrc ?? false;

  /// 搜索：返回命中的 `trackId`（已按相关度排序）；未开启 / 未就绪 / 失败
  /// 一律返回 null，调用方回退 `LIKE`。空关键字同样返回 null（等于原列表）。
  ///
  /// 索引就绪时直接用只读连接查询（不排队）；**构建门被占用时不排队阻塞**，
  /// 直接返回 null 回退 `LIKE`（构建完成后再次搜索即命中）；其余情况经
  /// [ensureIndex] 走构建门。任何异常都降级返回 null，**绝不抛到 UI**。
  ///
  /// [fuzzy]（默认开）启用**两趟容错**（设计文档 §4.6）：精确命中不足 [fuzzyMinExact]
  /// 且查询含拉丁词元时，追加编辑距离 ≤ 1 的模糊查询。失败仍降级返回 null，不抛到 UI。
  Future<List<LocalSearchHit>?> search(
    String query, {
    LocalSearchScope scope = LocalSearchScope.all,
    int limit = 200,
    int offset = 0,
    bool fuzzy = true,
    int fuzzyMinExact = 1,
  }) async {
    // 总开关关闭：第一道门，零成本回退（不触碰模块 / search.db）。
    if (!enabled) return null;
    final keyword = query.trim();
    if (keyword.isEmpty) return null;
    try {
      final index = await _resolveIndexForSearch();
      if (index == null) return null;
      return index.search(
        keyword,
        scope: scope,
        limit: limit,
        offset: offset,
        fuzzy: fuzzy,
        minExact: fuzzyMinExact,
      );
    } catch (err) {
      Log.w('search', '本地索引搜索失败，回退 LIKE: $err');
      _status = LocalSearchStatus.error('$err');
      return null;
    }
  }

  /// 分析文本得到与索引同构的词元；供**结果高亮**（拼音 / 首字母命中）复用同一
  /// 原生分析器（保证与索引 / 查询侧一致）。
  ///
  /// 复用已加载的 indexer 句柄（[_lib]），**不**触发加载 / 构建 / 查询——
  /// 高亮是展示层增强，未就绪（总开关关闭、模块未加载）时返回 null，
  /// 调用方降级为仅字面高亮。任何异常都返回 null，绝不抛到 UI。
  AnalyzerTokens? analyze(String text) {
    if (!enabled || _disposed) return null;
    final lib = _lib;
    if (lib == null) return null;
    try {
      return lib.analyze(text);
    } catch (err) {
      Log.w('search', '分析器调用失败（高亮降级）: $err');
      return null;
    }
  }

  /// 搜索侧的索引选取：就绪即用；构建门占用（构建 / 重开 / 删除进行中）则
  /// **不排队**，返回 null 由调用方回退 `LIKE`；否则按需构建。
  Future<SearchIndex?> _resolveIndexForSearch() {
    if (_disposed) return Future<SearchIndex?>.value();
    final current = _index;
    if (current != null && current.available) {
      return Future<SearchIndex?>.value(current);
    }
    if (_gateBusy) return Future<SearchIndex?>.value();
    return ensureIndex();
  }

  /// 确保索引就绪（必要时构建）；不可用返回 null。绝不抛异常。
  ///
  /// 需要构建 / 重开时经构建门串行；门内**再次**检查是否已就绪（可能被前一个
  /// 关键段建好），避免重复构建。
  Future<SearchIndex?> ensureIndex() async {
    if (_disposed) return null;
    if (!enabled) {
      _status = LocalSearchStatus.disabled;
      return null;
    }
    final current = _index;
    if (current != null && current.available) return current;
    return _serialize(() async {
      if (_disposed) return null;
      if (!enabled) {
        _status = LocalSearchStatus.disabled;
        return null;
      }
      // 门内复查：前一个关键段可能已建好索引，直接复用（不重复构建）。
      final existing = _index;
      if (existing != null && existing.available) return existing;
      return _buildAndOpenLocked(
        full: _needsFullBuild(),
        failMessage: '索引构建失败',
      );
    });
  }

  /// 强制全量重建索引（设置页「重建索引」）。经构建门串行；失败降级 error。
  Future<void> rebuild() async {
    if (_disposed || !enabled) return;
    await _serialize(() async {
      if (_disposed || !enabled) return;
      await _buildAndOpenLocked(full: true, failMessage: '索引重建失败');
    });
  }

  /// 增量重建索引（`.lrc` 子开关切换后调用）：只处理脏文档，完成后重开只读连接。
  ///
  /// `full:false` 交给 indexer 侧按 `(mtime, size)` 脏集增量——内嵌歌词变更、
  /// `.lrc` 开启 / 关闭（含清理）都能被识别，只重算受影响的曲目，
  /// **无需**用户手动「重建索引」（P3b-1 遗留风险，P4 修复）。
  ///
  /// 与 [rebuild] 一样经构建门串行、**失败降级**：任何失败置为 error 态并返回，
  /// 绝不抛到 UI；`search.db` 缺失 / schema 不符时回退全量，保证可用。
  Future<void> reindex() async {
    if (_disposed) return;
    final override = debugReindexOverride;
    if (override != null) return override();
    if (!enabled) return;
    await _serialize(() async {
      if (_disposed || !enabled) return;
      await _buildAndOpenLocked(
        full: _needsFullBuild(),
        failMessage: '索引增量更新失败',
      );
    });
  }

  /// 请求取消进行中的构建（透传 `indexer_cancel`）。
  bool cancel() {
    final override = debugCancelOverride;
    if (override != null) return override();
    try {
      return _lib?.cancel() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 应用启动时的**后台预构建**（总开关开启才触发；幂等；失败静默）。
  ///
  /// 由启动引导（`app/bootstrap.dart` 的 [AuthBootstrap]）在偏好就绪后调用：
  /// - 总开关关闭 / 快照缺失：**不触碰**模块 / `search.db`（零成本，直接返回）；
  /// - 首次调用且总开关开启：后台跑 [ensureIndex]（不阻塞首帧）；后续调用因
  ///   [_startupWarmUpTriggered] 短路，且 [ensureIndex] 本身门内复查复用已有
  ///   构建，不会重复构建；
  /// - 任何失败（模块缺失 / 构建失败）由 [ensureIndex] 内部降级，这里再兜底
  ///   `catch`，**绝不抛到启动路径**（索引是派生数据，可随时重建）。
  Future<void> warmUpOnStartup() async {
    if (_startupWarmUpTriggered) return;
    if (!enabled) return; // 关闭态零成本：不加载模块 / 不建库 / 不查询。
    _startupWarmUpTriggered = true;
    try {
      await ensureIndex();
    } catch (err) {
      Log.w('search', '启动预构建索引失败（静默降级）: $err');
    }
  }

  /// 停止接管（总开关关闭时调用）：取消在途构建、关闭只读连接、置为未启用。
  ///
  /// **不删除** `search.db`（派生数据默认保留，避免每次开关都全量重建）；
  /// 需要释放空间走 [deleteIndex]。总开关关闭后 [search] 本就返回 null，
  /// 这里额外：
  /// - 经 [cancel] 请求取消在途 `indexer_run`（透传 `indexer_cancel`；无在途
  ///   构建时为 no-op）——**不绕过构建门**，只是取消信号，门内关键段仍串行；
  /// - 释放连接；进行中的构建会在其门内段结束时发现总开关已关（`!enabled`）
  ///   而**放弃重开**（不复活连接），状态回到 [LocalSearchStatus.disabled]。
  void deactivate() {
    if (_disposed) return;
    cancel();
    _closeIndexLocked();
    _status = LocalSearchStatus.disabled;
  }

  /// 删除派生索引（`search.db` 及其 WAL 侧车）；总开关仍开启时下次搜索重建。
  ///
  /// 经构建门串行：**不与构建并发**（避免删除正在进行写入的 `search.db`）。
  Future<void> deleteIndex() async {
    await _serialize(() async {
      if (_disposed) return;
      _closeIndexLocked();
      final path = defaultSearchDbPath();
      for (final suffix in const ['', '-wal', '-shm']) {
        try {
          final file = File('$path$suffix');
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // 删除失败不阻断（下次构建覆盖 / 交由用户处理）
        }
      }
      _status = LocalSearchStatus.disabled;
    });
  }

  /// 关闭只读连接并释放回调。
  ///
  /// 设置关闭标志（后续入口拒绝开新连接）、请求取消在途 `indexer_run`；在途
  /// 关键段发现已关闭后**不再开新连接**。绝不抛异常。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    _closeIndexLocked();
    if (!_progressDisposed) {
      _progressDisposed = true;
      progress.dispose();
    }
    _status = LocalSearchStatus.disabled;
  }

  /// 测试接缝：把单例恢复到初始可用状态（仅单测使用）。
  ///
  /// `dispose()` 不可逆；需要在其后继续用单例的测试在此重置。
  @visibleForTesting
  void debugReset() {
    _index?.close();
    _index = null;
    _lib = null;
    _soPath = null;
    _disposed = false;
    _progressDisposed = false;
    _gateTail = Future<void>.value();
    _gateOccupancy = 0;
    _status = LocalSearchStatus.disabled;
    lastResult = null;
    debugReindexOverride = null;
    debugBuildExecutor = null;
    debugCancelOverride = null;
    _startupWarmUpTriggered = false;
    progress = ValueNotifier<IndexerProgress?>(null);
  }

  // ---------------------------------------------------------------- 内部

  /// `search.db` 缺失 / schema 不符 → 需要全量构建。
  bool _needsFullBuild() {
    final searchDb = defaultSearchDbPath();
    return !File(searchDb).existsSync() || !SearchIndex.isAvailable(searchDb);
  }

  /// 构建 + 开库关键段（**必须**在构建门内调用；自身不取门）。
  ///
  /// 步骤：先确认索引器可用（模块缺失早退）→ 关闭旧连接（构建期间 [search]
  /// 回退 LIKE，不读陈旧数据）→ 跑构建 → 成功后开**唯一**新连接。
  /// 全程 `_disposed` / `enabled` 复查，关闭或总开关断开时不复活连接。
  Future<SearchIndex?> _buildAndOpenLocked({
    required bool full,
    required String failMessage,
  }) async {
    if (_disposed || !enabled) return null;
    final executor = debugBuildExecutor;
    if (executor == null) {
      final lib = _ensureLib();
      if (lib == null) {
        _status = LocalSearchStatus.error('未找到索引器模块');
        return null;
      }
    }
    // 替换前先关旧连接，保证任一时刻至多一个有效 `_index`。
    _closeIndexLocked();
    _status = LocalSearchStatus.building;

    if (executor != null) {
      try {
        final index = await executor(full: full);
        if (_disposed || !enabled) {
          index?.close();
          _status = LocalSearchStatus.disabled;
          return null;
        }
        _index = index;
        _status = index != null
            ? LocalSearchStatus.ready
            : LocalSearchStatus.error(failMessage);
        return index;
      } catch (err) {
        if (!_disposed) _status = LocalSearchStatus.error('$err');
        return null;
      }
    }

    final built = await _runBuild(full: full);
    if (_disposed) return null;
    if (!enabled) {
      _status = LocalSearchStatus.disabled;
      return null;
    }
    if (!built) {
      _status = LocalSearchStatus.error(failMessage);
      return null;
    }
    return _openIndexLocked();
  }

  IndexerLibrary? _ensureLib() {
    if (_disposed) return null;
    final existing = _lib;
    if (existing != null) return existing;
    try {
      _soPath ??= IndexerLibrary.resolveSoPath();
      final lib = IndexerLibrary.load(soPath: _soPath);
      _lib = lib;
      return lib;
    } catch (err) {
      Log.w('search', '加载 indexer 模块失败: $err');
      return null;
    }
  }

  void _closeIndexLocked() {
    _index?.close();
    _index = null;
  }

  SearchIndex? _openIndexLocked() {
    final lib = _lib;
    final index = SearchIndex.open(
      defaultSearchDbPath(),
      analyzer: lib == null ? null : (q) => lib.analyze(q),
    );
    if (index == null) {
      _status = LocalSearchStatus.error('search.db 不可用（schema 不符或损坏）');
      return null;
    }
    _closeIndexLocked();
    _index = index;
    _status = LocalSearchStatus.ready;
    return index;
  }

  /// 在后台 isolate 跑 `indexer_run`；进度经 [progress] 暴露（不阻塞 UI）。
  Future<bool> _runBuild({required bool full}) async {
    final lib = _lib;
    final soPath = _soPath;
    if (lib == null || soPath == null) return false;

    final libraryDb = LibraryScanner.defaultDbPath();
    final searchDb = defaultSearchDbPath();
    File(searchDb).parent.createSync(recursive: true);
    final optionsJson =
        jsonEncode({'index_lrc': indexLrc, 'pinyin': true});

    final callable =
        NativeCallable<Void Function(Pointer<Void>)>.listener(_handleProgress);
    _setProgress(null);
    try {
      final cb = callable.nativeFunction.cast<Void>();
      final (code, text) = await Isolate.run(() {
        // 子 isolate 重新加载库（句柄进程共享）；指针可跨 isolate 传递。
        final lib = IndexerLibrary.load(soPath: soPath);
        return lib.runBlocking(
          dbPath: libraryDb,
          indexPath: searchDb,
          full: full,
          optionsJson: optionsJson,
          onProgress: cb,
        );
      });
      if (_disposed) return false;
      if (code != 0) {
        Log.w('search', '索引构建失败（exit=$code）: $text');
        return false;
      }
      lastResult =
          IndexerRunResult.fromJson(jsonDecode(text) as Map<String, dynamic>);
      return true;
    } catch (err) {
      Log.w('search', '索引构建异常: $err');
      return false;
    } finally {
      callable.close();
      _setProgress(null);
    }
  }

  /// 仅在未关闭时写进度（`dispose` 后 [progress] 已释放，写入会抛）。
  void _setProgress(IndexerProgress? value) {
    if (_disposed || _progressDisposed) return;
    progress.value = value;
  }

  /// 进度回调入口（主 isolate 事件循环执行）：解析 JSON 并释放 C# 内存。
  void _handleProgress(Pointer<Void> ptr) {
    String? text;
    try {
      text = ptr.cast<Utf8>().toDartString();
    } catch (_) {}
    // 句柄内存始终释放（`dispose` 后 `_lib` 仍常驻，避免泄漏）。
    try {
      _lib?.free(ptr);
    } catch (_) {}
    if (text == null || _disposed) return;
    try {
      _setProgress(
        IndexerProgress.fromJson(jsonDecode(text) as Map<String, dynamic>),
      );
    } catch (_) {
      // 进度帧解析失败忽略（不中断构建）
    }
  }
}

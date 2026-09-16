// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_scanner.dart';
import 'tracks_db.dart';
import '../../stores/app_prefs.dart';

part 'library_store/library_store_core.dart';
part 'library_store/library_store_scan.dart';

/// 本地音乐库状态。
class LibraryState {
  const LibraryState({
    this.initialized = false,
    this.scanDirs = const [],
    this.scanning = false,
    this.scanPercent,
    this.scanCurrent = '',
    this.scanned = 0,
    this.total = 0,
    this.scanErrors = 0,
    this.scanCanceled = false,
    this.tracks = const [],
    this.totalCount = 0,
    this.totalSizeBytes = 0,
    this.totalDurationMs = 0,
    this.hasMore = false,
    this.loadingMore = false,
    this.searchQuery = '',
    this.error,
  });

  final bool initialized;

  /// 扫描目录列表（持久化）。
  final List<String> scanDirs;

  /// 正在扫描。
  final bool scanning;

  /// 扫描进度 0~1（total==0 统计阶段为 null）。
  final double? scanPercent;

  /// 当前扫描文件。
  final String scanCurrent;
  final int scanned;
  final int total;
  final int scanErrors;
  final bool scanCanceled;

  /// 已载入的曲目窗口（按标题排序；分页追加，**不含 lyrics**）。
  ///
  /// 不再是全量：滚动触底经 [LibraryNotifier.loadMore] 续拉；搜索经 SQL 下推
  /// 后同样只驻留当前窗口。
  final List<TrackRow> tracks;

  /// 当前搜索条件下的曲目总数（无搜索时等于曲库总数）。
  final int totalCount;

  /// 曲库总文件大小（字节，来自 DB 聚合，非窗口求和）。
  final int totalSizeBytes;

  /// 曲库总时长（毫秒，来自 DB 聚合，非窗口求和）。
  final int totalDurationMs;

  /// 是否还有未载入的曲目（窗口 < [totalCount]）。
  final bool hasMore;

  /// 是否正在加载下一页。
  final bool loadingMore;

  final String searchQuery;

  final String? error;

  LibraryState copyWith({
    bool? initialized,
    List<String>? scanDirs,
    bool? scanning,
    double? scanPercent,
    String? scanCurrent,
    int? scanned,
    int? total,
    int? scanErrors,
    bool? scanCanceled,
    List<TrackRow>? tracks,
    int? totalCount,
    int? totalSizeBytes,
    int? totalDurationMs,
    bool? hasMore,
    bool? loadingMore,
    String? searchQuery,
    String? error,
  }) {
    return LibraryState(
      initialized: initialized ?? this.initialized,
      scanDirs: scanDirs ?? this.scanDirs,
      scanning: scanning ?? this.scanning,
      scanPercent: scanPercent ?? this.scanPercent,
      scanCurrent: scanCurrent ?? this.scanCurrent,
      scanned: scanned ?? this.scanned,
      total: total ?? this.total,
      scanErrors: scanErrors ?? this.scanErrors,
      scanCanceled: scanCanceled ?? this.scanCanceled,
      tracks: tracks ?? this.tracks,
      totalCount: totalCount ?? this.totalCount,
      totalSizeBytes: totalSizeBytes ?? this.totalSizeBytes,
      totalDurationMs: totalDurationMs ?? this.totalDurationMs,
      hasMore: hasMore ?? this.hasMore,
      loadingMore: loadingMore ?? this.loadingMore,
      searchQuery: searchQuery ?? this.searchQuery,
      error: error ?? this.error,
    );
  }
}

/// 本地音乐库控制器：扫描目录持久化 + 扫描（FFI 直连）+ 曲库查询。
///
/// 曲目数据单一事实源是 scanner 直写的 library.db（sqlite3），
/// 本 store 只读缓存（[LibraryState.tracks]），写操作一律走扫描。
class LibraryNotifier extends Notifier<LibraryState>
    with _LibraryStoreCore, _LibraryStoreScan {
  @override
  LibraryState build() {
    ref.onDispose(() {
      _searchDebounce?.cancel();
      _searchDebounce = null;
    });
    return const LibraryState();
  }

  /// 进行中的扫描器（供 cancelScan 调用 C# 静态 CTS 取消）。
  @override
  LibraryScanner? _activeScanner;

  /// 上次自动增量扫描时间（进入音乐库页触发；5 分钟内不重复）。
  @override
  DateTime? _lastAutoRefreshAt;

  /// 搜索输入去抖（SQL 下推前合并连续输入）。
  @override
  Timer? _searchDebounce;

  /// 扫描目录配置文件路径。
  static String _scanDirsFile() => _LibraryStoreCore._libraryScanDirsFilePath();

  /// 初始化：读扫描目录 + 载入曲库（幂等）。
  Future<void> init() => _initLibrary();

  /// 重新载入曲目（从 library.db，回到第一页）。
  Future<void> reloadTracks() => _reloadTracks();

  /// 滚动触底续拉下一页（无更多 / 加载中时忽略）。
  Future<void> loadMore() => _loadMore();

  /// 按当前搜索条件取全量曲目（不含 lyrics，供「播放全部」建队列）。
  Future<List<TrackRow>> allTracks() => _allTracks();

  void setSearchQuery(String q) => _setSearchQuery(q);

  /// 从曲库移除曲目（仅删 library.db 记录，不删源文件；命中返回 true）。
  Future<bool> removeTrackByPath(String path) => _removeTrackByPath(path);

  /// 添加扫描目录（已存在 / 非目录时忽略，返回是否成功）。
  bool addScanDir(String dir) => _addScanDir(dir);

  /// 移除扫描目录。
  void removeScanDir(String dir) => _removeScanDir(dir);

  /// 扫描（增量/全量）。进度实时写入 [LibraryState]。
  Future<void> startScan({bool incremental = true}) =>
      _startScan(incremental: incremental);

  /// 取消进行中的扫描（C# 静态 CTS；结果最终以 canceled 返回）。
  void cancelScan() => _cancelScan();

  /// 进入音乐库页时自动增量扫描（避免手动点刷新才更新列表）。
  ///
  /// - 距上次自动扫描 ≥5 分钟才执行（同一会话内反复进出不重复扫）；
  /// - 先幂等 init（保证扫描目录已载入，首次进入与 AppShell 触发竞态安全）；
  /// - 无目录 / 扫描中直接跳过。
  Future<void> maybeAutoRefresh() => _maybeAutoRefresh();
}

/// 本地音乐库 store。
final libraryStoreProvider = NotifierProvider<LibraryNotifier, LibraryState>(
  LibraryNotifier.new,
);

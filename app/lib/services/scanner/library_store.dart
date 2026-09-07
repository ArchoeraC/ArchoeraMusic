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

  /// 曲目全量（按标题排序，内存过滤搜索）。
  final List<TrackRow> tracks;

  final String searchQuery;

  final String? error;

  /// 搜索过滤后的曲目。
  List<TrackRow> get filteredTracks {
    final q = searchQuery.trim().toLowerCase();
    if (q.isEmpty) return tracks;
    return tracks.where((t) {
      if (t.title.toLowerCase().contains(q)) return true;
      if (t.artistNames.join(' / ').toLowerCase().contains(q)) return true;
      if ((t.albumName ?? '').toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  /// 曲目总文件大小（字节）。
  int get totalSizeBytes =>
      tracks.fold(0, (sum, t) => sum + (t.fileSize > 0 ? t.fileSize : 0));

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
  LibraryState build() => const LibraryState();

  /// 进行中的扫描器（供 cancelScan 调用 C# 静态 CTS 取消）。
  @override
  LibraryScanner? _activeScanner;

  /// 上次自动增量扫描时间（进入音乐库页触发；5 分钟内不重复）。
  @override
  DateTime? _lastAutoRefreshAt;

  /// 扫描目录配置文件路径。
  static String _scanDirsFile() => _LibraryStoreCore._libraryScanDirsFilePath();

  /// 初始化：读扫描目录 + 载入曲库（幂等）。
  Future<void> init() => _initLibrary();

  /// 重新载入曲目（从 library.db）。
  Future<void> reloadTracks() => _reloadTracks();

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

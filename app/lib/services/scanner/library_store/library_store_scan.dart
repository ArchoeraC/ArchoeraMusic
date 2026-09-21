// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_store.dart';

mixin _LibraryStoreScan on Notifier<LibraryState>, _LibraryStoreCore {
  LibraryScanner? get _activeScanner;
  set _activeScanner(LibraryScanner? value);

  DateTime? get _lastAutoRefreshAt;
  set _lastAutoRefreshAt(DateTime? value);

  Future<void> _startScan({bool incremental = true}) async {
    if (state.scanning || state.scanDirs.isEmpty) return;
    state = state.copyWith(
      scanning: true,
      scanPercent: null,
      scanCurrent: '正在统计文件…',
      scanned: 0,
      total: 0,
      scanErrors: 0,
      scanCanceled: false,
      error: null,
    );

    final scanner = LibraryScanner();
    _activeScanner = scanner;
    final sub = scanner.progress.listen((p) {
      state = state.copyWith(
        scanning: p.scanning,
        scanCurrent: p.current,
        scanned: p.scanned,
        total: p.total,
        scanPercent: p.total > 0 ? p.scanned / p.total : null,
      );
    });

    try {
      final result = await scanner.scan(
        state.scanDirs,
        incremental: incremental,
        batch: ref.read(appPrefsProvider).scanBatchSize,
        maxParallelism: ref.read(appPrefsProvider).scanParallelism,
        maxFileSizeMb: ref.read(appPrefsProvider).scanMaxFileSizeMb,
        maxScanFiles: ref.read(appPrefsProvider).scanMaxScanFiles,
        maxScanErrors: ref.read(appPrefsProvider).scanMaxScanErrors,
        extraExts: ref.read(appPrefsProvider).scanExtraExts,
      );
      state = state.copyWith(
        scanning: false,
        scanPercent: null,
        scanCanceled: result.canceled,
        scanErrors: result.errors,
      );
      await _reloadTracks();
    } catch (e) {
      state = state.copyWith(scanning: false, error: e.toString());
    } finally {
      await sub.cancel();
      scanner.dispose();
      _activeScanner = null;
    }
  }

  void _cancelScan() {
    _activeScanner?.cancel();
  }

  Future<void> _maybeAutoRefresh() async {
    await _initLibrary();
    if (state.scanning || state.scanDirs.isEmpty) return;
    final now = DateTime.now();
    // 扫描目录自身 mtime 变了（有新文件落入）→ 绕过节流立即扫描，
    // 否则新加的媒体要等 5 分钟节流或重启才会入库。
    final dirsChanged = _scanDirsChangedSinceLastScan();
    if (!dirsChanged &&
        _lastAutoRefreshAt != null &&
        now.difference(_lastAutoRefreshAt!) < const Duration(minutes: 5)) {
      return;
    }
    _lastAutoRefreshAt = now;
    _snapshotScanDirMtimes();
    await _startScan(incremental: true);
  }

  /// 相比上次扫描，扫描目录是否新增/移除或自身 mtime 变化（顶层新增文件可见）。
  bool _scanDirsChangedSinceLastScan();

  /// 记录当前扫描目录的 mtime 快照（扫描触发时调用）。
  void _snapshotScanDirMtimes();
}

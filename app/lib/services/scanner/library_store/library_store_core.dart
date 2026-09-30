// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_store.dart';

mixin _LibraryStoreCore on Notifier<LibraryState> {
  /// 搜索去抖延时（SQL 下推前合并连续输入）。
  static const Duration _searchDebounceDelay = Duration(milliseconds: 250);

  /// 重新载入曲库（清空页缓存 + 载入第一页 + 聚合统计）。
  ///
  /// 由 [_LibraryStorePager] 实现；core / scan 仅通过本契约调用。
  Future<void> _reloadTracks();

  Timer? get _searchDebounce;
  set _searchDebounce(Timer? value);

  static String _libraryScanDirsFilePath() =>
      '${LibraryScanner.defaultDataDir()}/scan_dirs.json';

  Future<void> _initLibrary() async {
    if (state.initialized) return;
    List<String> dirs;
    try {
      final f = File(LibraryNotifier._scanDirsFile());
      if (f.existsSync()) {
        dirs = (jsonDecode(f.readAsStringSync()) as List<dynamic>)
            .whereType<String>()
            .toList();
      } else {
        dirs = const [];
      }
    } catch (_) {
      dirs = const [];
    }
    state = state.copyWith(initialized: true, scanDirs: dirs);
    await _reloadTracks();
  }

  /// 按当前搜索条件取全量（不含 lyrics），供「播放全部」建队列。
  Future<List<TrackRow>> _allTracks() async {
    try {
      final db = TracksDb.open();
      final rows = db.allTracks(query: state.searchQuery);
      db.close();
      return rows;
    } catch (_) {
      return const [];
    }
  }

  /// 随机抽取 [limit] 首本地曲目（首页聚光 / 随便听听；不含 lyrics）。
  Future<List<Track>> _randomTracks(int limit) async {
    if (limit <= 0) return const [];
    try {
      final db = TracksDb.open();
      final rows = db.randomTracks(limit);
      db.close();
      return rows.map(trackFromRow).toList();
    } catch (_) {
      return const [];
    }
  }

  void _setSearchQuery(String q) {
    if (state.searchQuery == q) return;
    state = state.copyWith(searchQuery: q);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDelay, () {
      _searchDebounce = null;
      _reloadTracks();
    });
  }

  /// 删除曲目文件（磁盘）并从曲库移除（见 [LibraryNotifier.deleteTrackFile]）。
  Future<bool> _deleteTrackFile(String path) async {
    if (path.isEmpty) return false;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      return false; // 删除失败：保留曲库记录，交由调用方提示
    }
    await _removeTrackByPath(path);
    return true;
  }

  Future<bool> _removeTrackByPath(String path) async {
    if (path.isEmpty) return false;
    try {
      final db = TracksDb.open();
      final ok = db.deleteByPath(path);
      db.close();
      if (ok) await _reloadTracks();
      return ok;
    } catch (_) {
      return false;
    }
  }

  void _persistScanDirs() {
    try {
      final f = File(LibraryNotifier._scanDirsFile());
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(state.scanDirs));
    } catch (_) {}
  }

  bool _addScanDir(String dir) {
    final normalized = dir.trim();
    if (normalized.isEmpty) return false;
    final d = Directory(normalized);
    if (!d.existsSync()) return false;
    if (state.scanDirs.contains(normalized)) return false;
    state = state.copyWith(scanDirs: [...state.scanDirs, normalized]);
    _persistScanDirs();
    return true;
  }

  void _removeScanDir(String dir) {
    state = state.copyWith(
      scanDirs: state.scanDirs.where((d) => d != dir).toList(),
    );
    _persistScanDirs();
  }
}

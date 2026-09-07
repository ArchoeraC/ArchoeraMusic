part of '../library_store.dart';

mixin _LibraryStoreCore on Notifier<LibraryState> {
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

  Future<void> _reloadTracks() async {
    try {
      final db = TracksDb.open();
      final tracks = db.listTracks(limit: 100000);
      db.close();
      state = state.copyWith(tracks: tracks, error: null);
    } catch (_) {
      state = state.copyWith(tracks: const [], error: null);
    }
  }

  void _setSearchQuery(String q) => state = state.copyWith(searchQuery: q);

  Future<bool> _removeTrackByPath(String path) async {
    if (path.isEmpty) return false;
    try {
      final db = TracksDb.open();
      final ok = db.deleteByPath(path);
      db.close();
      if (ok) {
        state = state.copyWith(
          tracks: state.tracks.where((t) => t.path != path).toList(),
        );
      }
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

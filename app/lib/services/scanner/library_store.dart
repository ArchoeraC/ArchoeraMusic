import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_scanner.dart';
import 'tracks_db.dart';

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
class LibraryNotifier extends Notifier<LibraryState> {
  @override
  LibraryState build() => const LibraryState();

  /// 进行中的扫描器（供 cancelScan 调用 C# 静态 CTS 取消）。
  LibraryScanner? _activeScanner;

  /// 上次自动增量扫描时间（进入音乐库页触发；5 分钟内不重复）。
  DateTime? _lastAutoRefreshAt;

  /// 扫描目录配置文件路径。
  static String _scanDirsFile() =>
      '${LibraryScanner.defaultDataDir()}/scan_dirs.json';

  /// 初始化：读扫描目录 + 载入曲库（幂等）。
  Future<void> init() async {
    if (state.initialized) return;
    List<String> dirs;
    try {
      final f = File(_scanDirsFile());
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
    await reloadTracks();
  }

  /// 重新载入曲目（从 library.db）。
  Future<void> reloadTracks() async {
    try {
      final db = TracksDb.open();
      final tracks = db.listTracks(limit: 100000);
      db.close();
      state = state.copyWith(tracks: tracks, error: null);
    } catch (_) {
      // DB 尚未建立（首次/无目录）→ 空曲库
      state = state.copyWith(tracks: const [], error: null);
    }
  }

  void setSearchQuery(String q) =>
      state = state.copyWith(searchQuery: q);

  /// 从曲库移除曲目（仅删 library.db 记录，不删源文件；命中返回 true）。
  Future<bool> removeTrackByPath(String path) async {
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
      final f = File(_scanDirsFile());
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(state.scanDirs));
    } catch (_) {
      // 持久化失败不阻断（自用）
    }
  }

  /// 添加扫描目录（已存在 / 非目录时忽略，返回是否成功）。
  bool addScanDir(String dir) {
    final normalized = dir.trim();
    if (normalized.isEmpty) return false;
    final d = Directory(normalized);
    if (!d.existsSync()) return false;
    if (state.scanDirs.contains(normalized)) return false;
    state = state.copyWith(scanDirs: [...state.scanDirs, normalized]);
    _persistScanDirs();
    return true;
  }

  /// 移除扫描目录。
  void removeScanDir(String dir) {
    state = state.copyWith(
      scanDirs: state.scanDirs.where((d) => d != dir).toList(),
    );
    _persistScanDirs();
  }

  /// 扫描（增量/全量）。进度实时写入 [LibraryState]。
  Future<void> startScan({bool incremental = true}) async {
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
      );
      state = state.copyWith(
        scanning: false,
        scanPercent: null,
        scanCanceled: result.canceled,
        scanErrors: result.errors,
      );
      // 扫描后曲库可能变化 → 重载
      await reloadTracks();
    } catch (e) {
      state = state.copyWith(scanning: false, error: e.toString());
    } finally {
      await sub.cancel();
      scanner.dispose();
      _activeScanner = null;
    }
  }

  /// 取消进行中的扫描（C# 静态 CTS；结果最终以 canceled 返回）。
  void cancelScan() {
    _activeScanner?.cancel();
  }

  /// 进入音乐库页时自动增量扫描（避免手动点刷新才更新列表）。
  ///
  /// - 距上次自动扫描 ≥5 分钟才执行（同一会话内反复进出不重复扫）；
  /// - 先幂等 init（保证扫描目录已载入，首次进入与 AppShell 触发竞态安全）；
  /// - 无目录 / 扫描中直接跳过。
  Future<void> maybeAutoRefresh() async {
    await init();
    if (state.scanning || state.scanDirs.isEmpty) return;
    final now = DateTime.now();
    if (_lastAutoRefreshAt != null &&
        now.difference(_lastAutoRefreshAt!) < const Duration(minutes: 5)) {
      return;
    }
    _lastAutoRefreshAt = now;
    await startScan(incremental: true);
  }
}

/// 本地音乐库 store。
final libraryStoreProvider =
    NotifierProvider<LibraryNotifier, LibraryState>(LibraryNotifier.new);

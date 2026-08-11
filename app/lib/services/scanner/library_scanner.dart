import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../stores/data_dir.dart';
import 'scanner_ffi.dart';

/// 扫描进度（对齐 C# ScanProgress JSON：type=progress）。
class ScanProgress {
  const ScanProgress({
    required this.scanning,
    required this.scanned,
    required this.total,
    required this.upserted,
    required this.errors,
    required this.trained,
    required this.current,
  });

  final bool scanning;
  final int scanned;
  final int total;
  final int upserted;
  final int errors;
  final int trained;
  final String current;

  factory ScanProgress.fromJson(Map<String, dynamic> json) => ScanProgress(
        scanning: json['scanning'] as bool? ?? true,
        scanned: (json['scanned'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        upserted: (json['upserted'] as num?)?.toInt() ?? 0,
        errors: (json['errors'] as num?)?.toInt() ?? 0,
        trained: (json['trained'] as num?)?.toInt() ?? 0,
        current: json['current'] as String? ?? '',
      );
}

/// 扫描结果（对齐 C# ScanResult JSON：type=done）。
class ScanResult {
  const ScanResult({
    required this.total,
    required this.scanned,
    required this.upserted,
    required this.deleted,
    required this.canceled,
    required this.errors,
    required this.trained,
  });

  final int total;
  final int scanned;
  final int upserted;
  final int deleted;
  final bool canceled;
  final int errors;
  final int trained;

  factory ScanResult.fromJson(Map<String, dynamic> json) => ScanResult(
        total: (json['total'] as num?)?.toInt() ?? 0,
        scanned: (json['scanned'] as num?)?.toInt() ?? 0,
        upserted: (json['upserted'] as num?)?.toInt() ?? 0,
        deleted: (json['deleted'] as num?)?.toInt() ?? 0,
        canceled: json['canceled'] as bool? ?? false,
        errors: (json['errors'] as num?)?.toInt() ?? 0,
        trained: (json['trained'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() =>
      'ScanResult(scanned=$scanned/$total, upserted=$upserted, '
      'deleted=$deleted, errors=$errors, trained=$trained, canceled=$canceled)';
}

/// 扫描失败（exitCode != 0）。
class ScannerException implements Exception {
  const ScannerException(this.message);
  final String message;

  @override
  String toString() => 'ScannerException: $message';
}

/// 本地音乐扫描器（高层封装）。
///
/// 职责：
///  - 在独立 isolate 中执行阻塞的 FFI `scanner_scan`，避免冻结 UI；
///  - 通过 [NativeCallable].listener 接收 C# 后台线程的进度回调，
///    转为 [progress] 广播流（主 isolate 消费）；
///  - [cancel] 从主 isolate 请求取消（C# 静态 CTS）。
///
/// 生命周期：可多次调用 [scan]（内部每次在子 isolate 重新加载共享库）；
/// 使用完调用 [dispose] 释放回调。
class LibraryScanner {
  LibraryScanner({String? soPath}) : _soPath = soPath {
    // 主 isolate 持有库句柄，供进度回调里释放 C# 分配的内存
    _lib = ScannerLibrary.load(soPath: soPath);
    _progressCallable =
        NativeCallable<Void Function(Pointer<Void>)>.listener(_handleProgress);
  }

  final String? _soPath;
  late final ScannerLibrary _lib;
  late final NativeCallable<Void Function(Pointer<Void>)> _progressCallable;

  final StreamController<ScanProgress> _progressController =
      StreamController<ScanProgress>.broadcast();

  /// 扫描进度流（每 ~500ms 一帧 + 完成快照）。
  Stream<ScanProgress> get progress => _progressController.stream;

  /// 是否正在扫描（由最近一次进度帧的 scanning 字段决定）。
  bool _scanning = false;
  bool get isScanning => _scanning;

  /// 扫描目录，进度经 [progress] 广播。
  ///
  /// [dbPath] 为空时回退到默认数据目录的 library.db。
  /// [coverDir]/[quarantineDir] 为空时使用 dbPath 同目录下的 cache/covers、quarantine。
  Future<ScanResult> scan(
    List<String> dirs, {
    String? dbPath,
    String? coverDir,
    String? quarantineDir,
    bool incremental = true,
    int batch = 0,
    int maxParallelism = 0,
  }) async {
    if (_scanning) {
      throw StateError('已有扫描在进行中');
    }
    _scanning = true;

    final resolvedDb = dbPath ?? defaultDbPath();
    final resolvedCover = coverDir ?? '${_dbDir(resolvedDb)}/cache/covers';
    final resolvedQuarantine = quarantineDir ?? '${_dbDir(resolvedDb)}/quarantine';

    // 确保 DB 父目录存在（SqliteDirectWriter 只 Open 不建目录）
    File(resolvedDb).parent.createSync(recursive: true);

    final soPath = _soPath;
    final progressCb = _progressCallable.nativeFunction.cast<Void>();

    try {
      // 子 isolate 执行阻塞扫描；Pointer/函数指针可跨 isolate 传递（进程共享）
      final (code, text) = await Isolate.run(() {
        final lib = ScannerLibrary.load(soPath: soPath);
        return lib.scanBlocking(
          dirs: dirs,
          dbPath: resolvedDb,
          coverDir: resolvedCover,
          quarantineDir: resolvedQuarantine,
          incremental: incremental,
          batch: batch,
          maxParallelism: maxParallelism,
          onProgress: progressCb,
        );
      });

      if (code != 0) {
        throw ScannerException(text.isEmpty ? '扫描失败（exit=$code）' : text);
      }
      return ScanResult.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } finally {
      _scanning = false;
    }
  }

  /// 请求取消进行中的扫描。
  bool cancel() {
    try {
      return _lib.cancel();
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _progressCallable.close();
    _progressController.close();
  }

  /// 默认数据目录（~/.local/share/ArchoeraMusic，ARCHOERA_DATA_DIR 可覆盖）。
  static String defaultDataDir() => resolveDataDir();

  /// 默认曲库 DB 路径。
  static String defaultDbPath() => '${defaultDataDir()}/database/library.db';

  /// 进度回调入口（主 isolate 事件循环执行）。
  void _handleProgress(Pointer<Void> ptr) {
    final str = ptr.cast<Utf8>().toDartString();
    // 释放 C# NativeMemory 分配的内存
    try {
      _lib.free(ptr);
    } catch (_) {}
    try {
      final p = ScanProgress.fromJson(jsonDecode(str) as Map<String, dynamic>);
      _scanning = p.scanning;
      if (!_progressController.isClosed) {
        _progressController.add(p);
      }
    } catch (_) {
      // 进度帧解析失败忽略（不中断扫描）
    }
  }

  static String _dbDir(String dbPath) {
    final idx = dbPath.lastIndexOf('/');
    return idx > 0 ? dbPath.substring(0, idx) : '.';
  }
}

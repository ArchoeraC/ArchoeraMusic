import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// scanner-ffi NativeAOT 库的定位、加载与 FFI 绑定。
///
/// 纯 FFI 层：不持有任何 isolate 本地状态，可在任意 isolate 内
/// [load] 后调用 [scanBlocking] / [cancel] / [free]（同一进程共享句柄）。
///
/// 产物约定（与 audio-engine 一致的 ancestors 查找模式）：
///   `scanner/build/scanner-ffi.{so,dylib,dll}` + `libe_sqlite3.{so,dylib}`。
/// 模块位于 app/core/scanner（app 内部，路径关系固定，可随 app 独立部署）。
class ScannerLibrary {
  ScannerLibrary._(this._lib);

  final DynamicLibrary _lib;

  // ---------------------------------------------------------------- 定位

  /// 解析 scanner-ffi 共享库路径。
  ///
  /// 优先级：
  ///  1. 环境变量 `ARCHOERA_SCANNER_FFI`（.so 文件路径或含 `scanner-ffi.so` 的目录）；
  ///  2. 从可执行文件（[Platform.resolvedExecutable]）沿父目录向上查找
  ///     `scanner/build/scanner-ffi.so`；
  ///  3. dev 兜底：`flutter run` 的 cwd 为 `app/`，库在 `app/core/scanner/build/`。
  static String resolveSoPath() {
    final libName = _soFileName();

    final override = Platform.environment['ARCHOERA_SCANNER_FFI'];
    if (override != null && override.isNotEmpty) {
      if (File(override).existsSync()) return override;
      final asDir = '$override/$libName';
      if (File(asDir).existsSync()) return asDir;
    }

    final exe = Platform.resolvedExecutable;
    var dir = File(exe).parent;
    while (dir.path != dir.parent.path) {
      final cand = File('${dir.path}/scanner/build/$libName');
      if (cand.existsSync()) return cand.absolute.path;
      dir = dir.parent;
    }

    final fromCwd = File('${Directory.current.path}/core/scanner/build/$libName');
    if (fromCwd.existsSync()) return fromCwd.absolute.path;

    throw StateError('无法定位 scanner-ffi：请设置 ARCHOERA_SCANNER_FFI 环境变量');
  }

  static String _soFileName() {
    if (Platform.isWindows) return 'scanner-ffi.dll';
    if (Platform.isMacOS) return 'scanner-ffi.dylib';
    return 'scanner-ffi.so';
  }

  static String _sqliteLibName() {
    if (Platform.isWindows) return 'e_sqlite3.dll';
    if (Platform.isMacOS) return 'libe_sqlite3.dylib';
    return 'libe_sqlite3.so';
  }

  // ---------------------------------------------------------------- 加载

  // Linux glibc dlfcn.h 标志（libdl FFI 用，见 bits/dlfcn.h）
  static const int _rtldNow = 0x2;
  static const int _rtldGlobal = 0x100;
  static const int _rtldDeepbind = 0x8;

  static DynamicLibrary _libdl() {
    // glibc ≥ 2.34 将 dlopen 并入 libc；旧版本在 libdl.so.2
    try {
      return DynamicLibrary.open('libdl.so.2');
    } catch (_) {}
    return DynamicLibrary.open('libc.so.6');
  }

  /// 预加载 `libe_sqlite3`（SQLitePCLRaw 的 .NET 侧通过
  /// `DllImport("e_sqlite3")` 按名称解析它）。
  ///
  /// Linux 上必须带 [RTLD_DEEPBIND]：libe 内部通过 PLT 调用
  /// `sqlite3_initialize@plt` 等，默认在**全局作用域**先解析，而进程里
  /// 先加载的系统 `/usr/lib/libsqlite3.so` / Flutter bundle `libsqlite3.so`
  /// 已导出同名符号，导致 libe 初始化了别人的 sqlite3Config（或根本没
  /// 初始化）→ `sqlite3Malloc` 跳转地址 0 → 段错误。DEEPBIND 使 libe 的
  /// 未定义符号优先在自己作用域解析，命中自己导出的实现。
  ///
  /// macOS（两级命名空间）与 Windows（每模块导入表）不存在全局符号
  /// 遮蔽问题，走默认加载。
  static void _preloadSqlite(String path) {
    if (!Platform.isLinux) {
      DynamicLibrary.open(path);
      return;
    }
    final dlopen = _libdl().lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
    final cstr = path.toNativeUtf8();
    try {
      final handle = dlopen(cstr, _rtldNow | _rtldGlobal | _rtldDeepbind);
      if (handle == nullptr) {
        throw StateError('dlopen($path) 失败');
      }
    } finally {
      calloc.free(cstr);
    }
  }

  /// 加载共享库。[soPath] 为空时走 [resolveSoPath]。
  ///
  /// 先预加载同目录的 `libe_sqlite3`（见 [_preloadSqlite]），否则
  /// SQLitePCLRaw 运行期会因找不到符号失败。
  static ScannerLibrary load({String? soPath}) {
    final path = soPath ?? resolveSoPath();
    final dir = File(path).parent;
    final sqliteSo = File('${dir.path}/${_sqliteLibName()}');
    if (sqliteSo.existsSync()) {
      try {
        _preloadSqlite(sqliteSo.path);
      } catch (_) {
        // 系统库/已加载时忽略
      }
    }
    final lib = DynamicLibrary.open(path);
    return ScannerLibrary._(lib);
  }

  // ---------------------------------------------------------------- FFI

  late final _ScanDart _scan = _lib
      .lookupFunction<_ScanNative, _ScanDart>('scanner_scan');
  late final _CancelDart _cancel =
      _lib.lookupFunction<_CancelNative, _CancelDart>('scanner_cancel');
  late final _FreeDart _free =
      _lib.lookupFunction<_FreeNative, _FreeDart>('scanner_free');

  /// 同步阻塞执行扫描（须在子 isolate 调用，避免阻塞 UI 线程）。
  ///
  /// [onProgress] 为 C# 侧回调函数指针（NativeCallable.nativeFunction.cast()）。
  /// 返回 `(exitCode, resultText)`：exitCode==0 时 resultText 为 ScanResult JSON，
  /// 否则为错误文本。进度回调 JSON 与结果内存均须由调用方调 [free] 释放
  /// （回调侧由 LibraryScanner 的 listener 释放）。
  (int, String) scanBlocking({
    required List<String> dirs,
    required String dbPath,
    required String coverDir,
    required String quarantineDir,
    required bool incremental,
    required int batch,
    required int maxParallelism,
    required Pointer<Void> onProgress,
  }) {
    final dirsJson = jsonEncode(dirs).toNativeUtf8();
    final db = dbPath.toNativeUtf8();
    final cover = coverDir.toNativeUtf8();
    final quarantine = quarantineDir.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    final outLen = calloc<Int32>();
    try {
      final code = _scan(
        dirsJson,
        db,
        cover,
        quarantine,
        incremental ? 1 : 0,
        batch,
        maxParallelism,
        onProgress,
        out,
        outLen,
      );
      final resultPtr = out.value;
      final text = resultPtr == nullptr
          ? ''
          : resultPtr.cast<Utf8>().toDartString(length: outLen.value);
      if (resultPtr != nullptr) _free(resultPtr.cast());
      return (code, text);
    } finally {
      calloc.free(dirsJson);
      calloc.free(db);
      calloc.free(cover);
      calloc.free(quarantine);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// 请求取消进行中的扫描（任意线程/isolate 可调）。返回 false 表示无进行中扫描。
  bool cancel() => _cancel() == 0;

  /// 释放 scanner-ffi 侧（NativeMemory.Alloc）分配的内存。
  void free(Pointer<Void> ptr) => _free(ptr);
}

typedef _ScanNative = Int32 Function(
  Pointer<Utf8> dirsJson,
  Pointer<Utf8> dbPath,
  Pointer<Utf8> coverDir,
  Pointer<Utf8> quarantineDir,
  Int32 incremental,
  Int32 batch,
  Int32 maxParallelism,
  Pointer<Void> onProgress,
  Pointer<Pointer<Utf8>> outResult,
  Pointer<Int32> outLen,
);
typedef _ScanDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  int,
  Pointer<Void>,
  Pointer<Pointer<Utf8>>,
  Pointer<Int32>,
);

typedef _CancelNative = Int32 Function();
typedef _CancelDart = int Function();

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

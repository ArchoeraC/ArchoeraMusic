// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../log/log.dart';
import '../native_integrity.dart';
import '../native_lib_paths.dart';
import '../scanner/sqlite_preload.dart';
import 'search_models.dart';

/// indexer-ffi NativeAOT 库的定位、加载与 FFI 绑定（镜像 `ScannerLibrary`）。
///
/// 纯 FFI 层：不持有任何 isolate 本地状态，可在任意 isolate 内 [load] 后调用
/// [runBlocking] / [cancel] / [analyze]（同一进程共享句柄）。
///
/// 产物约定：`indexer/build/indexer-ffi.{so,dylib,dll}` + 同目录
/// `libe_sqlite3.{so,dylib}`（与 scanner 同版本同实例）。
///
/// 生命周期：与 scanner 一致，`indexer-ffi` 为 .NET NativeAOT（C# runtime），
/// `indexer_run` 返回后仍可能有后台线程存活且**无模块级 destroy/join**，
/// 立即 `DynamicLibrary.close()` 会 unmap 代码段导致崩溃；故**常驻、不 unload**。
class IndexerLibrary {
  IndexerLibrary._(this._lib);

  final DynamicLibrary _lib;

  // ---------------------------------------------------------------- 定位

  /// 解析 indexer-ffi 共享库路径：统一走 [NativeLibPaths]
  /// （环境变量 → ancestors 链 → dev 兜底）。
  static String resolveSoPath() {
    return NativeLibPaths.resolveRequired(
      NativeModule.indexer,
      hint: '请设置 ARCHOERA_INDEXER_FFI 环境变量',
    );
  }

  static String _sqliteLibName() {
    if (Platform.isWindows) return 'e_sqlite3.dll';
    if (Platform.isMacOS) return 'libe_sqlite3.dylib';
    return 'libe_sqlite3.so';
  }

  // ---------------------------------------------------------------- 加载

  /// 加载共享库。[soPath] 为空时走 [resolveSoPath]。
  ///
  /// 先预加载同目录的 `libe_sqlite3`（见 [preloadBundledSqlite]），否则
  /// SQLitePCLRaw 运行期会因找不到符号失败（Linux 需 RTLD_DEEPBIND
  /// 防系统 libsqlite3 全局符号遮蔽）。
  static IndexerLibrary load({String? soPath}) {
    final path = soPath ?? resolveSoPath();
    final dir = File(path).parent;
    final sqliteSo = File('${dir.path}/${_sqliteLibName()}');
    if (sqliteSo.existsSync()) {
      try {
        preloadBundledSqlite(path: sqliteSo.path);
      } catch (_) {
        // 系统库/已加载时忽略
      }
    }
    NativeIntegrity.verifyOrThrow(path);
    final lib = DynamicLibrary.open(path);
    return IndexerLibrary._(lib)..installLogSink();
  }

  /// 注入统一日志 sink（缺失符号时静默跳过，兼容旧版库）。
  void installLogSink() {
    final sink = Log.nativeWritePointer;
    if (sink == null) return;
    try {
      _lib.lookupFunction<_SetLogSinkNative, _SetLogSinkDart>(
        'indexer_set_log_sink',
      )(sink, Log.effectiveLevel);
    } catch (_) {
      // 旧版库无此符号：保持 Console 兜底。
    }
  }

  // ---------------------------------------------------------------- FFI

  late final _RunDart _run = _lib.lookupFunction<_RunNative, _RunDart>(
    'indexer_run',
  );
  late final _CancelDart _cancel = _lib
      .lookupFunction<_CancelNative, _CancelDart>('indexer_cancel');
  late final _FreeDart _free = _lib.lookupFunction<_FreeNative, _FreeDart>(
    'indexer_free',
  );
  late final _AnalyzeDart _analyze = _lib
      .lookupFunction<_AnalyzeNative, _AnalyzeDart>('indexer_analyze');

  /// 同步阻塞执行构建 / 增量（须在子 isolate 调用，避免阻塞 UI 线程）。
  ///
  /// [onProgress] 为 C# 侧回调函数指针（`NativeCallable.nativeFunction.cast()`，
  /// 可为 `nullptr.cast<Void>()` 关闭进度）。返回 `(exitCode, resultText)`：
  /// exitCode==0 时 resultText 为 `IndexerResult` JSON，否则为错误文本。进度
  /// 回调 JSON 与结果内存均须由调用方调 [free] 释放。
  (int, String) runBlocking({
    required String dbPath,
    required String indexPath,
    required bool full,
    String optionsJson = '',
    required Pointer<Void> onProgress,
  }) {
    final db = dbPath.toNativeUtf8();
    final index = indexPath.toNativeUtf8();
    final opts = optionsJson.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    final outLen = calloc<Int32>();
    try {
      final code = _run(
        db,
        index,
        full ? 1 : 0,
        opts,
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
      calloc.free(db);
      calloc.free(index);
      calloc.free(opts);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// 请求取消进行中的构建（任意线程/isolate 可调）。返回 false 表示无进行中构建。
  bool cancel() => _cancel() == 0;

  /// 分析文本，返回与索引侧同构的结构化词元；失败返回 null。
  ///
  /// [field] 对齐 C# `Field` 枚举（0=Title .. 6=Filename）；当前实现不依赖它，
  /// 仅作 ABI 契约校验。
  AnalyzerTokens? analyze(String text, {int field = 0}) {
    final textPtr = text.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    final outLen = calloc<Int32>();
    try {
      final code = _analyze(textPtr, field, out, outLen);
      final resultPtr = out.value;
      if (code != 0 || resultPtr == nullptr) {
        if (resultPtr != nullptr) _free(resultPtr.cast());
        return null;
      }
      final json = resultPtr.cast<Utf8>().toDartString(length: outLen.value);
      _free(resultPtr.cast());
      final map = jsonDecode(json) as Map<String, dynamic>;
      return AnalyzerTokens(
        lexical: _splitTokens(map['tokens'] as String?),
        pinyin: _splitTokens(map['pinyin'] as String?),
        initials: _nullIfEmpty(map['initials'] as String?),
        crossLingual: _splitTokens(map['defs'] as String?),
      );
    } catch (_) {
      return null;
    } finally {
      calloc.free(textPtr);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// 释放 indexer-ffi 侧（NativeMemory.Alloc）分配的内存。
  void free(Pointer<Void> ptr) => _free(ptr);

  static List<String> _splitTokens(String? raw) => (raw ?? '')
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  static String? _nullIfEmpty(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return raw;
  }
}

typedef _RunNative =
    Int32 Function(
      Pointer<Utf8> dbPath,
      Pointer<Utf8> indexPath,
      Int32 full,
      Pointer<Utf8> optionsJson,
      Pointer<Void> onProgress,
      Pointer<Pointer<Utf8>> outResult,
      Pointer<Int32> outLen,
    );
typedef _RunDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
      Pointer<Int32>,
    );

typedef _CancelNative = Int32 Function();
typedef _CancelDart = int Function();

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

typedef _AnalyzeNative =
    Int32 Function(
      Pointer<Utf8> text,
      Int32 field,
      Pointer<Pointer<Utf8>> outTokens,
      Pointer<Int32> outLen,
    );
typedef _AnalyzeDart =
    int Function(
      Pointer<Utf8>,
      int,
      Pointer<Pointer<Utf8>>,
      Pointer<Int32>,
    );

typedef _SetLogSinkNative =
    Void Function(Pointer<NativeFunction<LogWriteNative>> fn, Int32 minLevel);
typedef _SetLogSinkDart = void Function(
    Pointer<NativeFunction<LogWriteNative>> fn, int minLevel);

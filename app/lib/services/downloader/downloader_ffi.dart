import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// archoera-downloader cdylib 的定位、加载与 FFI 绑定。
///
/// 纯 FFI 层：不持有 isolate 本地状态，可在任意 isolate 内 [load] 后调用。
///
/// 戒律 13.1（硬约束）：本文件**永不声明** `poll_event / poll_progress / pull_event /
/// try_recv_event / event_queue_len` 等任何拉式轮询函数。事件全部以 Rust 主动调用回调
/// 指针的 PUSH 方式推送，Dart 从不拉。
///
/// 产物约定（与 audio-engine / scanner 一致的 ancestors 查找模式）：
///   `downloader/target/debug/libarchoera_downloader.{so,dylib,dll}`
///   或 release: `downloader/target/release/libarchoera_downloader.{so,dylib,dll}`。
class DownloaderLibrary {
  DownloaderLibrary._(this._lib);

  final DynamicLibrary _lib;

  // ---------------------------------------------------------------- 定位

  /// 解析 downloader 共享库路径。
  ///
  /// 优先级：
  ///  1. 环境变量 `ARCHOERA_DOWNLOADER_SO`（.so 文件路径或含库文件的目录）；
  ///  2. 从可执行文件沿父目录向上查找
  ///     `core/downloader/target/release/libarchoera_downloader.{ext}`，
  ///     再 fallback `target/debug/`；
  ///  3. dev 兜底：`flutter run` 的 cwd 为 `app/`，库在 `app/core/downloader/target/`。
  static String resolveSoPath() {
    final libName = _soFileName();

    final override = Platform.environment['ARCHOERA_DOWNLOADER_SO'];
    if (override != null && override.isNotEmpty) {
      if (File(override).existsSync()) return override;
      final asDir = '$override/$libName';
      if (File(asDir).existsSync()) return asDir;
    }

    final exe = Platform.resolvedExecutable;
    var dir = File(exe).parent;
    while (dir.path != dir.parent.path) {
      for (final flavor in const ['release', 'debug']) {
        final cand =
            File('${dir.path}/core/downloader/target/$flavor/$libName');
        if (cand.existsSync()) return cand.absolute.path;
      }
      dir = dir.parent;
    }

    for (final flavor in const ['release', 'debug']) {
      final fromCwd =
          File('${Directory.current.path}/core/downloader/target/$flavor/$libName');
      if (fromCwd.existsSync()) return fromCwd.absolute.path;
    }

    throw StateError(
        '无法定位 archoera_downloader：请设置 ARCHOERA_DOWNLOADER_SO 环境变量');
  }

  static String _soFileName() {
    if (Platform.isWindows) return 'archoera_downloader.dll';
    if (Platform.isMacOS) return 'libarchoera_downloader.dylib';
    return 'libarchoera_downloader.so';
  }

  // ---------------------------------------------------------------- 加载

  static DownloaderLibrary load({String? soPath}) {
    final path = soPath ?? resolveSoPath();
    final lib = DynamicLibrary.open(path);
    return DownloaderLibrary._(lib);
  }

  // ---------------------------------------------------------------- FFI 绑定（§8.1）

  late final _InitDart _init =
      _lib.lookupFunction<_InitNative, _InitDart>('archoera_downloader_init');
  late final _EnqueueDart _enqueue = _lib
      .lookupFunction<_EnqueueNative, _EnqueueDart>('archoera_downloader_enqueue');
  late final _CancelDart _cancel =
      _lib.lookupFunction<_CancelNative, _CancelDart>('archoera_downloader_cancel');
  late final _RetryDart _retry =
      _lib.lookupFunction<_RetryNative, _RetryDart>('archoera_downloader_retry');
  late final _PauseDart _pause =
      _lib.lookupFunction<_PauseNative, _PauseDart>('archoera_downloader_pause');
  late final _RemoveDart _remove = _lib
      .lookupFunction<_RemoveNative, _RemoveDart>('archoera_downloader_remove');
  late final _ClearDart _clear = _lib
      .lookupFunction<_ClearNative, _ClearDart>('archoera_downloader_clear');
  late final _PauseAllDart _pauseAll = _lib.lookupFunction<
      _PauseAllNative,
      _PauseAllDart>('archoera_downloader_pause_all');
  late final _ResumeAllDart _resumeAll = _lib.lookupFunction<
      _ResumeAllNative,
      _ResumeAllDart>('archoera_downloader_resume_all');
  late final _SetHistoryLimitDart _setHistoryLimit = _lib.lookupFunction<
      _SetHistoryLimitNative,
      _SetHistoryLimitDart>('archoera_downloader_set_history_limit');
  late final _SetHistoryPathDart _setHistoryPath = _lib.lookupFunction<
      _SetHistoryPathNative,
      _SetHistoryPathDart>('archoera_downloader_set_history_path');
  late final _SetMaxSpeedDart _setMaxSpeed = _lib.lookupFunction<
      _SetMaxSpeedNative,
      _SetMaxSpeedDart>('archoera_downloader_set_max_speed');
  late final _SetFilenameTemplateDart _setFilenameTemplate = _lib.lookupFunction<
      _SetFilenameTemplateNative,
      _SetFilenameTemplateDart>('archoera_downloader_set_filename_template');
  late final _ResumeDart _resume = _lib.lookupFunction<
      _ResumeNative,
      _ResumeDart>('archoera_downloader_resume_from_history');
  late final _SetKugouSessionDart _setKugouSession = _lib.lookupFunction<
      _SetKugouSessionNative,
      _SetKugouSessionDart>('archoera_downloader_set_kugou_session');
  late final _SetNeteaseCookieDart _setNeteaseCookie = _lib.lookupFunction<
      _SetNeteaseCookieNative,
      _SetNeteaseCookieDart>('archoera_downloader_set_netease_cookie');
  late final _FreeDart _free =
      _lib.lookupFunction<_FreeNative, _FreeDart>('archoera_downloader_free');
  late final _DestroyDart _destroy =
      _lib.lookupFunction<_DestroyNative, _DestroyDart>('archoera_downloader_destroy');

  /// 初始化下载引擎（启动时一次，唯一允许注册回调指针的入口）。
  ///
  /// [eventCb] 必须来自 `NativeCallable.listener(...).nativeFunction.cast<Void>()`；
  /// [freeFn] 可空：当 Dart 侧有自定义分配器时传入，否则传 `null`，Rust 会用默认
  /// `CString::from_raw` 释放。
  int init({
    required String rootDir,
    required int subdirStrategy,
    required int maxConcurrent,
    required Pointer<Void> eventCb,
    Pointer<Void>? freeFn,
  }) {
    final root = rootDir.toNativeUtf8();
    try {
      return _init(root, subdirStrategy, maxConcurrent, eventCb, freeFn ?? nullptr);
    } finally {
      calloc.free(root);
    }
  }

  /// 入队下载任务。返回 `(code, taskId)`；code==0 时 taskId 为 UUID v4 字符串。
  /// 返回的 taskId C 字符串由 Rust 分配，本方法读取后立即 [free] 释放。
  (int code, String taskId) enqueue(Map<String, dynamic> requestJson) {
    final req = jsonEncode(requestJson).toNativeUtf8();
    final outId = calloc<Pointer<Utf8>>();
    try {
      final code = _enqueue(req, outId);
      if (code != 0) return (code, '');
      final p = outId.value;
      if (p == nullptr) return (code, '');
      final tid = p.toDartString();
      _free(p.cast<Void>());
      return (code, tid);
    } finally {
      calloc.free(req);
      calloc.free(outId);
    }
  }

  int cancel(String taskId) {
    final p = taskId.toNativeUtf8();
    try {
      return _cancel(p);
    } finally {
      calloc.free(p);
    }
  }

  int retry(String taskId) {
    final p = taskId.toNativeUtf8();
    try {
      return _retry(p);
    } finally {
      calloc.free(p);
    }
  }

  /// 暂停任务（v2）：保留 .tmp 供恢复续传；恢复走 [retry]。
  int pause(String taskId) {
    final p = taskId.toNativeUtf8();
    try {
      return _pause(p);
    } finally {
      calloc.free(p);
    }
  }

  /// 移除下载任务：删除任务项 + .tmp 缓存；[deleteFile] 为 true 时
  /// 精确删除该任务记录的目标文件（仅任务自己的 dest，不做模糊匹配）。
  int remove(String taskId, {bool deleteFile = false}) {
    final p = taskId.toNativeUtf8();
    try {
      return _remove(p, deleteFile ? 1 : 0);
    } finally {
      calloc.free(p);
    }
  }

  /// 一键清空下载任务：所有任务项 + .tmp 缓存；[deleteFiles] 为 true 时
  /// 精确删除各任务记录的目标文件。
  int clear({bool deleteFiles = false}) => _clear(deleteFiles ? 1 : 0);

  /// 全部暂停：queued 立即暂停，running/resolving 在下一个检查点退出并保留 .tmp。
  int pauseAll() => _pauseAll();

  /// 全部开始：恢复所有暂停任务（续传）并重试所有失败任务。
  int resumeAll() => _resumeAll();

  /// 设置下载记录上限（finished 条目超过该值淘汰最旧；<=0 恢复默认 100）。
  int setHistoryLimit(int limit) => _setHistoryLimit(limit);

  /// 设置下载历史文件路径（v2：重启恢复；路径由 Dart 决定，内容 Rust 管理）。
  int setHistoryPath(String path) {
    final p = path.toNativeUtf8();
    try {
      return _setHistoryPath(p);
    } finally {
      calloc.free(p);
    }
  }

  /// 设置全局限速（bytes/sec；0 = 不限速）。立即生效。
  int setMaxSpeed(int bytesPerSec) => _setMaxSpeed(bytesPerSec);

  /// 设置文件名模板（占位符 {artist}/{title}/{album}；空串恢复默认）。
  /// 只影响之后入队的任务。Rust init 默认 "{artist} - {title}"。
  int setFilenameTemplate(String template) {
    final p = template.toNativeUtf8();
    try {
      return _setFilenameTemplate(p);
    } finally {
      calloc.free(p);
    }
  }

  /// 重启恢复：恢复历史中的进行中任务并续传；返回恢复的任务数。
  int resumeFromHistory() => _resume();

  int setKugouSession(String userid, String token) {
    final u = userid.toNativeUtf8();
    final t = token.toNativeUtf8();
    try {
      return _setKugouSession(u, t);
    } finally {
      calloc.free(u);
      calloc.free(t);
    }
  }

  int setNeteaseCookie(String cookieHeader) {
    final c = cookieHeader.toNativeUtf8();
    try {
      return _setNeteaseCookie(c);
    } finally {
      calloc.free(c);
    }
  }

  /// 释放 Rust 分配的 C 字符串（task_id、回调事件 ptr 都要调）。
  void free(Pointer<Void> ptr) => _free(ptr);

  void destroy() => _destroy();
}

// ============================================================
// §8.1 C ABI typedef（Native <-> Dart）
// ============================================================

typedef _InitNative = Int32 Function(
  Pointer<Utf8> rootDir,
  Int32 subdirStrategy,
  Int32 maxConcurrent,
  Pointer<Void> eventCb,
  Pointer<Void> freeFn,
);
typedef _InitDart = int Function(
  Pointer<Utf8>, int, int, Pointer<Void>, Pointer<Void>
);

typedef _EnqueueNative = Int32 Function(
  Pointer<Utf8> requestJson,
  Pointer<Pointer<Utf8>> outTaskId,
);
typedef _EnqueueDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);

typedef _CancelNative = Int32 Function(Pointer<Utf8> taskId);
typedef _CancelDart = int Function(Pointer<Utf8>);

typedef _RetryNative = Int32 Function(Pointer<Utf8> taskId);
typedef _RetryDart = int Function(Pointer<Utf8>);

typedef _PauseNative = Int32 Function(Pointer<Utf8> taskId);
typedef _PauseDart = int Function(Pointer<Utf8>);

typedef _RemoveNative = Int32 Function(Pointer<Utf8> taskId, Int32 deleteFile);
typedef _RemoveDart = int Function(Pointer<Utf8>, int);

typedef _ClearNative = Int32 Function(Int32 deleteFiles);
typedef _ClearDart = int Function(int);

typedef _PauseAllNative = Int32 Function();
typedef _PauseAllDart = int Function();

typedef _ResumeAllNative = Int32 Function();
typedef _ResumeAllDart = int Function();

typedef _SetHistoryLimitNative = Int32 Function(Int32 limit);
typedef _SetHistoryLimitDart = int Function(int);

typedef _SetHistoryPathNative = Int32 Function(Pointer<Utf8> path);
typedef _SetHistoryPathDart = int Function(Pointer<Utf8>);

typedef _SetMaxSpeedNative = Int32 Function(Int64 bytesPerSec);
typedef _SetMaxSpeedDart = int Function(int);

typedef _SetFilenameTemplateNative = Int32 Function(Pointer<Utf8> template);
typedef _SetFilenameTemplateDart = int Function(Pointer<Utf8>);

typedef _ResumeNative = Int32 Function();
typedef _ResumeDart = int Function();

typedef _SetKugouSessionNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SetKugouSessionDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _SetNeteaseCookieNative = Int32 Function(Pointer<Utf8>);
typedef _SetNeteaseCookieDart = int Function(Pointer<Utf8>);

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

typedef _DestroyNative = Void Function();
typedef _DestroyDart = void Function();

/// §8.2 Rust 回调签名（对齐 library_scanner）
///
/// ```c
/// typedef void(*EventCallback)(char* json_cstring);
/// ```
typedef EventCallbackNative = Void Function(Pointer<Utf8> json);
typedef EventCallbackDart = void Function(Pointer<Utf8> json);

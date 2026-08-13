import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'downloader_ffi.dart';

/// 下载引擎高层封装：持有 [DownloaderLibrary] + NativeCallable 回调。
///
/// 戒律 13.1（硬约束）：本类**永不使用** `Timer.periodic` / `Stream.periodic` /
/// 任何形式 `poll_*()` 拉取下载进度。进度/状态变更**只能**来自 Rust 侧
/// `event_cb` 主动 push 到 [_handleEvent] → [_eventController].add。
///
/// 戒律 13.2（硬约束）：本类**绝不执行**以下任何业务逻辑（全部下沉到 Rust）：
///  - 计算 destPath / tmpPath / 做非法字符替换 / 做去重检查
///  - 调用任何 `KugouApi.resolvePlayUrl` / Netease `song_download_url` 拿 URL
///  - 使用 `dart:io` 写下载文件
///  - 自己存第二份 Kugou / Netease 登录态（登录后立即 set_* 注入 Rust）
///
/// 生命周期：`init()` → `enqueue()` 多次 → `dispose()`（内部 destroy）。
class DownloaderEngine {
  DownloaderEngine({this._soPath});

  final String? _soPath;
  late final DownloaderLibrary _lib;
  late final NativeCallable<Void Function(Pointer<Utf8>)> _eventCallable;
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 原始事件流（每条事件是 Rust 推送的 JSON 解析后的 Map）。
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  // ---------------------------------------------------------------- 生命周期

  /// 初始化（启动时一次）。
  ///
  /// [rootDir] 下载根目录（Scanner 可识别）；
  /// [subdirStrategy] 0=flat, 1=bySource, 2=byArtist(v2)；
  /// [maxConcurrent] 同时下载最大任务数（默认 3）；
  /// [historyPath] 下载历史文件路径（v2 重启恢复；null = 不持久化）；
  /// [maxSpeedBytes] 全局限速 bytes/sec（0 = 不限速）；
  /// [filenameTemplate] 文件名模板（占位符 {artist}/{title}/{album}；
  /// null = 用 Rust 默认 "{artist} - {title}"）。
  ///
  /// 初始化成功后内部自动：注入历史路径 → 恢复上次未完成任务（断点续传）→
  /// 应用限速。返回 code，0 = 成功。
  Future<int> init({
    required String rootDir,
    int subdirStrategy = 1,
    int maxConcurrent = 3,
    String? historyPath,
    int maxSpeedBytes = 0,
    String? filenameTemplate,
  }) async {
    if (_initialized) throw StateError('DownloaderEngine 已初始化');
    _lib = DownloaderLibrary.load(soPath: _soPath);
    _eventCallable = NativeCallable<Void Function(Pointer<Utf8>)>.listener(
      _handleEvent,
    );

    final code = _lib.init(
      rootDir: rootDir,
      subdirStrategy: subdirStrategy,
      maxConcurrent: maxConcurrent,
      eventCb: _eventCallable.nativeFunction.cast<Void>(),
      freeFn: null,
    );
    _initialized = code == 0;
    if (_initialized) {
      if (historyPath != null && historyPath.isNotEmpty) {
        _lib.setHistoryPath(historyPath);
      }
      _lib.setMaxSpeed(maxSpeedBytes);
      if (filenameTemplate != null && filenameTemplate.isNotEmpty) {
        _lib.setFilenameTemplate(filenameTemplate);
      }
      // 重启恢复：读历史中的进行中任务（.tmp 续传 / 重新入队），并清理孤儿 .tmp
      try {
        _lib.resumeFromHistory();
      } catch (_) {}
    }
    return code;
  }

  void dispose() {
    try {
      _lib.destroy();
    } catch (_) {}
    try {
      _eventCallable.close();
    } catch (_) {}
    _eventController.close();
    _initialized = false;
  }

  // ---------------------------------------------------------------- 操作接口

  /// 入队下载任务。[requestJson] 结构见 §12 enqueue 请求协议（或 DownloadRequest）。
  ///
  /// 戒律 13.2：requestJson 只传 Track 基本信息（title/artist/quality...），
  /// **绝不**传 pre-resolved URL；URL 解析全在 Rust 内部。
  (int code, String taskId) enqueue(Map<String, dynamic> requestJson) {
    _ensureInit();
    return _lib.enqueue(requestJson);
  }

  int cancel(String taskId) {
    _ensureInit();
    return _lib.cancel(taskId);
  }

  int retry(String taskId) {
    _ensureInit();
    return _lib.retry(taskId);
  }

  /// 暂停任务（v2）：保留 .tmp 供恢复续传；恢复走 [retry]。
  int pause(String taskId) {
    _ensureInit();
    return _lib.pause(taskId);
  }

  /// 移除下载任务：删除任务项 + .tmp 缓存；[deleteFile] 为 true 时精确删除
  /// 该任务记录的目标文件（仅任务自己的 dest，不做模糊匹配）。
  int remove(String taskId, {bool deleteFile = false}) {
    _ensureInit();
    return _lib.remove(taskId, deleteFile: deleteFile);
  }

  /// 一键清空下载任务：所有任务项 + .tmp 缓存；[deleteFiles] 为 true 时
  /// 精确删除各任务记录的目标文件。
  int clear({bool deleteFiles = false}) {
    _ensureInit();
    return _lib.clear(deleteFiles: deleteFiles);
  }

  /// 全部暂停：queued 立即暂停，running/resolving 在下一个检查点退出并保留 .tmp。
  int pauseAll() {
    _ensureInit();
    return _lib.pauseAll();
  }

  /// 全部开始：恢复所有暂停任务（续传）并重试所有失败任务。
  int resumeAll() {
    _ensureInit();
    return _lib.resumeAll();
  }

  /// 设置下载记录上限（finished 条目超过该值淘汰最旧；<=0 恢复默认 100）。
  int setHistoryLimit(int limit) {
    _ensureInit();
    return _lib.setHistoryLimit(limit);
  }

  /// 设置全局限速（bytes/sec；0 = 不限速）。立即生效，可随时调整。
  int setMaxSpeed(int bytesPerSec) {
    _ensureInit();
    return _lib.setMaxSpeed(bytesPerSec);
  }

  /// 设置文件名模板（占位符 {artist}/{title}/{album}；空串恢复默认）。
  /// 只影响之后入队的任务，不回溯已有任务。
  int setFilenameTemplate(String template) {
    _ensureInit();
    return _lib.setFilenameTemplate(template);
  }

  /// 注入下载历史文件路径（v2）。通常由 init 内部完成，仅特殊场景手动调用。
  int setHistoryPath(String path) {
    _ensureInit();
    return _lib.setHistoryPath(path);
  }

  /// 恢复历史中的进行中任务（断点续传）。通常由 init 内部完成。
  int resumeFromHistory() {
    _ensureInit();
    return _lib.resumeFromHistory();
  }

  /// Dart 侧登录成功后立即调此注入，Rust 内部永远只以自己的状态为准。
  int setKugouSession(String userid, String token) {
    _ensureInit();
    return _lib.setKugouSession(userid, token);
  }

  int setNeteaseCookie(String cookieHeader) {
    _ensureInit();
    return _lib.setNeteaseCookie(cookieHeader);
  }

  /// 注入设备指纹（init 后调用；Dart 首次生成持久化的 downloaderIdentity JSON）。
  /// 幂等，引擎重建时重复注入同值。
  int setDownloaderIdentity(String identityJson) {
    _ensureInit();
    return _lib.setDownloaderIdentity(identityJson);
  }

  /// 清除设备指纹（动态指纹开关开启路径）：回退旧版「每次启动随机」动态值
  /// 行为（酷狗 mid 下一次取值惰性生成会话随机；网易 cookie 字段回落随机）。
  int clearDownloaderIdentity() {
    _ensureInit();
    return _lib.clearDownloaderIdentity();
  }

  // ---------------------------------------------------------------- 回调入口

  /// Rust 推送事件 → NativeCallable 触发 → 此处执行。
  ///
  /// 戒律 13.3：
  ///  ① 第 2 行（toDartString 之后）**必须立即 `_lib.free(ptr)`**，否则内存泄漏；
  ///  ② 解析失败只吞异常，不 rethrow（不中断 Rust 后续回调）。
  void _handleEvent(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return;
    final str = ptr.toDartString();
    // 戒律 13.3 第 ① 条：必须 free
    try {
      _lib.free(ptr.cast<Void>());
    } catch (_) {}
    try {
      final json = jsonDecode(str) as Map<String, dynamic>;
      if (!_eventController.isClosed) {
        _eventController.add(json);
      }
    } catch (e, st) {
      debugPrint('DownloaderEngine 事件解析失败: $e\n$st');
    }
  }

  void _ensureInit() {
    if (!_initialized) throw StateError('DownloaderEngine 未初始化，先调 init()');
  }
}

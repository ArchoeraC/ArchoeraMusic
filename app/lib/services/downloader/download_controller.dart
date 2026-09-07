// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 下载任务状态机 + 引擎生命周期管理（UI 唯一入口）。
///
/// 职责边界（戒律 13.2）：本文件**不做** URL 解析 / 路径计算 / 文件写入 /
/// 并发控制——全部在 Rust cdylib 内。本控制器只做三件事：
///   ① 持有 [DownloaderEngine]，启动时 init（配置来自 AppPrefs）并在配置
///      变更时重建引擎；
///   ② 订阅引擎事件流（唯一通道，无轮询），把 Rust push 的事件翻译成
///      任务状态机的更新（queued / resolving / running / failed /
///      canceled / done / already）；
///   ③ 向引擎注入登录态（Kugou session / Netease cookie），登录/登出后
///      由外部调 [syncSessions] 重新注入。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../netease/track.dart';
import '../../stores/app_prefs.dart';
import '../../stores/data_dir.dart';
import '../../stores/providers.dart';
import 'downloader_engine.dart';

part 'download_controller/download_controller_core.dart';
part 'download_controller/download_controller_actions.dart';
part 'download_controller/download_controller_events.dart';
part 'download_controller/download_controller_request.dart';

// ----------------------------------------------------------------
// 配置派生 provider：只跟踪下载相关字段，避免任意设置变更触发引擎重建
// ----------------------------------------------------------------

/// 下载配置（rootDir / subdirStrategy / maxConcurrent）。
///
/// 独立于 [appPrefsProvider] 派生：只有下载相关字段变化时才重建依赖方
/// （否则改个主色都会导致下载引擎重建、在途任务被清）。
/// 注意：限速字段**不在此**（见 [downloadSpeedLimitProvider]），
/// 否则改限速会触发引擎重建、打断在途任务。
class DownloadPrefs {
  const DownloadPrefs({
    required this.rootDir,
    required this.subdirStrategy,
    required this.maxConcurrent,
  });

  final String rootDir;
  final int subdirStrategy;
  final int maxConcurrent;
}

final downloadPrefsProvider = Provider<DownloadPrefs>((ref) {
  final prefs = ref.watch(appPrefsProvider);
  return DownloadPrefs(
    rootDir: prefs.downloadRoot,
    subdirStrategy: prefs.downloadSubdirStrategy,
    maxConcurrent: prefs.downloadMaxConcurrent,
  );
});

/// 全局限速 bytes/sec（0 = 不限速）。
///
/// 独立 provider：变更时只调 [DownloadController.setMaxSpeed] 实时应用，
/// **不**触发引擎重建（避免打断在途下载任务）。
final downloadSpeedLimitProvider = Provider<int>((ref) {
  return ref.watch(appPrefsProvider).downloadSpeedLimit;
});

/// 文件名模板（占位符 {artist}/{title}/{album}；默认 "{artist} - {title}"）。
///
/// 独立 provider：只影响之后入队的任务，变更实时注入 Rust，不触发引擎重建。
final downloadFilenameTemplateProvider = Provider<String>((ref) {
  return ref.watch(appPrefsProvider).downloadFilenameTemplate;
});

/// 下载记录上限（finished 条目超过该值淘汰最旧，10~500，默认 100）。
///
/// 独立 provider：变更实时注入 Rust，不触发引擎重建（避免打断在途任务）。
final downloadHistoryLimitProvider = Provider<int>((ref) {
  return ref.watch(appPrefsProvider).downloadHistoryLimit;
});

// ----------------------------------------------------------------
// 下载任务模型
// ----------------------------------------------------------------

/// 单任务 UI 态（事件驱动更新，字段全部来自 Rust 事件 + enqueue 时元数据）。
@immutable
class DownloadTask {
  const DownloadTask({
    required this.taskId,
    this.trackId = '',
    this.source = '',
    this.platformId = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.quality = '',
    this.status = 'queued',
    this.error,
    this.retryable = false,
    this.stage,
    this.received = 0,
    this.total,
    this.filePath,
    this.fileSize,
    this.actualQuality,
    this.speed = 0,
  });

  /// Rust 侧 taskId（UUID v4；重试复用，生命周期内稳定）。
  final String taskId;

  /// 本地 Track 主键（enqueue 元数据，用于重复入队识别）。
  final String trackId;
  final String source;
  final String platformId;
  final String title;
  final String artist;
  final String album;

  /// 请求音质档（lq/sq/hq/lossless/hi-res）。
  final String quality;

  /// 任务状态（对齐设计稿 §4：queued/resolving/running/failed/
  /// canceled/done/already）。
  final String status;
  final String? error;
  final bool retryable;

  /// 失败阶段（resolving / downloading，来自 Error 事件）。
  final String? stage;

  /// 已下载字节（progress 事件节流 500ms 更新）。
  final int received;
  final int? total;
  final String? filePath;
  final int? fileSize;

  /// 实时下载速度 bytes/sec（progress 事件携带；非下载态为 0）。
  final int speed;

  /// 实际命中的品质 key（'128k'/'320k'/'flac'/'flac24bit'，done 事件携带）。
  final String? actualQuality;

  bool get isActive =>
      status == 'queued' || status == 'resolving' || status == 'running';

  /// 是否处于暂停态（v2：保留 .tmp，可 [DownloadController.pause] 暂停 / retry 恢复）。
  bool get isPaused => status == 'paused';

  bool get isDone => status == 'done' || status == 'already';

  bool get isFailed => status == 'failed' || status == 'canceled';

  /// 进度 0~1；无 total（未知大小）返回 null（UI 显示不定进度）。
  double? get progress {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }

  /// 展示名（歌手 - 歌名）。
  String get displayName {
    final a = artist.trim();
    final t = title.trim();
    if (a.isEmpty) return t.isEmpty ? '未知名歌曲' : t;
    return t.isEmpty ? a : '$a - $t';
  }

  DownloadTask copyWith({
    String? trackId,
    String? source,
    String? platformId,
    String? title,
    String? artist,
    String? album,
    String? quality,
    String? status,
    String? error,
    bool? retryable,
    String? stage,
    int? received,
    int? total,
    String? filePath,
    int? fileSize,
    String? actualQuality,
    int? speed,
  }) => DownloadTask(
    taskId: taskId,
    trackId: trackId ?? this.trackId,
    source: source ?? this.source,
    platformId: platformId ?? this.platformId,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    quality: quality ?? this.quality,
    status: status ?? this.status,
    error: error ?? this.error,
    retryable: retryable ?? this.retryable,
    stage: stage ?? this.stage,
    received: received ?? this.received,
    total: total ?? this.total,
    filePath: filePath ?? this.filePath,
    fileSize: fileSize ?? this.fileSize,
    actualQuality: actualQuality ?? this.actualQuality,
    speed: speed ?? this.speed,
  );
}

// ----------------------------------------------------------------
// 控制器状态
// ----------------------------------------------------------------

class DownloadState {
  const DownloadState({
    this.initializing = true,
    this.initError,
    this.tasks = const [],
  });

  /// 引擎是否正在初始化。
  final bool initializing;

  /// 引擎初始化失败原因（成功为 null）。
  final String? initError;

  /// 任务列表（入队顺序，新任务追加在尾部）。
  final List<DownloadTask> tasks;

  int get activeCount => tasks.where((t) => t.isActive).length;

  int get doneCount => tasks.where((t) => t.isDone).length;

  DownloadState copyWith({
    bool? initializing,
    String? initError,
    List<DownloadTask>? tasks,
  }) => DownloadState(
    initializing: initializing ?? this.initializing,
    initError: initError ?? this.initError,
    tasks: tasks ?? this.tasks,
  );
}

// ----------------------------------------------------------------
// 控制器
// ----------------------------------------------------------------

/// 下载控制器：引擎生命周期 + 事件 → 任务状态机 + 登录态注入。
class DownloadController extends Notifier<DownloadState>
    with
        _DownloadControllerCore,
        _DownloadControllerEvents,
        _DownloadControllerActions {
  @override
  DownloaderEngine? _engine;
  @override
  StreamSubscription<Map<String, dynamic>>? _eventsSub;

  /// 引擎重建代际：配置变更触发重建时，旧 init 的异步结果必须丢弃。
  @override
  int _gen = 0;

  /// 已删除/已清空的任务 id：Rust 异步退出的残留事件一律忽略，
  /// 避免 remove/clear 后任务「复活」。
  @override
  final Set<String> _removedIds = {};

  @override
  DownloadState build() => _buildState();

  // ── 操作接口 ────────────────────────────────────────────────

  /// 入队下载。[track] 只提供元数据，URL 解析全在 Rust。
  ///
  /// [quality] 缺省时取设置里的默认下载音质（prefs.downloadQuality）。
  /// 返回 taskId；引擎未就绪或入队失败返回 null。
  String? enqueue(Track track, {String? quality}) =>
      _enqueue(track, quality: quality);

  /// 取消任务（queued 立即移除；运行中在下一个 await 点退出并清理 tmp）。
  void cancel(String taskId) => _cancel(taskId);

  /// 重试失败/已取消任务（Rust 复用原 taskId，URL 重新解析）。
  /// 对暂停任务调用即恢复续传（.tmp 存在走 Range 续传）。
  void retry(String taskId) => _retry(taskId);

  /// 暂停任务（v2）：保留 .tmp，[retry] 恢复续传。
  /// queued 任务立即移除；resolving/downloading 在下一个 await 点退出。
  void pause(String taskId) => _pause(taskId);

  /// 移除下载任务：删除任务项 + .tmp 缓存；[deleteFile] 为 true 时精确删除
  /// 该任务记录的目标文件（仅任务自己的 dest，不做模糊匹配）。
  void removeTask(String taskId, {bool deleteFile = false}) =>
      _removeTask(taskId, deleteFile: deleteFile);

  /// 一键清空下载任务：删除所有任务项 + .tmp 缓存；[deleteFiles] 为 true 时
  /// 精确删除各任务记录的目标文件。
  void clearTasks({bool deleteFiles = false}) =>
      _clearTasks(deleteFiles: deleteFiles);

  /// 全部暂停：queued 立即暂停，running/resolving 在下一个检查点退出并保留 .tmp。
  void pauseAll() => _pauseAll();

  /// 全部开始：恢复所有暂停任务（续传）并重试所有失败任务。
  void resumeAll() => _resumeAll();

  /// 批量移除选中的任务；[deleteFile] 为 true 时附带精确删除媒体文件。
  void removeTasks(Iterable<String> taskIds, {bool deleteFile = false}) =>
      _removeTasks(taskIds, deleteFile: deleteFile);

  /// 设置全局限速（bytes/sec；0 = 不限速），立即生效。
  void setMaxSpeed(int bytesPerSec) => _setMaxSpeed(bytesPerSec);

  /// 会话同步：登录 / 登出后重新注入 Rust（幂等）。顺带重注入设备指纹，
  /// 供设置页「重置设备指纹」即时生效（否则要等下次引擎重建）。
  void syncSessions() => _syncSessions();

  // ── 事件 → 状态机 ───────────────────────────────────────────
}

final downloadControllerProvider =
    NotifierProvider<DownloadController, DownloadState>(DownloadController.new);

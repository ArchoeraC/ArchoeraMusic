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
class DownloadController extends Notifier<DownloadState> {
  DownloaderEngine? _engine;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;

  /// 引擎重建代际：配置变更触发重建时，旧 init 的异步结果必须丢弃。
  int _gen = 0;

  /// 已删除/已清空的任务 id：Rust 异步退出的残留事件一律忽略，
  /// 避免 remove/clear 后任务「复活」。
  final Set<String> _removedIds = {};

  @override
  DownloadState build() {
    final prefs = ref.watch(downloadPrefsProvider);
    _gen += 1;
    final gen = _gen;
    _initEngine(
      rootDir: prefs.rootDir,
      subdirStrategy: prefs.subdirStrategy,
      maxConcurrent: prefs.maxConcurrent,
      speedLimit: ref.read(downloadSpeedLimitProvider),
      filenameTemplate: ref.read(downloadFilenameTemplateProvider),
      historyLimit: ref.read(downloadHistoryLimitProvider),
      gen: gen,
    );
    // 限速变更：不重建引擎，实时 apply（不打断在途任务）
    ref.listen(downloadSpeedLimitProvider, (_, next) => setMaxSpeed(next));
    // 文件名模板变更：只影响之后入队的任务，实时注入即可
    ref.listen(downloadFilenameTemplateProvider, (_, next) {
      final engine = _engine;
      if (engine != null && engine.isInitialized) {
        engine.setFilenameTemplate(next);
      }
    });
    // 记录上限变更：实时注入并立即裁剪
    ref.listen(downloadHistoryLimitProvider, (_, next) {
      final engine = _engine;
      if (engine != null && engine.isInitialized) {
        engine.setHistoryLimit(next);
      }
      _pruneHistory(); // Rust 裁剪不发事件，UI 同步淘汰最旧
    });
    ref.onDispose(_teardown);
    return const DownloadState();
  }

  void _teardown() {
    _gen += 1; // 使在途 init 失效
    _eventsSub?.cancel();
    _eventsSub = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      try {
        engine.dispose();
      } catch (_) {}
    }
  }

  Future<void> _initEngine({
    required String rootDir,
    required int subdirStrategy,
    required int maxConcurrent,
    required int speedLimit,
    required String filenameTemplate,
    required int historyLimit,
    required int gen,
  }) async {
    DownloaderEngine engine;
    try {
      engine = DownloaderEngine();
      final code = await engine.init(
        rootDir: rootDir,
        subdirStrategy: subdirStrategy,
        maxConcurrent: maxConcurrent,
        historyPath: '${resolveDataDir()}/download_history.json',
        maxSpeedBytes: speedLimit,
        filenameTemplate: filenameTemplate,
      );
      if (gen != _gen) {
        // 已被配置变更重建，丢弃本次初始化
        try {
          engine.dispose();
        } catch (_) {}
        return;
      }
      if (code != 0) {
        try {
          engine.dispose();
        } catch (_) {}
        state = state.copyWith(
          initializing: false,
          initError: '下载引擎初始化失败（code=$code）',
        );
        return;
      }
    } catch (e) {
      if (gen != _gen) return;
      state = state.copyWith(initializing: false, initError: '下载引擎初始化失败：$e');
      return;
    }
    _engine = engine;
    _eventsSub = engine.events.listen(_handleEvent);
    engine.setHistoryLimit(historyLimit);
    _injectIdentity();
    _injectSessions();
    state = state.copyWith(initializing: false, initError: null);
  }

  // ── 操作接口 ────────────────────────────────────────────────

  /// 入队下载。[track] 只提供元数据，URL 解析全在 Rust。
  ///
  /// [quality] 缺省时取设置里的默认下载音质（prefs.downloadQuality）。
  /// 返回 taskId；引擎未就绪或入队失败返回 null。
  String? enqueue(Track track, {String? quality}) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return null;
    final q = quality ?? ref.read(appPrefsProvider).downloadQuality;
    final (code, taskId) = engine.enqueue(
      buildDownloadRequest(track, quality: q),
    );
    if (code != 0 || taskId.isEmpty) return null;
    // 事件可能在 enqueue 同步回调期间已创建占位任务（无元数据）→ 合并元数据。
    // 同一任务重复入队（Rust 去重返回相同 taskId）也走此路径，元数据幂等。
    _applyTask(
      taskId,
      (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
        trackId: track.id,
        source: track.source,
        platformId: track.id,
        title: track.title,
        artist: track.artistNames,
        album: track.album?.name ?? '',
        quality: q,
      ),
    );
    return taskId;
  }

  /// 取消任务（queued 立即移除；运行中在下一个 await 点退出并清理 tmp）。
  void cancel(String taskId) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.cancel(taskId);
    // 先置 canceled，随后 Rust 的 Error(已取消) 事件是幂等覆盖。
    _applyTask(
      taskId,
      (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
        status: 'canceled',
        error: '已取消',
        retryable: false,
      ),
    );
  }

  /// 重试失败/已取消任务（Rust 复用原 taskId，URL 重新解析）。
  /// 对暂停任务调用即恢复续传（.tmp 存在走 Range 续传）。
  void retry(String taskId) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.retry(taskId);
  }

  /// 暂停任务（v2）：保留 .tmp，[retry] 恢复续传。
  /// queued 任务立即移除；resolving/downloading 在下一个 await 点退出。
  void pause(String taskId) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.pause(taskId);
    // 本地乐观置 paused（Rust 随后推 state 事件幂等覆盖）。
    _applyTask(
      taskId,
      (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
        status: 'paused',
        speed: 0,
      ),
    );
  }

  /// 移除下载任务：删除任务项 + .tmp 缓存；[deleteFile] 为 true 时精确删除
  /// 该任务记录的目标文件（仅任务自己的 dest，不做模糊匹配）。
  void removeTask(String taskId, {bool deleteFile = false}) {
    _removedIds.add(taskId);
    final engine = _engine;
    if (engine != null && engine.isInitialized) {
      engine.remove(taskId, deleteFile: deleteFile);
    }
    // 本地立即移除；running 任务异步退出的残留事件已被 [removedIds] 忽略
    state = state.copyWith(
      tasks: state.tasks.where((t) => t.taskId != taskId).toList(),
    );
  }

  /// 一键清空下载任务：删除所有任务项 + .tmp 缓存；[deleteFiles] 为 true 时
  /// 精确删除各任务记录的目标文件。
  void clearTasks({bool deleteFiles = false}) {
    final engine = _engine;
    if (engine != null && engine.isInitialized) {
      engine.clear(deleteFiles: deleteFiles);
    }
    _removedIds.addAll(state.tasks.map((t) => t.taskId));
    state = state.copyWith(tasks: const []);
  }

  /// 全部暂停：queued 立即暂停，running/resolving 在下一个检查点退出并保留 .tmp。
  void pauseAll() {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.pauseAll();
    // queued → paused 由 Rust 同步推 state；running 由下载循环推
    final tasks = state.tasks
        .map((t) => t.isActive ? t.copyWith(status: 'paused', speed: 0) : t)
        .toList();
    state = state.copyWith(tasks: tasks);
  }

  /// 全部开始：恢复所有暂停任务（续传）并重试所有失败任务。
  void resumeAll() {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.resumeAll();
    // 状态由 Rust 推 state 事件驱动（resolving/queued）
  }

  /// 批量移除选中的任务；[deleteFile] 为 true 时附带精确删除媒体文件。
  void removeTasks(Iterable<String> taskIds, {bool deleteFile = false}) {
    final ids = taskIds.toSet();
    if (ids.isEmpty) return;
    _removedIds.addAll(ids);
    final engine = _engine;
    if (engine != null && engine.isInitialized) {
      for (final id in ids) {
        engine.remove(id, deleteFile: deleteFile);
      }
    }
    state = state.copyWith(
      tasks: state.tasks.where((t) => !ids.contains(t.taskId)).toList(),
    );
  }

  /// 设置全局限速（bytes/sec；0 = 不限速），立即生效。
  void setMaxSpeed(int bytesPerSec) {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    engine.setMaxSpeed(bytesPerSec);
  }

  /// 会话同步：登录 / 登出后重新注入 Rust（幂等）。顺带重注入设备指纹，
  /// 供设置页「重置设备指纹」即时生效（否则要等下次引擎重建）。
  void syncSessions() {
    _injectIdentity();
    _injectSessions();
  }

  /// 设备指纹注入/清除：按「动态指纹」开关分流。
  ///
  /// 开关关（默认）：首次启动生成并持久化到 prefs，此后跨会话不变；引擎
  /// 每次 init（含配置变更重建）后注入同值（幂等）。
  /// 开关开：回退旧版「每次启动随机」动态值——不注入、不生成持久化指纹，
  /// 并清除 Rust 侧已注入值（Rust 回落会话随机，见 clear_identity）。
  void _injectIdentity() {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    final prefs = ref.read(appPrefsProvider);
    if (prefs.downloadDynamicFingerprint) {
      engine.clearDownloaderIdentity();
      return;
    }
    var identity = prefs.downloaderIdentity;
    if (identity == null) {
      identity = jsonEncode(generateDownloaderIdentity());
      ref.read(appPrefsProvider.notifier).setDownloaderIdentity(identity);
    }
    engine.setDownloaderIdentity(identity);
  }

  void _injectSessions() {
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    // Kugou：登录会话（token/userid）
    final kugou = ref.read(kugouApiProvider).session;
    if (kugou != null && kugou.userid.isNotEmpty && kugou.token.isNotEmpty) {
      engine.setKugouSession(kugou.userid, kugou.token);
    }
    // Netease：持久化 cookie（经 vault 会话存储解密读取）
    final cookies = getRuntime().sessionStore.get('netease');
    if (cookies.isNotEmpty) {
      engine.setNeteaseCookie(
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
  }

  // ── 事件 → 状态机 ───────────────────────────────────────────

  void _handleEvent(Map<String, dynamic> evt) {
    final taskId = evt['taskId'] as String?;
    if (taskId == null || taskId.isEmpty) return;
    // 已删除/已清空的任务：Rust 异步退出的残留事件忽略（防「复活」）
    if (_removedIds.contains(taskId)) return;
    switch (evt['type'] as String?) {
      case 'state':
        final to = evt['to'] as String? ?? 'queued';
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: to,
            // 进入暂停/终态时速度归零
            speed:
                (to == 'paused' ||
                    to == 'done' ||
                    to == 'canceled' ||
                    to == 'failed')
                ? 0
                : null,
          ),
        );
      case 'progress':
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            received: (evt['received'] as num?)?.toInt() ?? 0,
            total: (evt['total'] as num?)?.toInt(),
            speed: (evt['speed'] as num?)?.toInt(),
          ),
        );
      case 'done':
        // v2.1：Done 事件携带引擎自主寻找的 title/artist/album，非空才覆盖
        // （避免空串冲掉 enqueue 时已展示的元数据）。
        _applyTask(taskId, (t) {
          final cur = t ?? DownloadTask(taskId: taskId);
          final enrTitle = evt['title'] as String? ?? '';
          final enrArtist = evt['artist'] as String? ?? '';
          final enrAlbum = evt['album'] as String? ?? '';
          return cur.copyWith(
            status: 'done',
            filePath: evt['filePath'] as String?,
            fileSize: (evt['fileSize'] as num?)?.toInt(),
            actualQuality: evt['actualQuality'] as String?,
            title: enrTitle.isNotEmpty ? enrTitle : null,
            artist: enrArtist.isNotEmpty ? enrArtist : null,
            album: enrAlbum.isNotEmpty ? enrAlbum : null,
          );
        });
      case 'error':
        final msg = evt['error'] as String? ?? '未知错误';
        // Rust 取消路径统一推 Error(已取消, retryable=false)
        final canceled = msg == '已取消';
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: canceled ? 'canceled' : 'failed',
            error: msg,
            retryable: evt['retryable'] as bool? ?? false,
            stage: evt['stage'] as String?,
          ),
        );
      case 'already':
        _applyTask(
          taskId,
          (t) => (t ?? DownloadTask(taskId: taskId)).copyWith(
            status: 'already',
            filePath: evt['filePath'] as String?,
          ),
        );
    }
    // 新进 failed/canceled 的条目按记录上限淘汰最旧
    _pruneHistory();
  }

  /// 按 taskId 更新或新建任务（新任务追加尾部，保持入队顺序）。
  void _applyTask(String taskId, DownloadTask Function(DownloadTask?) update) {
    final tasks = List<DownloadTask>.of(state.tasks);
    final idx = tasks.indexWhere((t) => t.taskId == taskId);
    final next = update(idx >= 0 ? tasks[idx] : null);
    if (idx >= 0) {
      tasks[idx] = next;
    } else {
      tasks.add(next);
    }
    state = state.copyWith(tasks: tasks);
  }

  /// 记录上限裁剪：failed/canceled/done/already 条目超过
  /// [downloadHistoryLimitProvider] 时按入队顺序淘汰最旧（任务列表尾部
  /// 追加，最旧在前）。与 Rust `prune_finished` 语义一致；Rust 裁剪不发
  /// 事件，UI 在此同步。done/already 已落盘，可安全淘汰释放内存。
  void _pruneHistory() {
    final limit = ref.read(downloadHistoryLimitProvider);
    final tasks = state.tasks;
    // 已完成 / 已失败 / 已取消均视为历史记录（进行中任务不受裁）
    final finished = tasks.where((t) => t.isDone || t.isFailed).length;
    if (finished <= limit) return;
    final dropCount = finished - limit;
    final dropIds = <String>{};
    for (final t in tasks) {
      if (dropIds.length >= dropCount) break;
      if (t.isDone || t.isFailed) dropIds.add(t.taskId);
    }
    if (dropIds.isEmpty) return;
    state = state.copyWith(
      tasks: tasks.where((t) => !dropIds.contains(t.taskId)).toList(),
    );
  }
}

final downloadControllerProvider =
    NotifierProvider<DownloadController, DownloadState>(DownloadController.new);

// ----------------------------------------------------------------
// enqueue 请求构造（§12 协议；Dart 纯数据传递，不解析 URL）
// ----------------------------------------------------------------

/// 由 [Track] 构造 enqueue 请求 JSON（对齐 Rust `EnqueueRequest` camelCase）。
Map<String, dynamic> buildDownloadRequest(
  Track track, {
  String quality = 'hq',
}) {
  final kugou = track.kugou;
  return {
    'trackId': track.id,
    'source': track.source,
    'platformId': track.id,
    'quality': quality,
    'title': track.title,
    'artist': track.artistNames,
    'album': track.album?.name,
    'extra': (track.source == 'kugou' && kugou != null)
        ? {'hashes': kugou.hashes, 'sizes': kugou.sizes}
        : const <String, dynamic>{},
  };
}

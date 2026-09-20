// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_controller.dart';

/// 支持「播放管线回退解析」的来源：
/// - kugou/netease：Rust 自研解析，失败后回退；
/// - qqmusic：Rust 无自研解析（enqueue 后即失败）→ 直接走 Dart 播放管线。
/// 走 Dart 播放管线回退解析的来源（Rust 无自研解析的：QQ / 实验性 Neko）。
const _downloadFallbackSources = {'kugou', 'netease', 'qqmusic', 'neko'};

mixin _DownloadControllerCore on Notifier<DownloadState> {
  DownloaderEngine? get _engine;
  set _engine(DownloaderEngine? value);

  StreamSubscription<Map<String, dynamic>>? get _eventsSub;
  set _eventsSub(StreamSubscription<Map<String, dynamic>>? value);

  int get _gen;
  set _gen(int value);

  bool get _engineDesired;
  set _engineDesired(bool value);

  bool get _pageVisible;
  set _pageVisible(bool value);

  Future<void>? get _engineReady;
  set _engineReady(Future<void>? value);

  Timer? get _idleTimer;
  set _idleTimer(Timer? value);

  Set<String> get _removedIds;

  /// enqueue 时留存的完整 Track（taskId → Track），供回退解析使用。
  Map<String, Track> get _tracks;

  /// 已触发过回退解析的任务 id（防循环）。
  Set<String> get _fallbackTried;

  void _handleEvent(Map<String, dynamic> evt);
  void _setMaxSpeed(int bytesPerSec);
  void _pruneHistory();

  DownloadState _buildState() {
    final prefs = ref.watch(downloadPrefsProvider);
    _gen += 1;
    // 引擎按需：启动不再无条件常驻。仅在「已被请求」（下载页可见 / 有待恢复
    // 任务 / 已入队）时初始化；配置变更重建时若引擎在用，则用新配置重启。
    if (_engineDesired) {
      _initEngine(
        rootDir: prefs.rootDir,
        subdirStrategy: prefs.subdirStrategy,
        maxConcurrent: prefs.maxConcurrent,
        speedLimit: ref.read(downloadSpeedLimitProvider),
        filenameTemplate: ref.read(downloadFilenameTemplateProvider),
        historyLimit: ref.read(downloadHistoryLimitProvider),
        gen: _gen,
      );
    }
    ref.listen(downloadSpeedLimitProvider, (_, next) => _setMaxSpeed(next));
    ref.listen(downloadFilenameTemplateProvider, (_, next) {
      final engine = _engine;
      if (engine != null && engine.isInitialized) {
        engine.setFilenameTemplate(next);
      }
    });
    ref.listen(downloadHistoryLimitProvider, (_, next) {
      final engine = _engine;
      if (engine != null && engine.isInitialized) {
        engine.setHistoryLimit(next);
      }
      _pruneHistory();
    });
    ref.onDispose(_teardown);
    return DownloadState(initializing: _engineDesired);
  }

  void _teardown() {
    _gen += 1;
    _idleTimer?.cancel();
    _idleTimer = null;
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

  // ── 按需生命周期 ─────────────────────────────────────────────

  /// 按需初始化引擎（幂等，可并发安全）：下载页可见 / 有待恢复任务 /
  /// 入队前调用。已初始化则直接返回；进行中则复用同一 Future。
  Future<void> ensureEngine() {
    _engineDesired = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    final current = _engine;
    if (current != null && current.isInitialized) return Future<void>.value();
    final pending = _engineReady;
    if (pending != null) return pending;
    state = state.copyWith(initializing: true, clearInitError: true);
    final future = _startEngine();
    _engineReady = future;
    return future.whenComplete(() {
      if (identical(_engineReady, future)) _engineReady = null;
    });
  }

  /// 下载页可见性：可见即确保引擎；不可见则尝试空闲释放。
  void setPageVisible(bool visible) {
    if (_pageVisible == visible) return;
    _pageVisible = visible;
    if (visible) {
      unawaited(ensureEngine());
    } else {
      _scheduleIdleSuspend();
    }
  }

  /// 启动时仅在历史存在未完成任务时初始化引擎续传，否则保持引擎未加载。
  Future<void> resumePendingAtStartup() async {
    if (_engineDesired || (_engine?.isInitialized ?? false)) return;
    var pending = false;
    try {
      final f = File('${resolveDataDir()}/download_history.json');
      if (f.existsSync()) {
        final decoded = jsonDecode(f.readAsStringSync());
        pending =
            decoded is Map &&
            decoded['tasks'] is List &&
            (decoded['tasks'] as List).isNotEmpty;
      }
    } catch (_) {}
    if (pending) await ensureEngine();
  }

  Future<void> _startEngine() async {
    final prefs = ref.read(downloadPrefsProvider);
    final gen = ++_gen;
    await _initEngine(
      rootDir: prefs.rootDir,
      subdirStrategy: prefs.subdirStrategy,
      maxConcurrent: prefs.maxConcurrent,
      speedLimit: ref.read(downloadSpeedLimitProvider),
      filenameTemplate: ref.read(downloadFilenameTemplateProvider),
      historyLimit: ref.read(downloadHistoryLimitProvider),
      gen: gen,
    );
  }

  /// 空闲释放：非页面可见、无在途任务、无暂停任务时，延时销毁 Rust 引擎
  /// （释放 Rust 运行时/任务态堆内存）；下次 ensureEngine 重新 init。
  void _scheduleIdleSuspend() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_engineDesired || _pageVisible) return;
    _idleTimer = Timer(const Duration(seconds: 3), () {
      _idleTimer = null;
      if (_pageVisible || !_engineDesired) return;
      if (state.activeCount > 0) return;
      if (state.tasks.any((t) => t.isPaused)) return;
      _suspendEngine();
    });
  }

  void _suspendEngine() {
    if (_engine == null && !_engineDesired) return;
    _engineDesired = false;
    _teardown();
    state = state.copyWith(initializing: false, clearInitError: true);
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
    state = state.copyWith(initializing: false, clearInitError: true);
  }

  void _syncSessions() {
    _injectIdentity();
    _injectSessions();
  }

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
    final kugou = ref.read(kugouApiProvider).session;
    if (kugou != null && kugou.userid.isNotEmpty && kugou.token.isNotEmpty) {
      engine.setKugouSession(kugou.userid, kugou.token);
    }
    final cookies = getRuntime().sessionStore.get('netease');
    if (cookies.isNotEmpty) {
      engine.setNeteaseCookie(
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
  }

  // ── §12.1 下载回退：Rust 解析失败 → 复用播放管线解析 URL 再下载 ──────────

  /// 记录 enqueue 时的完整 Track（回退解析用）。
  void _rememberTrack(String taskId, Track track) {
    _tracks[taskId] = track;
  }

  /// 清理任务关联的 Track / 回退标记（移除、清空、终结时调用）。
  void _forgetTracks(Iterable<String> taskIds) {
    for (final id in taskIds) {
      _tracks.remove(id);
      _fallbackTried.remove(id);
    }
  }

  DownloadTask? _taskById(String taskId) {
    for (final t in state.tasks) {
      if (t.taskId == taskId) return t;
    }
    return null;
  }

  /// Rust 在 resolving 阶段解析失败 → 调度一次播放管线回退解析。
  ///
  /// kugou/netease：Rust 自研解析失败后回退；qqmusic：Rust 无解析，
  /// 直接由 Dart 播放管线解析（含 QQ 登录态取流）。
  void _scheduleFallback(String taskId) {
    final track = _tracks[taskId];
    if (track == null) return;
    if (!_downloadFallbackSources.contains(track.source)) return;
    unawaited(_resolveFallback(taskId, track));
  }

  /// 手动重试回退任务：重新解析 URL（避免复用已失效的预解析 URL）。
  ///
  /// 命中返回 true（已接管重试）；否则调用方走普通 [DownloaderEngine.retry]。
  bool _retryViaFallback(String taskId) {
    final track = _tracks[taskId];
    if (track == null) return false;
    if (!_downloadFallbackSources.contains(track.source)) return false;
    if (!_fallbackTried.contains(taskId)) return false;
    _fallbackTried.remove(taskId);
    unawaited(_resolveFallback(taskId, track));
    return true;
  }

  Future<void> _resolveFallback(String taskId, Track track) async {
    if (_removedIds.contains(taskId)) return;
    if (!_fallbackTried.add(taskId)) return; // 已在途/已尝试
    final engine = _engine;
    if (engine == null || !engine.isInitialized) return;
    // 仅在任务确实失败时回退（手动重试路径下状态为 failed）。
    final before = _taskById(taskId);
    if (before == null || before.status != 'failed') return;
    final quality = before.quality.isEmpty
        ? ref.read(appPrefsProvider).downloadQuality
        : before.quality;

    final String? url;
    try {
      url = await resolvePlaySource(
        ref,
        track,
        quality: quality,
        allowQqMusic: true,
        log: (m) => debugPrint('下载回退解析: $m'),
      );
    } catch (e) {
      debugPrint('下载回退解析异常: ${track.title}: $e');
      return;
    }
    if (url == null || url.isEmpty) {
      debugPrint('下载回退无可用播放源: ${track.title}');
      return;
    }
    if (_removedIds.contains(taskId)) return;
    final current = _taskById(taskId);
    if (current == null || current.status != 'failed') return;

    // Neko 直传原文件、直链无扩展名：按文件头魔数嗅探真实容器（对齐官方
    // PC 客户端），失败再回退 `fileFormat`，避免落盘扩展名错配。
    String? extOverride;
    if (track.source == 'neko') {
      try {
        extOverride = await ref.read(nekoApiProvider).probeAudioExtension(
          track.id,
        );
      } catch (_) {
        // 探测失败回退默认扩展名
      }
    }
    final resolved = _buildPreResolved(
      track,
      url,
      quality,
      extOverride: extOverride,
    );
    final code = engine.retryWithUrl(taskId, resolved);
    debugPrint('下载回退${code == 0 ? '已提交' : '提交失败(code=$code)'}: ${track.title}');
  }

  /// 构造 Rust `archoera_downloader_retry_with_url` 的 resolvedJson（camelCase）。
  Map<String, dynamic> _buildPreResolved(
    Track track,
    String url,
    String quality, {
    String? extOverride,
  }) {
    final ext =
        extOverride ??
        _extFromUrl(url) ??
        ((quality == 'lossless' || quality == 'hi-res') ? 'flac' : 'mp3');
    final headers = <List<String>>[];
    if (track.source == 'netease') {
      // 网易 CDN 通常需 Referer/UA；带登录态时补 Cookie（对齐 Rust resolver）。
      headers.add(const ['Referer', 'https://music.163.com/']);
      headers.add(const [
        'User-Agent',
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0',
      ]);
      final cookies = getRuntime().sessionStore.get('netease');
      if (cookies.isNotEmpty) {
        headers.add([
          'Cookie',
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        ]);
      }
    } else if (track.source == 'qqmusic') {
      // QQ CDN 需 UA/Referer；带登录态时补 Cookie（GetVkey 直链鉴权）。
      headers.add(const ['User-Agent', 'QQMusic 14090008(android 15)']);
      headers.add(const ['Referer', 'https://y.qq.com']);
      final cookies = getRuntime().sessionStore.get('qqmusic');
      if (cookies.isNotEmpty) {
        headers.add([
          'Cookie',
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        ]);
      }
    }
    return {
      'url': url,
      'qualityKey': _qualityKeyFor(quality, ext),
      'fileExt': ext,
      'headers': headers,
    };
  }

  /// 从 URL 路径推断扩展名（决定落盘扩展与标签写入格式）。
  String? _extFromUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['flac', 'mp3', 'm4a', 'aac', 'wav', 'ogg']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return null;
  }

  /// 实际品质 key（供 done 事件 actualQuality 展示；近似，以扩展名为准）。
  String _qualityKeyFor(String quality, String ext) {
    if (ext == 'flac') return quality == 'hi-res' ? 'flac24bit' : 'flac';
    return quality == 'lq' ? '128k' : '320k';
  }
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_controller.dart';

mixin _DownloadControllerCore on Notifier<DownloadState> {
  DownloaderEngine? get _engine;
  set _engine(DownloaderEngine? value);

  StreamSubscription<Map<String, dynamic>>? get _eventsSub;
  set _eventsSub(StreamSubscription<Map<String, dynamic>>? value);

  int get _gen;
  set _gen(int value);

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
    return const DownloadState();
  }

  void _teardown() {
    _gen += 1;
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
  /// 仅 kugou/netease（下载器支持的源）；QQMusic 明确不支持，直接跳过。
  void _scheduleFallback(String taskId) {
    final track = _tracks[taskId];
    if (track == null) return;
    if (track.source != 'kugou' && track.source != 'netease') return;
    unawaited(_resolveFallback(taskId, track));
  }

  /// 手动重试回退任务：重新解析 URL（避免复用已失效的预解析 URL）。
  ///
  /// 命中返回 true（已接管重试）；否则调用方走普通 [DownloaderEngine.retry]。
  bool _retryViaFallback(String taskId) {
    final track = _tracks[taskId];
    if (track == null) return false;
    if (track.source != 'kugou' && track.source != 'netease') return false;
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
        allowQqMusic: false,
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

    final resolved = _buildPreResolved(track, url, quality);
    final code = engine.retryWithUrl(taskId, resolved);
    debugPrint('下载回退${code == 0 ? '已提交' : '提交失败(code=$code)'}: ${track.title}');
  }

  /// 构造 Rust `archoera_downloader_retry_with_url` 的 resolvedJson（camelCase）。
  Map<String, dynamic> _buildPreResolved(
    Track track,
    String url,
    String quality,
  ) {
    final ext =
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

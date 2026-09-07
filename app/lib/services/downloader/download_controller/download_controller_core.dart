part of '../download_controller.dart';

mixin _DownloadControllerCore on Notifier<DownloadState> {
  DownloaderEngine? get _engine;
  set _engine(DownloaderEngine? value);

  StreamSubscription<Map<String, dynamic>>? get _eventsSub;
  set _eventsSub(StreamSubscription<Map<String, dynamic>>? value);

  int get _gen;
  set _gen(int value);

  Set<String> get _removedIds;

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
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../scrape_controller.dart';

mixin _ScrapeControllerCore on Notifier<ScrapeState> {
  ScraperController? get _scraper;
  set _scraper(ScraperController? value);

  int? get _handleAddr;
  set _handleAddr(int? value);

  Timer? get _timer;
  set _timer(Timer? value);

  Timer? get _finishTimer;
  set _finishTimer(Timer? value);

  ReceivePort? get _eventPort;
  set _eventPort(ReceivePort? value);

  Isolate? get _pumpIsolate;
  set _pumpIsolate(Isolate? value);

  Completer<void>? get _pumpReady;
  set _pumpReady(Completer<void>? value);

  ReceivePort? get _pumpExitPort;
  set _pumpExitPort(ReceivePort? value);

  bool get _stopped;
  set _stopped(bool value);

  bool get _cancelRequested;
  set _cancelRequested(bool value);

  void _handleEvent(String json);
  void _startEventPump();
  Future<void> _ensurePumpDelivery();
  void _poll();
  void _teardownEventPump();

  ScrapeState _buildState() {
    ref.onDispose(_finish);
    return ScrapeState.initial;
  }

  void _start({
    required List<String> dirs,
    required String dbPath,
    required ScrapeSources sources,
    required bool embedMetadata,
    required bool embedCover,
    required bool embedLyrics,
    required bool skipScraped,
    required int workers,
    required int batchSize,
    required int maxRetries,
  }) {
    if (state.scraping) return;
    final cleanDirs = dirs
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList();
    if (cleanDirs.isEmpty) {
      state = state.copyWith(error: 'scrape empty dirs');
      return;
    }
    if (!_stopped || _scraper != null) _finish();

    final config = ScraperConfig(
      scraperDbPath: dbPath,
      dirs: cleanDirs,
      useMusicBrainz: sources.musicBrainz,
      useDeezer: sources.deezer,
      useItunes: sources.itunes,
      useNetease: sources.netease,
      useQQMusic: sources.qqMusic,
      useKugou: sources.kugou,
      useKuwo: sources.kuwo,
      useMigu: sources.migu,
      useAcoustID: sources.acoustId,
      embedMetadata: embedMetadata,
      embedCover: embedCover,
      embedLyrics: embedLyrics,
      skipScraped: skipScraped,
      concurrentWorkers: workers > 0 ? workers : null,
      batchSize: batchSize > 0 ? batchSize : 10,
      maxRetries: maxRetries >= 0 ? maxRetries : 5,
    );
    _launchScrape(config, organize: false);
  }

  void _startOrganize({
    required List<String> dirs,
    required String dbPath,
    required String targetDir,
    required String pattern,
  }) {
    if (state.scraping) return;
    final cleanDirs = dirs
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList();
    final target = targetDir.trim();
    if (cleanDirs.isEmpty || target.isEmpty) {
      state = state.copyWith(error: 'organize dirs/target empty');
      return;
    }
    if (!_stopped || _scraper != null) _finish();
    _launchScrape(
      ScraperConfig(
        scraperDbPath: dbPath,
        dirs: cleanDirs,
        mode: 'organize',
        organizeTargetDir: target,
        organizePattern: pattern.isEmpty ? kOrganizeDefaultPattern : pattern,
      ),
      organize: true,
    );
  }

  void _launchScrape(ScraperConfig config, {bool organize = false}) {
    final ScraperController scraper;
    try {
      scraper = ScraperController(config);
    } catch (e) {
      state = state.copyWith(error: '$e');
      return;
    }
    _scraper = scraper;
    _handleAddr = scraper.address;
    _stopped = false;
    _cancelRequested = false;

    state = ScrapeState(scraping: true, organize: organize);
    if (!scraper.run()) {
      state = state.copyWith(scraping: false, error: 'archoera_scraper_run 失败');
      _finish();
      return;
    }
    if (ScrapeController._usePollFallback) {
      _timer = Timer.periodic(ScrapeController._pollInterval, (_) => _poll());
    } else {
      _pumpReady = Completer<void>();
      _startEventPump();
      unawaited(_ensurePumpDelivery());
    }
  }

  void _cancel() {
    if (!state.scraping) return;
    _cancelRequested = true;
    _scraper?.cancel();
  }

  /// 关闭「仅目录整理」完成/结果视图，回到可编辑的空闲态。
  /// 仅空闲（未运行）时可用：清空 organize/进度/错误，保留引擎会话可再启动。
  void _dismissResult() {
    if (state.scraping) return;
    state = ScrapeState.initial;
  }

  void _finish() {
    if (_stopped &&
        _scraper == null &&
        _timer == null &&
        _finishTimer == null &&
        _eventPort == null &&
        _pumpIsolate == null) {
      return;
    }
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _finishTimer?.cancel();
    _finishTimer = null;
    final s = _scraper;
    _scraper = null;
    _handleAddr = null;
    if (s != null) {
      while (true) {
        final ev = s.pollEvent();
        if (ev == null) break;
        _handleEvent(ev);
      }
      if (state.scraping) {
        state = state.copyWith(scraping: false, canceled: _cancelRequested);
      }
      _cancelRequested = false;
      s.dispose();
    }
    _teardownEventPump();
  }
}

part of '../playback_notifier.dart';

mixin _PlaybackNotifierSession
    on _PlaybackNotifierBase, _PlaybackNotifierQueue, _PlaybackNotifierLoading {
  @override
  Future<void> _startSession(
    String source, {
    required int offsetMs,
    required int bitrate,
    bool passthrough = true,
    int gen = 0,
    SegStoreHandle store = 0,
    bool memoryStore = false,
  }) async {
    await _stopEngine();
    final AudioEngineProcess engine;
    try {
      engine = await AudioEngineProcess.start(
        source: source,
        store: store,
        memoryStore: memoryStore,
        offsetMs: offsetMs,
        bitrate: bitrate,
        passthrough: passthrough,
      );
    } catch (e) {
      // store 会话引擎创建失败：句柄尚未交给 _engine/_engineStore，就地释放后
      // 上抛，由 load 决定回退 URL 路径或按 load 失败处理。
      _log('引擎创建失败（${memoryStore ? 'store 内存源' : 'URL 源'}）: $e');
      _destroyStore(store);
      rethrow;
    }
    if (gen != 0 && gen != _loadGen) {
      _log('会话被新 load 取代，丢弃刚创建的引擎');
      await engine.stop();
      _destroyStore(store);
      return;
    }
    _engine = engine;
    // store 所有权交给 _engineStore：此后由 _stopEngine（engine.stop join 之后）
    // 负责 destroy，本方法其余失败出口不再触碰（避免同句柄重复释放）。
    _engineStore = store;
    _sessionOffsetMs = offsetMs;
    _engineSubs.add(engine.events.listen(_onEngineEvent));
    _fftStarted = false;
    final sinkId = ref.read(appPrefsProvider).sink;
    if (sinkId.isNotEmpty) {
      unawaited(engine.sendCommand('set_sink', {'id': sinkId}));
    }
    _lastSpectrumAtMs = -1000;
    unawaited(engine.setVolume(state.volume));
    state = state.copyWith(
      source: source,
      sessionId: engine.sessionId,
      playing: false,
      position: Duration(milliseconds: offsetMs),
      duration: Duration.zero,
      fft: null,
    );
    var startedInTime = false;
    try {
      await engine.started.timeout(const Duration(seconds: 30));
      startedInTime = true;
    } on TimeoutException {
      _log('引擎就绪等待超时（30s），放弃该会话（seek/load 不挂死）');
      startedInTime = false;
    }
    if (!startedInTime) {
      if (gen != 0 && gen != _loadGen) return;
      if (!identical(_engine, engine)) return;
      state = state.copyWith(buffering: false);
      // 超时放弃当前会话：_stopEngine 负责 engine.stop（join）+ destroy 关联
      // store；随后 load 决定回退 URL 路径或按失败处理。
      await _stopEngine();
      throw StateError('引擎启动超时（30s），已停止该会话');
    }
    if (gen != 0 && gen != _loadGen) {
      _log('会话被新 load 取代（就绪前/就绪时）');
      return;
    }
    if (!identical(_engine, engine)) {
      _log('会话已放弃（就绪等待期间被 stop）');
      return;
    }
    _log(memoryStore ? '引擎 store 内存源会话就绪，开始播放' : '引擎会话就绪，开始播放');
  }

  void _recordHistoryOnce() {
    if (_historyRecorded) return;
    final current = state.track;
    if (current == null) return;
    final prefs = ref.read(appPrefsProvider);
    if (!prefs.historyEnabled) return;
    _historyRecorded = true;
    ref.read(historyStoreProvider).record(current, limit: prefs.historyLimit);
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case EngineReady():
        _log(
          '引擎就绪: v${event.version} ${event.durationMs}ms @${event.sampleRate}Hz/${event.channels}ch',
        );
        if (event.durationMs > 0) {
          state = state.copyWith(
            duration: Duration(milliseconds: event.durationMs),
          );
        }
      case EngineStatus():
        if (event.playing != null) {
          state = state.copyWith(playing: event.playing!);
          _syncFftActive();
        }
        if (event.positionMs > 0) {
          state = state.copyWith(
            position: Duration(
              milliseconds: event.positionMs + _sessionOffsetMs,
            ),
          );
        }
      case EngineDone():
        _log('引擎转码完成');
      case EnginePlaying():
        _autoResumeInFlight = false;
        _retryableSnapshot = null;
        final durMs = event.durationMs > 0
            ? event.durationMs + _sessionOffsetMs
            : 0;
        if (durMs > 0) {
          state = state.copyWith(duration: Duration(milliseconds: durMs));
        }
        if (_pendingPauseAfterReady) {
          _pendingPauseAfterReady = false;
          unawaited(_engine?.pause());
          state = state.copyWith(playing: false, buffering: false);
          _syncFftActive();
          _log('播放器就绪: miniaudio 已加载（保持暂停）');
          return;
        }
        state = state.copyWith(playing: true, buffering: false);
        _syncFftActive();
        _log('播放器就绪: miniaudio 播放 WAV');
        _recordHistoryOnce();
      case EnginePosition():
        final absMs = event.positionMs + _sessionOffsetMs;
        state = state.copyWith(position: Duration(milliseconds: absMs));
        _pollSpectrum();
        if (Platform.environment['ARCHOERA_AUTOPLAY'] == '1' &&
            absMs > 0 &&
            (_lastPosLogMs == null || absMs - _lastPosLogMs! >= 5000)) {
          _lastPosLogMs = absMs;
          _log('播放位置: ${absMs}ms / ${state.duration.inMilliseconds}ms');
        }
      case EngineEventInterval():
        _engineIntervalMs = event.intervalMs;
        _syncFftActive();
        _log('事件间隔已协商: ${event.intervalMs}ms');
      case EnginePlayerEnded():
        state = state.copyWith(playing: false, buffering: false);
        _syncFftActive();
        _log('播放完成（miniaudio EOF）');
        unawaited(_onTrackEnded());
      case EngineError():
        if (_autoResumeInFlight) {
          final retry = _retryableSnapshot;
          _autoResumeInFlight = false;
          _retryableSnapshot = null;
          if (retry != null) _writeSession(retry);
        }
        _log('引擎错误: ${event.message}');
        state = state.copyWith(buffering: false);
      case EngineSinkChanged():
        if (event.ok) {
          _log('输出设备已切换');
        } else {
          final err = event.err;
          _log('切换输出设备失败: ${err ?? '未知错误'}');
          if (err != null && err.isNotEmpty && !_sinkFailureCtrl.isClosed) {
            _sinkFailureCtrl.add(err);
          }
        }
      case EngineExited():
        if (_engine != null) {
          if (_autoResumeInFlight) {
            final retry = _retryableSnapshot;
            _autoResumeInFlight = false;
            _retryableSnapshot = null;
            if (retry != null) _writeSession(retry);
          }
          _log('引擎退出 code=${event.code}');
          state = state.copyWith(buffering: false);
        }
    }
  }

  @override
  Future<void> _stopEngine() async {
    _fftActive = false;
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
    final engine = _engine;
    _engine = null;
    final store = _engineStore;
    _engineStore = 0;
    if (engine != null) {
      await engine.stop();
    }
    // store 释放点（docs/audio-memory-source.md §12）：紧跟引擎 destroy（已 join
    // 解码线程）之后 destroy SegStore，释放驻留字节；同句柄只经本处释放一次。
    _destroyStore(store);
  }
}

part of '../playback_notifier.dart';

mixin _PlaybackNotifierLoading
    on _PlaybackNotifierBase, _PlaybackNotifierQueue {
  Future<void> restore() async {
    if (!_sessionMemoryEnabled) {
      const PlaybackSessionStore().clear();
      return;
    }
    final snapshot = const PlaybackSessionStore().load();
    if (snapshot == null) return;
    final queue = snapshot.queue;
    if (queue.isEmpty && snapshot.track == null) return;
    final track = snapshot.currentTrack;
    if (track == null) return;
    var idx = snapshot.queueIndex;
    if (idx < -1 || idx >= queue.length) idx = -1;
    var posMs = snapshot.positionMs;
    final durMs = track.duration;
    if (durMs > 0 && posMs >= durMs) posMs = 0;
    final autoPlay =
        snapshot.playing && ref.read(appPrefsProvider).autoPlayOnLaunch;
    _originalQueue = List.of(queue);
    _autoResumeInFlight = autoPlay;
    _retryableSnapshot = autoPlay ? snapshot : null;
    state = state.copyWith(
      queue: List.of(queue),
      queueIndex: idx,
      repeatMode: snapshot.repeatMode,
      shuffle: snapshot.shuffle,
      quality: snapshot.quality,
      title: snapshot.title,
      subtitle: snapshot.subtitle,
      trackId: snapshot.trackId,
      track: snapshot.track,
      playing: false,
      buffering: false,
      position: Duration(milliseconds: posMs),
    );
    _log(
      '恢复会话: ${queue.length} 首 @${posMs}ms '
      '${autoPlay ? '自动续播' : '暂停'}',
    );
    if (!autoPlay) return;
    await _resumeFrom(track, offsetMs: posMs, quality: snapshot.quality);
    await Future<void>.delayed(Duration.zero);
    if (!state.playing && _engine == null) {
      _autoResumeInFlight = false;
      _retryableSnapshot = null;
    }
  }

  Future<void> _resumeFrom(
    Track track, {
    required int offsetMs,
    String? quality,
  }) async {
    final q = quality ?? state.quality;
    try {
      final url = await _resolveSource(track, quality: q);
      if (url == null || url.isEmpty) {
        _log('恢复播放失败：无法解析播放源 ${track.title}');
        return;
      }
      await _playTrackMeta(url, track, quality: q, offsetMs: offsetMs);
    } catch (e) {
      _log('恢复播放异常: ${track.title}: $e');
    }
  }

  void persistNow() => _persistSession();

  void _writeSession(PlaybackSnapshot snapshot) {
    const PlaybackSessionStore().save(snapshot);
    _lastPersistPosMs = snapshot.positionMs;
  }

  void _persistSession() {
    if (_autoResumeInFlight && !state.playing) {
      final retry = _retryableSnapshot;
      if (retry != null) _writeSession(retry);
      return;
    }
    if (!_sessionMemoryEnabled) return;
    final s = state;
    if (s.queue.isEmpty && s.track == null && s.source == null) return;
    _writeSession(
      PlaybackSnapshot.fromState(
        queue: s.queue,
        queueIndex: s.queueIndex,
        position: s.position,
        repeatMode: s.repeatMode,
        shuffle: s.shuffle,
        quality: s.quality,
        playing: s.playing,
        title: s.title,
        subtitle: s.subtitle,
        trackId: s.trackId,
        track: s.track,
        source: s.source,
      ),
    );
  }

  @override
  Future<void> load(
    String source, {
    int bitrate = 128000,
    String? title,
    String? subtitle,
    String? trackId,
    Track? track,
    String quality = 'hq',
    int offsetMs = 0,
  }) {
    final gen = ++_loadGen;
    unawaited(_stopEngine());
    final task = _loadChain.then((_) async {
      if (gen != _loadGen) {
        _log('load 被新会话取代（排队中）: $source');
        return;
      }
      state = state.copyWith(
        title: title,
        subtitle: subtitle,
        trackId: trackId,
        track: track,
        quality: quality,
        buffering: true,
      );
      _historyRecorded = false;
      try {
        final useBitrate = track != null
            ? (qualityBitrate[quality] ?? bitrate)
            : bitrate;
        final passthrough = ref.read(appPrefsProvider).passthrough;
        // M2.2 在线纯内存源（docs/audio-memory-source.md §2/§6.1/§6.2）：
        // 内存播放开且 source 是 http(s) 在线 URL → Dart 整首下载进 SegStore 再
        // createStore 会话；下载失败/超 64 MiB/store 失败 → 回退 URL 直连引擎。
        var store = 0;
        var memoryTried = false;
        if (_memorySourceEligible(source)) {
          memoryTried = true;
          try {
            final r = await prepareWholeTrackStore(source);
            store = r.store;
            if (r.ok) {
              _log('内存源整首下载完成，驻留 ${r.bytes} 字节（SegStore）');
            } else {
              // M3（§13）：纯内存不可用时用红色 scrim 确认框（非 toast）。
              // true=在线直连回退（仍可播）；false=停止本次播放。
              final reason = r.error ?? '未知';
              final proceed = await confirmMemoryFallback(reason);
              _log(
                '内存源不可用（$reason）→ '
                '${proceed ? '在线直连回退' : '停止播放'}',
              );
              if (!proceed) {
                state = state.copyWith(buffering: false);
                _destroyStore(store); // store==0 时为空操作
                return;
              }
            }
          } catch (e) {
            _log('内存源整首下载异常，回退 URL 直连: $e');
          }
          // TODO(M2.3)：会话被取代时取消在途下载。当前每次下载为独立 store、
          // 无并发写同一句柄；被取代的下载完成后经下方 gen 校验销毁（浪费一次
          // 拉取，不影响正确性）。
          if (store != 0 && gen != _loadGen) {
            _log('内存源下载期间被新 load 取代，丢弃 store');
            _destroyStore(store);
            return;
          }
        }
        try {
          await _startSession(
            source,
            offsetMs: offsetMs,
            bitrate: useBitrate,
            passthrough: passthrough,
            gen: gen,
            store: store,
            memoryStore: store != 0,
          );
        } catch (e) {
          if (memoryTried && store != 0 && gen == _loadGen) {
            // store 会话启动失败 → 记日志并按旧路径（URL 直接给引擎）重试一次，
            // 不弹窗（内存门禁弹窗属后续 M3/§13 UI）。失败引擎与关联 store 的
            // 清理由重试 _startSession 入口的 _stopEngine 完成。
            _log('内存源会话启动失败，回退 URL 直连重试一次: $e');
            await _startSession(
              source,
              offsetMs: offsetMs,
              bitrate: useBitrate,
              passthrough: passthrough,
              gen: gen,
            );
          } else {
            rethrow;
          }
        }
        if (gen != _loadGen) {
          _log('load 被新会话取代: $source');
          return;
        }
        _log('load ok: ${store != 0 ? 'store 内存源' : source}');
        _consecutiveFailures = 0;
        _fallbackAttempted.clear();
      } catch (e, s) {
        _log('load 失败: $e\n$s');
        state = state.copyWith(buffering: false);
        rethrow;
      }
    });
    _loadChain = task.catchError((_) {});
    return task;
  }

  /// M2.2 内存源门禁（docs/audio-memory-source.md §2 三态）：仅当
  /// `engineMemoryPlay`（内存播放偏好）开且 [source] 为 http(s) 在线 URL
  /// （非本地文件 / SongCache 命中路径）时才尝试 Dart 下载 → SegStore 纯内存会话。
  bool _memorySourceEligible(String source) {
    if (source.isEmpty) return false;
    if (!ref.read(appPrefsProvider).engineMemoryPlay) return false;
    return source.startsWith('http://') || source.startsWith('https://');
  }

  Future<void> reload() async {
    final s = state;
    final src = s.source;
    if (src == null) return;
    _log('设置变更，重载当前曲目: ${s.title ?? src}');
    await load(
      src,
      bitrate: qualityBitrate[s.quality] ?? 128000,
      title: s.title,
      subtitle: s.subtitle,
      trackId: s.trackId,
      track: s.track,
      quality: s.quality,
    );
  }

  Future<void> setQuality(String quality) async {
    final track = state.track;
    if (track == null || state.source == null) return;
    if (quality == state.quality) return;
    _log('切换音质 → ${qualityLabels[quality] ?? quality}');
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref
            .read(kugouApiProvider)
            .resolvePlayUrl(track.kugou!, quality: quality);
      } else if (track.source == 'netease') {
        url = await ref
            .read(neteaseApiProvider)
            .resolvePlayUrl(track.id, quality: quality);
      } else if (track.source == 'qqmusic') {
        url = await ref
            .read(qqMusicApiProvider)
            .resolvePlayUrl(track, quality: quality);
      } else {
        url = null;
      }
      if (url == null || url.isEmpty) {
        _log('音质切换失败：无可用播放源（可能为 VIP / 版权限制）');
        return;
      }
      await load(
        url,
        bitrate: qualityBitrate[quality] ?? 128000,
        title: track.title,
        subtitle: track.artistNames,
        trackId: track.id,
        track: track,
        quality: quality,
      );
    } catch (e) {
      _log('音质切换失败: $e');
    }
  }
}

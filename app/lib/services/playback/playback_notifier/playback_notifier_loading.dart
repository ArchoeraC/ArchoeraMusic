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
        await _startSession(
          source,
          offsetMs: offsetMs,
          bitrate: useBitrate,
          passthrough: passthrough,
          gen: gen,
        );
        if (gen != _loadGen) {
          _log('load 被新会话取代: $source');
          return;
        }
        _log('load ok: $source');
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

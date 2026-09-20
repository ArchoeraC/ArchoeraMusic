// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../playback_notifier.dart';

mixin _PlaybackNotifierQueue on _PlaybackNotifierBase {
  /// 连续失败硬上限。
  static const _maxConsecutiveFailures = 5;

  Future<String?> _resolveSource(Track track, {String? quality}) {
    return resolvePlaySource(
      ref,
      track,
      quality: quality ?? state.quality,
      log: _log,
    );
  }

  Future<bool> _playTrackMeta(
    String url,
    Track track, {
    String? quality,
    int offsetMs = 0,
  }) async {
    final q = quality ?? state.quality;
    try {
      var playUrl = url;
      final prefs = ref.read(appPrefsProvider);
      // 纯内存播放（不落盘）优先：开启时不读也不写歌曲磁盘缓存——否则与
      // 「不落盘」语义冲突（缓存读命中会走本地文件、未命中会后台落盘）。
      if (!prefs.engineMemoryPlay &&
          prefs.songCacheEnabled &&
          url.isNotEmpty &&
          (track.source == 'kugou' || track.source == 'netease')) {
        final id = track.source == 'kugou'
            ? (track.kugou?.hash ?? track.id)
            : track.id;
        final key = SongCache.shared.cacheKeyFor(track.source, id, q);
        final cached = SongCache.shared.lookup(key);
        if (cached != null) {
          playUrl = cached;
        } else {
          final referer = track.source == 'kugou'
              ? 'https://www.kugou.com/'
              : 'https://music.163.com/';
          unawaited(
            SongCache.shared
                .storeAsync(key, url, referer: referer)
                .then((_) => SongCache.shared.trim(prefs.songCacheLimitMiB)),
          );
        }
      }
      await load(
        playUrl,
        bitrate: qualityBitrate[q] ?? 128000,
        title: track.title,
        subtitle: track.subtitle,
        trackId: track.id,
        track: track,
        quality: q,
        offsetMs: offsetMs,
      );
      return true;
    } catch (e) {
      _log('播放失败: ${track.title}: $e');
      return false;
    }
  }

  Future<void> _playCurrent() async {
    final djPrefs = ref.read(appPrefsProvider);
    if (djPrefs.fuckDjMode) {
      var guard = 0;
      final len = state.queue.length;
      while (guard < len) {
        final cur = state.currentQueueTrack;
        if (cur == null ||
            !shouldSkipDjTrack(
              cur,
              enhanced: djPrefs.djEnhanced,
              custom: djPrefs.djCustomKeywords,
            )) {
          break;
        }
        _advanceNext();
        guard++;
      }
      if (guard >= len) {
        _log('Fuck DJ Mode：队列全为 DJ 曲目，跳过逻辑放弃');
      }
    }
    final q = state.queue;
    final idx = state.queueIndex;
    if (idx < 0 || idx >= q.length) return;
    final track = q[idx];
    // 实验性音源 Neko 元数据不规范：播放前用其它音源补充/重写**展示元数据**
    // （标题/歌手/专辑/封面/时长；不改 id 与 source，播放仍走 Neko 直链）。
    // 结果按曲目 id 缓存，仅首次播放多一次搜索请求。失败静默用原元数据。
    var playTrack = track;
    if (track.source == 'neko' && ref.read(appPrefsProvider).nekoEnabled) {
      playTrack = await ref.read(nekoMetadataEnricherProvider).enrich(track);
    }
    final String? url;
    try {
      url = await _resolveSource(playTrack, quality: state.quality);
    } catch (e) {
      _log('解析播放源异常: ${playTrack.title}: $e');
      return _handleTrackFailure(playTrack, '解析播放源异常');
    }
    if (url == null || url.isEmpty) {
      _log('无法解析播放源: ${playTrack.title}');
      await _handleTrackFailure(playTrack, '无可用播放源');
      return;
    }
    final ok = await _playTrackMeta(url, playTrack);
    if (!ok) {
      await _handleTrackFailure(playTrack, '播放加载失败');
    }
  }

  Future<void> _handleTrackFailure(Track track, String reason) async {
    _log('播放失败: ${track.title}（$reason）');
    if (await _tryFallbackSource(track)) return;
    await _skipOnFailure('${track.title}：$reason');
  }

  Future<void> _skipOnFailure(String reason) async {
    _log('自动跳过无法播放的曲目: $reason');
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures ||
        _consecutiveFailures >= state.queue.length) {
      _consecutiveFailures = 0;
      _log('连续失败达上限，停止播放');
      await stop();
      return;
    }
    _advanceNext();
    await _playCurrent();
  }

  Future<bool> _tryFallbackSource(Track track) async {
    if (track.source == 'local' || track.source == 'streaming') return false;
    final title = track.title.trim();
    if (title.isEmpty) return false;
    final contentKey = _trackContentKey(track);
    if (_fallbackAttempted.contains(contentKey)) return false;
    _fallbackAttempted.add(contentKey);

    final artist = track.artistNames.trim();
    final keyword = [title, if (artist.isNotEmpty) artist].join(' ');
    final candidates = <Track>[];
    try {
      if (track.source == 'netease') {
        candidates.addAll(
          (await ref.read(kugouApiProvider).searchSongs(keyword, limit: 20))
              .items,
        );
      } else {
        candidates.addAll(
          (await ref.read(neteaseApiProvider).searchSongs(keyword, limit: 20))
              .items,
        );
      }
    } catch (e) {
      _log('换源搜索失败: $e');
      return false;
    }
    for (final cand in candidates) {
      if (cand.source == track.source) continue;
      if (!_isSameTitleArtist(track, cand)) continue;
      final url = await _resolveSource(cand, quality: state.quality);
      if (url == null || url.isEmpty) continue;
      _log('自动换源: ${track.title} → ${cand.source} 版本（${cand.title}）');
      final q = List.of(state.queue);
      if (state.queueIndex < 0 || state.queueIndex >= q.length) return false;
      q[state.queueIndex] = cand;
      state = state.copyWith(queue: q);
      final orig = _originalQueue;
      if (orig != null && state.queueIndex < orig.length) {
        orig[state.queueIndex] = cand;
      }
      final ok = await _playTrackMeta(url, cand);
      return ok;
    }
    return false;
  }

  static String _trackContentKey(Track track) {
    final artists =
        track.artists
            .map((a) => _normText(a.name))
            .where((s) => s.isNotEmpty)
            .toList()
          ..sort();
    final title = _normText(track.title);
    return '$title|${artists.join(',')}';
  }

  static String _normText(String s) => s
      .replaceAll(RegExp(r'[（(【\[].*?[）)】\]]'), '')
      .replaceAll(RegExp(r'''[\s·・\-—_.,，。:："'‘’/\\|]+'''), '')
      .toLowerCase();

  static bool _isSameTitleArtist(Track a, Track b) {
    if (_normText(a.title) != _normText(b.title)) return false;
    final aa = a.artists
        .map((x) => _normText(x.name))
        .where((s) => s.isNotEmpty);
    final ba = b.artists
        .map((x) => _normText(x.name))
        .where((s) => s.isNotEmpty);
    if (aa.isEmpty || ba.isEmpty) return false;
    return aa.any(ba.contains);
  }

  void _advanceNext() {
    final q = state.queue;
    if (q.isEmpty) return;
    final len = q.length;
    final idx = state.queueIndex;
    if (idx >= len - 1) {
      if (state.shuffle && len > 1) {
        state = state.copyWith(
          queue: _shuffledWithCurrentFirst(),
          queueIndex: 1,
        );
        _log('随机模式：已重新洗牌队列');
      } else {
        state = state.copyWith(queueIndex: 0);
      }
    } else {
      state = state.copyWith(queueIndex: idx + 1);
    }
  }

  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    final idx = startIndex.clamp(0, tracks.length - 1);
    _originalQueue = List.of(tracks);
    if (state.shuffle) {
      final q = List.of(tracks);
      final current = q.removeAt(idx);
      q.shuffle(math.Random());
      q.insert(0, current);
      state = state.copyWith(queue: q, queueIndex: 0);
      _log('随机模式：已洗牌队列（${q.length} 首）');
    } else {
      state = state.copyWith(queue: List.of(tracks), queueIndex: idx);
    }
    await _playCurrent();
  }

  Future<void> playTrack(Track track) async {
    if (state.queue.isNotEmpty) {
      final idx = _indexOfTrack(state.queue, track);
      if (idx != -1) {
        await playAtIndex(idx);
        return;
      }
    }
    await playQueue([track]);
  }

  Future<void> playNow(Track track, {String? resolvedUrl}) async {
    final q = state.queue;
    if (q.isEmpty) {
      final url = resolvedUrl ?? await _resolveSource(track);
      if (url == null || url.isEmpty) {
        _log('无法解析播放源: ${track.title}');
        await _handleTrackFailure(track, '无可用播放源');
        return;
      }
      state = state.copyWith(queue: [track], queueIndex: 0);
      _originalQueue = List.of(state.queue);
      final ok = await _playTrackMeta(url, track);
      if (!ok) await _handleTrackFailure(track, '播放加载失败');
      return;
    }
    final existing = _indexOfTrack(q, track);
    if (existing != -1) {
      await playAtIndex(existing);
      return;
    }
    final at = state.queueIndex + 1;
    final nq = List.of(q)..insert(at, track);
    state = state.copyWith(queue: nq, queueIndex: at);
    _originalQueue?.insert(at, track);
    final url = resolvedUrl ?? await _resolveSource(track);
    if (url == null || url.isEmpty) {
      _log('无法解析播放源: ${track.title}');
      await _handleTrackFailure(track, '无可用播放源');
      return;
    }
    final ok = await _playTrackMeta(url, track);
    if (!ok) await _handleTrackFailure(track, '播放加载失败');
  }

  Future<void> playPrevious() async {
    final q = state.queue;
    if (q.isEmpty) return;
    final idx = state.queueIndex > 0 ? state.queueIndex - 1 : q.length - 1;
    state = state.copyWith(queueIndex: idx);
    await _playCurrent();
  }

  Future<void> playNext() async {
    if (state.queue.isEmpty) return;
    _advanceNext();
    await _playCurrent();
  }

  Future<void> playAtIndex(int index) async {
    final q = state.queue;
    if (index < 0 || index >= q.length) return;
    if (index == state.queueIndex) {
      final engine = _engine;
      if (engine != null && !state.playing) {
        engine.play();
        state = state.copyWith(playing: true);
        _syncFftActive();
      }
      return;
    }
    state = state.copyWith(queueIndex: index);
    await _playCurrent();
  }

  void setRepeatMode(String mode) {
    if (!repeatModeCycle.contains(mode)) return;
    if (state.repeatMode == mode) return;
    state = state.copyWith(repeatMode: mode);
    _log('播放模式 → ${repeatModeLabels[mode] ?? mode}');
  }

  void cycleRepeatMode() {
    final cycle = repeatModeCycle;
    final next = cycle[(cycle.indexOf(state.repeatMode) + 1) % cycle.length];
    setRepeatMode(next);
  }

  void setShuffle(bool on) {
    if (state.shuffle == on) return;
    if (on) {
      state = state.copyWith(
        shuffle: true,
        queue: _shuffledWithCurrentFirst(),
        queueIndex: 0,
      );
      _log('随机播放已开启');
    } else {
      final original = _originalQueue;
      final q = state.queue;
      final currentId = state.currentQueueTrack?.id;
      List<Track> restored;
      int idx;
      if (original != null && original.isNotEmpty) {
        restored = List.of(original);
        idx = currentId != null
            ? restored.indexWhere((t) => t.id == currentId)
            : 0;
        if (idx < 0) {
          restored = List.of(q);
          idx = state.queueIndex;
        }
      } else {
        restored = List.of(q);
        idx = state.queueIndex;
      }
      state = state.copyWith(shuffle: false, queue: restored, queueIndex: idx);
      _log('随机播放已关闭');
    }
  }

  void toggleShuffle() => setShuffle(!state.shuffle);

  Future<void> removeFromQueue(int index) async {
    final q = List.of(state.queue);
    if (index < 0 || index >= q.length) return;
    final isCurrent = index == state.queueIndex;
    q.removeAt(index);
    _originalQueue?.removeAt(index);
    if (isCurrent) {
      if (q.isEmpty) {
        state = state.copyWith(queue: const [], queueIndex: -1);
        _originalQueue = null;
        await stop();
        return;
      }
      var qi = state.queueIndex;
      if (qi >= q.length) qi = 0;
      state = state.copyWith(queue: q, queueIndex: qi);
      await _playCurrent();
      return;
    }
    var qi = state.queueIndex;
    if (index < qi) qi--;
    state = state.copyWith(queue: q, queueIndex: qi);
  }

  int insertToQueue(Track track) {
    final q = List.of(state.queue);
    final qi = state.queueIndex;
    if (q.isEmpty) {
      q.add(track);
      state = state.copyWith(queue: q, queueIndex: 0);
      _originalQueue = List.of(q);
      return 0;
    }
    final existing = _indexOfTrack(q, track);
    if (existing != -1) {
      if (existing != qi + 1) moveInQueue(existing, qi + 1);
      return qi + 1;
    }
    final at = qi + 1;
    q.insert(at, track);
    state = state.copyWith(queue: q);
    _originalQueue?.insert(at, track);
    return at;
  }

  void moveInQueue(int from, int to) {
    final q = List.of(state.queue);
    if (from == to ||
        from < 0 ||
        from >= q.length ||
        to < 0 ||
        to >= q.length) {
      return;
    }
    final item = q.removeAt(from);
    q.insert(to, item);
    var qi = state.queueIndex;
    if (qi == from) {
      qi = to;
    } else if (from < qi && to >= qi) {
      qi--;
    } else if (from > qi && to <= qi) {
      qi++;
    }
    state = state.copyWith(queue: q, queueIndex: qi);
    final orig = _originalQueue;
    if (orig != null && from < orig.length && to < orig.length) {
      final oi = orig.removeAt(from);
      orig.insert(to, oi);
    }
  }

  Future<void> clearQueue() async {
    state = state.copyWith(queue: const [], queueIndex: -1);
    _originalQueue = null;
    if (state.source != null) {
      await stop();
    }
  }

  List<Track> _shuffledWithCurrentFirst() {
    final q = List.of(state.queue);
    if (q.length <= 1) return q;
    var cur = state.queueIndex;
    if (cur < 0 || cur >= q.length) cur = 0;
    final current = q.removeAt(cur);
    q.shuffle(math.Random());
    q.insert(0, current);
    return q;
  }

  static int _indexOfTrack(List<Track> q, Track track) {
    for (var i = 0; i < q.length; i++) {
      final t = q[i];
      if (t.id == track.id && t.source == track.source) return i;
    }
    return -1;
  }

  Future<void> _onTrackEnded() async {
    final q = state.queue;
    if (q.isEmpty) return;
    if (state.repeatMode == 'one') {
      final idx = state.queueIndex;
      if (idx < 0 || idx >= q.length) return;
      final track = q[idx];
      final url = await _resolveSource(track, quality: state.quality);
      if (url == null || url.isEmpty) {
        _log('单曲循环无法解析播放源: ${track.title}');
        await _handleTrackFailure(track, '单曲循环无可用播放源');
        return;
      }
      _log('单曲循环: ${track.title}');
      final ok = await _playTrackMeta(url, track);
      if (!ok) await _handleTrackFailure(track, '单曲循环播放失败');
      return;
    }
    await playNext();
  }
}

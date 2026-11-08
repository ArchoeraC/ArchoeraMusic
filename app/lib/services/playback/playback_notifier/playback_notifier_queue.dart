// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../playback_notifier.dart';

mixin _PlaybackNotifierQueue on _PlaybackNotifierBase {
  /// 连续失败硬上限。
  static const _maxConsecutiveFailures = 5;

  /// 随机模式待播袋（只存曲目键，队列本身保持原顺序）。
  final ShuffleBag _shuffleBag = ShuffleBag();

  /// 随机模式播放历史（键），用于「上一首」回到上一首随机曲目。
  final List<String> _shuffleHistory = <String>[];

  /// 随机历史长度上限（避免长时间随机播放无限增长）。
  static const _maxShuffleHistory = 200;

  /// 曲目在随机袋中的稳定键（source + id；id 为空时回退标题/歌手）。
  static String _trackKey(Track track) {
    final id = track.id.trim();
    if (id.isNotEmpty) return '${track.source}\u0000$id';
    return '${track.source}\u0000${track.title}\u0000${track.subtitle}';
  }

  int _indexOfKey(List<Track> q, String key) {
    for (var i = 0; i < q.length; i++) {
      if (_trackKey(q[i]) == key) return i;
    }
    return -1;
  }

  /// 清空随机袋 / 历史（退出随机、重装队列、清空队列时调用）。
  void _resetShuffleState() {
    _shuffleBag.clear();
    _shuffleHistory.clear();
  }

  /// 重填待播袋：排除当前曲，保证新一轮先覆盖队列其余曲目。
  void _refillShuffleBag({int? excludeIndex}) {
    final q = state.queue;
    final exclude = excludeIndex ?? state.queueIndex;
    _shuffleBag.reset([
      for (var i = 0; i < q.length; i++)
        if (i != exclude) _trackKey(q[i]),
    ]);
  }

  /// 清理已从队列删除的曲目键；返回是否仍有待播曲目。
  bool _pruneShuffleBag() {
    final keys = {for (final t in state.queue) _trackKey(t)};
    _shuffleBag.retainWhere(keys.contains);
    return !_shuffleBag.isEmpty;
  }

  bool _shuffleCycleExhausted() => !_pruneShuffleBag();

  /// 从待播袋随机取下一首的队列下标；袋空时按需开启新一轮。
  int? _takeShuffleIndex({bool refill = true}) {
    final q = state.queue;
    if (q.isEmpty) return null;
    if (q.length == 1) return 0;
    if (!_pruneShuffleBag() && refill) _refillShuffleBag();
    final key = _shuffleBag.take();
    if (key == null) return null;
    final idx = _indexOfKey(q, key);
    return idx >= 0 ? idx : _takeShuffleIndex(refill: refill);
  }

  void _pushShuffleHistory() {
    final track = state.currentQueueTrack;
    if (track == null) return;
    _shuffleHistory.add(_trackKey(track));
    if (_shuffleHistory.length > _maxShuffleHistory) {
      _shuffleHistory.removeAt(0);
    }
  }

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
      final platform = sourcePlatform(track.source);
      // 纯内存播放（不落盘）优先：开启时不读也不写歌曲磁盘缓存——否则与
      // 「不落盘」语义冲突（缓存读命中会走本地文件、未命中会后台落盘）。
      if (!prefs.engineMemoryPlay &&
          prefs.songCacheEnabled &&
          url.isNotEmpty &&
          platform.songCacheable) {
        final id = platform.songCacheId(track);
        final key = SongCache.shared.cacheKeyFor(track.source, id, q);
        final cached = SongCache.shared.lookup(key);
        if (cached != null) {
          playUrl = cached;
        } else {
          unawaited(
            SongCache.shared
                .storeAsync(key, url, referer: platform.songCacheReferer)
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
    // 播放前的**展示元数据**补齐（如 NK 用其它源补全标题/歌手/封面）；
    // 不改 id/source，播放仍走本源。失败静默用原元数据。
    playTrack = await sourcePlatform(track.source).enrichMetadata(ref, track);
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
    final platform = sourcePlatform(track.source);
    if (!platform.autoFallback) return false;
    final title = track.title.trim();
    if (title.isEmpty) return false;
    final contentKey = _trackContentKey(track);
    if (_fallbackAttempted.contains(contentKey)) return false;
    _fallbackAttempted.add(contentKey);

    final List<Track> candidates;
    try {
      candidates = await platform.fallbackCandidates(ref, track);
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
      final oldKey = _trackKey(q[state.queueIndex]);
      final newKey = _trackKey(cand);
      q[state.queueIndex] = cand;
      if (state.shuffle) {
        for (var i = 0; i < _shuffleHistory.length; i++) {
          if (_shuffleHistory[i] == oldKey) _shuffleHistory[i] = newKey;
        }
      }
      state = state.copyWith(queue: q);
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
    if (state.shuffle) {
      _pushShuffleHistory();
      final next = _takeShuffleIndex();
      if (next != null) state = state.copyWith(queueIndex: next);
      return;
    }
    final len = q.length;
    final idx = state.queueIndex;
    state = state.copyWith(queueIndex: idx >= len - 1 ? 0 : idx + 1);
  }

  /// 仅测试用：推进到下一首（不触发实际播放）。
  @visibleForTesting
  void debugAdvanceNext() => _advanceNext();

  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    final idx = startIndex.clamp(0, tracks.length - 1);
    _resetShuffleState();
    // 随机模式也保持队列原顺序，只随机决定下一首的队列下标。
    state = state.copyWith(queue: List.of(tracks), queueIndex: idx);
    if (state.shuffle) {
      _refillShuffleBag(excludeIndex: idx);
      _log('随机模式：队列顺序不变，随机待播 ${_shuffleBag.length} 首');
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
      _resetShuffleState();
      state = state.copyWith(queue: [track], queueIndex: 0);
      final ok = await _playTrackMeta(url, track);
      if (!ok) await _handleTrackFailure(track, '播放加载失败');
      return;
    }
    final existing = _indexOfTrack(q, track);
    if (existing != -1) {
      await playAtIndex(existing);
      return;
    }
    if (state.shuffle) _pushShuffleHistory();
    final at = state.queueIndex + 1;
    final nq = List.of(q)..insert(at, track);
    if (state.shuffle) _shuffleBag.remove(_trackKey(track));
    state = state.copyWith(queue: nq, queueIndex: at);
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
    if (state.shuffle) {
      // 随机模式：优先回到本轮的上一首随机曲目；历史为空时按原顺序兜底。
      while (_shuffleHistory.isNotEmpty) {
        final key = _shuffleHistory.removeLast();
        final idx = _indexOfKey(q, key);
        if (idx < 0) continue;
        final cur = state.currentQueueTrack;
        final curKey = cur == null ? null : _trackKey(cur);
        _shuffleBag.remove(key);
        if (curKey != null && curKey != key) _shuffleBag.add(curKey);
        state = state.copyWith(queueIndex: idx);
        await _playCurrent();
        return;
      }
    }
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
      }
      return;
    }
    if (state.shuffle) {
      _pushShuffleHistory();
      // 手动点播的曲目若还在本轮待播袋里，提前取出，避免之后重复播放。
      _shuffleBag.remove(_trackKey(q[index]));
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

  /// 反向循环切换（奇怪的特效 UI 专用）：切到 [repeatModeCycle] 中的**前一项**。
  /// 不改动 [cycleRepeatMode]，自动续播等内部路径仍走正向。
  void cycleRepeatModeReverse() {
    final cycle = repeatModeCycle;
    final i = cycle.indexOf(state.repeatMode);
    final prev = cycle[(i - 1 + cycle.length) % cycle.length];
    setRepeatMode(prev);
  }

  void setShuffle(bool on) {
    if (state.shuffle == on) return;
    _resetShuffleState();
    // 队列本身始终保持原顺序；随机只影响下一首的选择。
    state = state.copyWith(shuffle: on);
    if (on) {
      _refillShuffleBag();
      _log('随机播放已开启：队列顺序不变，将在整个队列中随机跳转');
    } else {
      _log('随机播放已关闭：按队列顺序播放');
    }
  }

  void toggleShuffle() => setShuffle(!state.shuffle);

  Future<void> removeFromQueue(int index) async {
    final q = List.of(state.queue);
    if (index < 0 || index >= q.length) return;
    final isCurrent = index == state.queueIndex;
    final removed = q.removeAt(index);
    if (state.shuffle) {
      final key = _trackKey(removed);
      _shuffleBag.remove(key);
      _shuffleHistory.removeWhere((k) => k == key);
    }
    if (isCurrent) {
      if (q.isEmpty) {
        _resetShuffleState();
        state = state.copyWith(queue: const [], queueIndex: -1);
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
      _resetShuffleState();
      q.add(track);
      state = state.copyWith(queue: q, queueIndex: 0);
      return 0;
    }
    final existing = _indexOfTrack(q, track);
    if (existing != -1) {
      if (existing != qi + 1) moveInQueue(existing, qi + 1);
      return qi + 1;
    }
    final at = qi + 1;
    q.insert(at, track);
    if (state.shuffle) _shuffleBag.add(_trackKey(track));
    state = state.copyWith(queue: q);
    return at;
  }

  /// 追加到队尾（AI 控制 / 批量入队用；与 [insertToQueue] 的「当前曲之后」
  /// 语义互补）。空队列时仅建立队列、不触发播放。
  int appendToQueue(Track track) {
    final q = List.of(state.queue);
    if (q.isEmpty) {
      _resetShuffleState();
      q.add(track);
      state = state.copyWith(queue: q, queueIndex: 0);
      return 0;
    }
    final existing = _indexOfTrack(q, track);
    if (existing != -1) return existing;
    q.add(track);
    if (state.shuffle) _shuffleBag.add(_trackKey(track));
    state = state.copyWith(queue: q);
    return q.length - 1;
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
  }

  Future<void> clearQueue() async {
    _resetShuffleState();
    state = state.copyWith(queue: const [], queueIndex: -1);
    if (state.source != null) {
      await stop();
    }
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
    // 随机播放：队列顺序不变，下一首从待播袋随机跳转；顺序播放（'off'）
    // 在本轮随机完队列后同样自动暂停，列表循环则自动开启下一轮。
    if (state.shuffle) {
      if (state.repeatMode == 'off' && _shuffleCycleExhausted()) {
        state = state.copyWith(playing: false, buffering: false);
        _log('随机播放：本轮已随机播完队列，自动暂停');
        unawaited(_stopEngine());
        toast(ref.read(l10nProvider).queueFinished, type: ToastType.info);
        return;
      }
      await playNext();
      return;
    }
    // 顺序播放（'off'）：播到队列末尾**自动暂停**，不回绕、不续播。
    // 此刻引擎已到 EOF 并自行退出，主动收尾销毁会话；之后按播放键走
    // 「无引擎」续播路径，从头重放本曲（与睡眠定时收尾同款处理）。
    if (isSequentialQueueEnd(state.repeatMode, state.queueIndex, q.length)) {
      state = state.copyWith(playing: false, buffering: false);
      _log('顺序播放：已到队列末尾，自动暂停');
      unawaited(_stopEngine());
      // 明确提示用户「已播完」（顺序播放不会静默地停在队尾）。
      toast(ref.read(l10nProvider).queueFinished, type: ToastType.info);
      return;
    }
    await playNext();
  }
}

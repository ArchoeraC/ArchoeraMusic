import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../netease/track.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../streaming/streaming_client.dart';
import '../streaming/streaming_provider.dart';
import '../streaming/streaming_session.dart';
import 'audio_engine_process.dart';
import 'dj_mode.dart';
import 'playback_session.dart';
import 'playback_state.dart';

export 'fft_frame.dart' show FftFrame;

/// 播放控制器（Notifier）：应用层单一播放状态源（架构文档 §5.3）。
///
/// 组合：AudioEngineProcess（直连 C 引擎：spawn + stdin 控制 + UDS 事件，
/// 全速完整转码 PCM 落盘 WAV）+ 引擎内置 miniaudio 播放（§10.8，替代 libmpv）。
/// 转码完成后引擎自播 WAV：完整时长（ready/playing 事件回填）、seek 走
/// miniaudio 本地 seek（不重启引擎重转码）、位置/播放状态经引擎事件推送。
class PlaybackNotifier extends Notifier<PlaybackState> {
  final List<StreamSubscription<EngineEvent>> _engineSubs = [];

  AudioEngineProcess? _engine;

  /// 最近一次播放位置诊断日志（AUTOPLAY，验证用）。
  int? _lastPosLogMs;

  /// 本会话是否已收到 FFT 帧（仅记录一次，诊断用）。
  bool _fftStarted = false;

  /// 会话快照最近一次落盘位置（毫秒；位置漂移按 5s 节流写盘）。
  int _lastPersistPosMs = -1;

  /// 当前引擎会话的起始偏移（毫秒，恢复续播用）。
  ///
  /// 引擎从 offset 处开始转码，miniaudio 的游标/时长均为 **WAV 相对值**
  /// （WAV 内从 0 计），而 UI/歌词/FFT/PCM 位置需要**绝对位置**
  /// （相对整首曲目，含 offset）。所有位置/时长换算以本字段为准：
  ///   绝对 = 引擎相对值 + _sessionOffsetMs；seek 命令反向：WAV 相对 = 目标 - _sessionOffsetMs。
  int _sessionOffsetMs = 0;

  /// 会话重启后需保持暂停（seek 回退到会话偏移之前且原为暂停态）：
  /// 引擎转码完成后 miniaudio 会自动开始播放，EnginePlaying 事件到达时
  /// 若此标志为 true 则立即暂停（不置 playing），避免闪播。
  bool _pendingPauseAfterReady = false;

  @override
  PlaybackState build() {
    ref.onDispose(() {
      // 退出前同步落盘「关闭前最后一次」现场（同步写，进程销毁也能保住）
      _persistSession();
      _volumeApplyTimer?.cancel();
      _fftActive = false;
      for (final s in _engineSubs) {
        s.cancel();
      }
      _engineSubs.clear();
      // ignore: discarded_futures
      unawaited(_stopEngine());
    });
    // 播放现场自动持久化：结构字段（曲目/队列/模式/音质/播放态）变化即落盘，
    // 播放中位置每 5s 节流写盘一次（保底恢复进度，避免 10Hz 位置事件刷盘）。
    listenSelf((prev, next) {
      if (prev == null) {
        _persistSession();
        return;
      }
      if (prev.source != next.source ||
          prev.trackId != next.trackId ||
          !identical(prev.queue, next.queue) ||
          prev.queueIndex != next.queueIndex ||
          prev.repeatMode != next.repeatMode ||
          prev.shuffle != next.shuffle ||
          prev.quality != next.quality ||
          prev.playing != next.playing) {
        _persistSession();
        return;
      }
      final posMs = next.position.inMilliseconds;
      if (_lastPersistPosMs < 0 || posMs - _lastPersistPosMs >= 5000) {
        _persistSession();
      }
    });
    // 偏好变化（性能模式/频谱开关）时同步 FFT 轮询启停，无需重启引擎。
    ref.listen(appPrefsProvider, (_, _) => _syncFftActive());
    // 初始音量 = 用户偏好（后续 setVolume 同步 prefs 与引擎）。
    return PlaybackState(volume: ref.read(appPrefsProvider).volume);
  }

  /// 退出确认弹窗 duck 前保存的用户音量（null = 非 duck 中）。
  ///
  /// duck（降半）不写 prefs：弹窗出现期间引擎音量临时减半，
  /// [restoreVolume] 恢复该基值，保证「其他时间保持在原音量」。
  double? _duckBaseVolume;

  /// 音量滑条拖动合并定时器：拖动中引擎命令 80ms 合并一次（只发最新值），
  /// 避免高频 FFI 命令风暴打扰引擎线程；prefs 仅在确定操作时落盘。
  Timer? _volumeApplyTimer;

  /// 设置播放音量（0~1 收敛）：立即同步引擎（当前会话）与偏好（落盘）。
  ///
  /// 用于**确定操作**（静音切换、快捷键、滑条拖动结束）；拖动过程请用
  /// [previewVolume]（实时预览不落盘、引擎命令节流合并）。
  Future<void> setVolume(double value) async {
    final v = value.clamp(0.0, 1.0);
    _volumeApplyTimer?.cancel();
    ref.read(appPrefsProvider.notifier).setVolume(v);
    state = state.copyWith(volume: v);
    // ignore: discarded_futures
    await _engine?.setVolume(v);
  }

  /// 音量滑条拖动中的实时预览：只更新 UI state，引擎命令 80ms 节流
  /// 合并（拖动中音量实时可闻，但不产生命令风暴）；不写 prefs——
  /// 拖动结束（onChangeEnd）走 [setVolume] 落盘最终值。
  ///
  /// 语义保证「调整音量不破坏性影响引擎的播放」：拖动期间引擎只收到
  /// 低频 set_volume，且 prefs 只在松开时保存一次。
  void previewVolume(double value) {
    final v = value.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    _volumeApplyTimer?.cancel();
    _volumeApplyTimer = Timer(const Duration(milliseconds: 80), () {
      _volumeApplyTimer = null;
      // ignore: discarded_futures
      unawaited(_engine?.setVolume(v));
    });
  }

  /// 退出确认弹窗出现：引擎音量平滑降至当前一半（小巧思；不落盘）。
  ///
  /// 只渐变**引擎**音量，不更新 `state.volume`——UI 音量滑条保持显示
  /// 用户原音量，不被 duck 的临时降半「明显看出被修改」。
  Future<void> duckVolume() async {
    if (_duckBaseVolume != null) return;
    final base = state.volume;
    _duckBaseVolume = base;
    await _fadeVolume(from: base, to: base / 2);
  }

  /// 退出确认弹窗关闭：引擎音量平滑回升到 duck 前的用户音量（不落盘）。
  /// 同样只动引擎，UI 音量滑条从头到尾显示用户原音量。
  Future<void> restoreVolume() async {
    final base = _duckBaseVolume;
    if (base == null) return;
    _duckBaseVolume = null;
    await _fadeVolume(from: base / 2, to: base);
  }

  /// 引擎音量渐变（约 250ms，easeOut）：每 ~16ms 推送一次引擎音量，
  /// 听感平滑过渡。用于退出弹窗的降半/回升；**不修改 `state.volume`**
  /// （UI 音量控件显示值保持不变），也不写 prefs（用户原音量始终保留）。
  Future<void> _fadeVolume({required double from, required double to}) async {
    const stepMs = 16;
    const totalMs = 250;
    final steps = totalMs ~/ stepMs;
    for (var i = 1; i <= steps; i++) {
      final t = Curves.easeOut.transform(i / steps);
      final v = from + (to - from) * t;
      // ignore: discarded_futures
      await _engine?.setVolume(v);
      await Future<void>.delayed(const Duration(milliseconds: stepMs));
    }
  }

  /// FFT 拉模式（§10.1，事件驱动无轮询）：引擎每 50ms 音频发一条
  /// EnginePosition 事件 → 更新 position 后立即按当前位置从本地 PCM
  /// 分析器缓冲取一帧。暂停/seek 时位置事件天然对齐，无独立 Timer。
  bool _fftActive = false;

  /// 诊断计数：无帧可取时周期性打印 PCM 状态。
  int _diagCounter = 0;

  /// 最近一次取帧位置（毫秒）：取帧节流基准（性能优化）。
  ///
  /// 引擎位置事件 ~50ms 一条，但频谱取帧含同步磁盘 IO + 下混 + FFT，
  /// 按 100ms 节流后 UI 线程负担减半；插值/平滑由 _SpectrumPainter
  /// 承担，10Hz 推送下视觉依旧流畅（原 Web 端也是 50ms 推送 + 帧间
  /// 插值消除阶梯）。初始 -1000 保证首帧立即取。
  int _lastSpectrumAtMs = -1000;

  void _pollSpectrum() {
    if (!_fftActive) return;
    final posMs = state.position.inMilliseconds;
    if (posMs - _lastSpectrumAtMs < 100) return;
    _lastSpectrumAtMs = posMs;
    final pcm = _engine?.pcm;
    if (pcm == null) return;
    final frame = pcm.frameAt(posMs);
    if (frame == null) {
      _diagCounter++;
      if (_diagCounter % 40 == 0) {
        _log(
          'FFT 诊断: pos=${state.position.inMilliseconds}ms '
          '块=${pcm.blockCount} 字节=${pcm.bytesIn}',
        );
      }
      return;
    }
    if (!_fftStarted) {
      _fftStarted = true;
      _log('FFT 频谱已启动: 本地 ${pcm.blockCount} 块，位置事件驱动拉模式');
    }
    state = state.copyWith(fft: frame);
  }

  // ── 会话记忆（关闭前最后一次现场：队列 + 位置 + 模式）───────────────

  /// 启动恢复：读取关闭前最后一次快照，恢复队列/模式/当前曲，按需续播。
  ///
  /// 关闭前在播放 → 自动续播（从保存位置开始）；关闭前暂停 → 仅恢复现场
  /// （播放条显示队列与位置，点播放从保存位置继续）。
  Future<void> restore() async {
    // 「会话记忆」关闭时不恢复任何现场（默认开）；顺带清掉可能残留的旧快照
    // （偏好文件被外部改为关闭等场景），保证关闭记忆期间磁盘零现场数据
    if (!ref.read(appPrefsProvider).sessionMemory) {
      const PlaybackSessionStore().clear();
      return;
    }
    final snapshot = const PlaybackSessionStore().load();
    if (snapshot == null) return;
    final queue = snapshot.queue;
    if (queue.isEmpty && snapshot.track == null) return;
    var idx = snapshot.queueIndex;
    if (idx < -1 || idx >= queue.length) idx = -1;
    _originalQueue = List.of(queue);
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
      position: Duration(milliseconds: snapshot.positionMs),
    );
    final track = snapshot.currentTrack;
    if (track == null) return;
    // 「启动时自动播放」偏好（默认关）：仅恢复现场（暂停态），点播放从保存位置继续
    final autoPlay = ref.read(appPrefsProvider).autoPlayOnLaunch;
    _log(
      '恢复会话: ${queue.length} 首 @${snapshot.positionMs}ms '
      '${snapshot.playing && autoPlay ? '自动续播' : '暂停'}',
    );
    if (!snapshot.playing || !autoPlay) return;
    await _resumeFrom(
      track,
      offsetMs: snapshot.positionMs,
      quality: snapshot.quality,
    );
  }

  /// 从指定位置续播 [track]（恢复会话 / 暂停态点播放共用）。
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
      // 解析/加载异常不打断启动流程：启动恢复与登录态初始化并行，此刻
      // 网络/登录态可能未就绪导致偶发失败。现场保留暂停态，点播放可重试。
      _log('恢复播放异常: ${track.title}: $e');
    }
  }

  /// 落盘当前播放现场（同步写；无任何现场时跳过）。
  void _persistSession() {
    // 「会话记忆」关闭时不落盘（默认开）
    if (!ref.read(appPrefsProvider).sessionMemory) return;
    final s = state;
    if (s.queue.isEmpty && s.track == null && s.source == null) return;
    const PlaybackSessionStore().save(
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
    _lastPersistPosMs = s.position.inMilliseconds;
  }

  /// 加载并播放（直连 C 引擎，AUTOPLAY 场景见 home_page）。
  ///
  /// [title]/[subtitle]/[trackId] 为展示信息（缺省回退 source / 不传），
  /// [track] 为当前曲目（音质切换需要平台/品质信息；本地文件不传），
  /// [quality] 为音质档位（决定转码 bitrate）。UI 层播放条/播放器/列表
  /// 高亮使用。连续调用串行排队执行（后一个先停掉前一个引擎，避免并发
  /// 转码竞态）。
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
    // 抢占式切歌：立即停掉当前引擎（stop 放行其 pending done，旧 load 任务
    // 快速收尾），新任务无需排队等旧会话转码完成即可启动——缓冲中可切歌。
    // ignore: discarded_futures
    unawaited(_stopEngine());
    final task = _loadChain.then((_) async {
      // 转码完成前即可展示标题（_startSession 内部 copyWith 保留之）
      state = state.copyWith(
        title: title,
        subtitle: subtitle,
        trackId: trackId,
        track: track,
        quality: quality,
        buffering: true,
      );
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
          // 已被更新的 load 取代：放弃收尾（历史记录由新会话负责）
          _log('load 被新会话取代: $source');
          return;
        }
        _log('load ok: $source');
        // 播放成功：重置连续失败计数与换源保护（对齐 SPlayer-Next
        // 成功时 consecutiveFailures = 0）
        _consecutiveFailures = 0;
        _fallbackAttempted.clear();
        // 历史播放记录（本地存储，同曲去重置顶；对齐 SPlayer-Next
        // history.record 在播放成功后调用）。失败静默，不影响播放。
        final current = state.track;
        if (current != null) {
          try {
            ref.read(historyStoreProvider).record(current);
          } catch (_) {}
        }
      } catch (e, s) {
        _log('load 失败: $e\n$s');
        state = state.copyWith(buffering: false);
        rethrow;
      }
    });
    _loadChain = task.catchError((_) {});
    return task;
  }

  /// 设置变更后重载当前曲目（转码开关切换即时生效）。
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

  /// 音质切换：按当前曲目平台重新解析播放源并重载引擎。
  ///
  /// [quality] 为 SPlayer-Next 档位（lq/sq/hq/lossless/hi-res）。
  /// 解析失败保持原音质播放，仅记录日志。
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

  /// 串行播放队列（见 [load]）。
  Future<void> _loadChain = Future<void>.value();

  /// 加载代际号：每次 [load] 递增。旧代际会话（创建中/转码中）发现被取代后
  /// 立即停掉自身引擎，不再等待转码完成——缓冲中切歌不再排队干等旧转码。
  int _loadGen = 0;

  /// 连续加载失败计数（成功播放时归零；对齐 SPlayer-Next consecutiveFailures）。
  int _consecutiveFailures = 0;

  /// 连续失败硬上限（对齐 SPlayer-Next MAX_CONSECUTIVE_FAILURES）。
  static const _maxConsecutiveFailures = 5;

  /// 本失败序列中已尝试过平台换源的曲目内容键（规范化标题|歌手，见
  /// [_tryFallbackSource]）：防止网/狗同曲互切死循环；播放成功时清空。
  final Set<String> _fallbackAttempted = {};

  // ── 播放队列 / 切歌（对齐原项目 core/player 语义）───────────────────

  /// 统一解析曲目播放源。
  ///
  /// local → 本地文件路径；kugou / netease → 对应平台 API 解析播放 URL
  /// （音质档跟随 [quality]，缺省取当前档位）；streaming 等暂未接入返回 null。
  Future<String?> _resolveSource(Track track, {String? quality}) async {
    final q = quality ?? state.quality;
    if (track.source == 'local') {
      final p = track.localPath;
      if (p == null || p.isEmpty) {
        _log('缺少本地文件路径: ${track.title}');
        return null;
      }
      return p;
    }
    if (track.source == 'kugou' && track.kugou != null) {
      return ref
          .read(kugouApiProvider)
          .resolvePlayUrl(track.kugou!, quality: q);
    }
    if (track.source == 'netease') {
      return ref.read(neteaseApiProvider).resolvePlayUrl(track.id, quality: q);
    }
    if (track.source == 'streaming') {
      final serverId = track.serverId;
      final originalId = track.originalId;
      if (serverId == null || originalId == null || originalId.isEmpty) {
        _log('流媒体曲目缺少 serverId/originalId: ${track.title}');
        return null;
      }
      final cfg = ref
          .read(streamingProvider.notifier)
          .serverConfigById(serverId);
      if (cfg == null) {
        _log('流媒体服务器不存在: $serverId（${track.title}）');
        return null;
      }
      return StreamingClient(
        cfg,
      ).getStreamUrl(originalId, playSessionId: sessionIdForTrack(track.id));
    }
    _log('暂不支持的播放源: ${track.source}（${track.title}）');
    return null;
  }

  /// 按元信息加载并播放（队列切歌统一入口；失败记录日志返回 false）。
  Future<bool> _playTrackMeta(
    String url,
    Track track, {
    String? quality,
    int offsetMs = 0,
  }) async {
    final q = quality ?? state.quality;
    try {
      await load(
        url,
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

  /// 播放队列中当前索引曲目。
  ///
  /// 解析/加载失败不打断播放流程：先尝试 [多源自动切换]（_tryFallbackSource），
  /// 无替代版本则自动跳过到下一首（_skipOnFailure，对齐 SPlayer-Next
  /// skipOnFailure：连续失败达上限或队列长度时停播）。
  Future<void> _playCurrent() async {
    // Fuck DJ Mode：加载 DJ 版曲目前自动跳到下一首（对齐原项目 loadTrack；
    // guard 上限 = 队列长度，防整队都是 DJ 时死循环）
    if (ref.read(appPrefsProvider).fuckDjMode) {
      var guard = 0;
      final len = state.queue.length;
      while (guard < len) {
        final cur = state.currentQueueTrack;
        if (cur == null || !shouldSkipDjTrack(cur)) break;
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
    final String? url;
    try {
      url = await _resolveSource(track, quality: state.quality);
    } catch (e) {
      _log('解析播放源异常: ${track.title}: $e');
      return _handleTrackFailure(track, '解析播放源异常');
    }
    if (url == null || url.isEmpty) {
      _log('无法解析播放源: ${track.title}');
      await _handleTrackFailure(track, '无可用播放源');
      return;
    }
    final ok = await _playTrackMeta(url, track);
    if (!ok) {
      await _handleTrackFailure(track, '播放加载失败');
    }
  }

  /// 单曲失败兜底：先尝试其他平台同名版本自动换源（[多源切换]，对齐
  /// Mineradio provider-fallback），换源未接管则自动跳过下一首；达到连续
  /// 失败上限/队列长度时停播（对齐 SPlayer-Next skipOnFailure）。
  Future<void> _handleTrackFailure(Track track, String reason) async {
    _log('播放失败: ${track.title}（$reason）');
    if (await _tryFallbackSource(track)) return;
    await _skipOnFailure('${track.title}：$reason');
  }

  /// 连续失败保护：递增失败计数，达上限或队列长度则停播，否则跳下一首。
  ///
  /// 对齐 SPlayer-Next `skipOnFailure`：`consecutiveFailures++`，
  /// 达到 `MAX_CONSECUTIVE_FAILURES(5)` 或 `queue.queueLength` 交
  /// `onQueueEnded` 停下，否则 nextTrack。
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

  /// 多源自动切换（对齐 Mineradio `provider-fallback`）：当前平台无源/
  /// 无法播放时，用「标题 + 歌手」在其他平台搜索同名版本；命中且可解析
  /// 播放 URL 则替换队列条目并播放。返回是否成功接管（未接管时由调用方
  /// 决定跳过）。
  ///
  /// 防死循环：本失败序列中同一内容（规范化标题|歌手）只尝试一次换源，
  /// 防止网/狗同曲互切（netease → kugou 失败 → 又搜回 netease）。
  Future<bool> _tryFallbackSource(Track track) async {
    // 本地/流媒体曲目无平台搜索语义，直接放弃换源
    if (track.source == 'local' || track.source == 'streaming') return false;
    final title = track.title.trim();
    if (title.isEmpty) return false;
    // 同一内容在本次失败序列中已尝试过换源 → 直接跳过（防互切死循环）
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
      // 同步原始队列（关闭随机时恢复顺序用）
      final orig = _originalQueue;
      if (orig != null && state.queueIndex < orig.length) {
        orig[state.queueIndex] = cand;
      }
      final ok = await _playTrackMeta(url, cand);
      return ok;
    }
    return false;
  }

  /// 曲目内容键（规范化标题|歌手，用于换源去重，对齐 Mineradio
  /// `sourceFallbackRecoveryContentKey`）。
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

  /// 规范化匹配文本：去除括号副题（live/remix 等）与分隔符，对齐
  /// Mineradio `normalizeMatchText`。
  static String _normText(String s) => s
      .replaceAll(RegExp(r'[（(【\[].*?[）)】\]]'), '')
      .replaceAll(RegExp(r'''[\s·・\-—_.,，。:："'‘’/\\|]+'''), '')
      .toLowerCase();

  /// 标题 + 歌手（任一歌手重叠）匹配，对齐 Mineradio `isSameTitleArtist`。
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

  /// 前进到下一首：末尾回绕；随机模式末尾重新洗牌（当前曲置顶、新队列 index=1）。
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

  /// 设置播放队列并从 [startIndex] 开始播放（对齐原项目 playFrom）。
  ///
  /// 随机模式开启时自动洗牌（当前曲置顶）。队列替换式语义：先停当前
  /// 引擎，再从起始曲目加载。
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

  /// 播放/接入单曲：队列中已有则跳转，否则建立单曲队列（保证切歌可用）。
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

  /// 立即播放 [track]（对齐原项目 playNow）：队列已有则跳转，否则插入到
  /// 当前曲目之后并播放。[resolvedUrl] 已由调用方解析时直接使用（在线曲目
  /// 避免重复请求）。
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

  /// 播放上一首（首位回绕到末尾，对齐原项目 prevTrack）。
  Future<void> playPrevious() async {
    final q = state.queue;
    if (q.isEmpty) return;
    final idx = state.queueIndex > 0 ? state.queueIndex - 1 : q.length - 1;
    state = state.copyWith(queueIndex: idx);
    await _playCurrent();
  }

  /// 播放下一首（末尾回绕；随机模式末尾重新洗牌，对齐原项目 nextTrack）。
  Future<void> playNext() async {
    if (state.queue.isEmpty) return;
    _advanceNext();
    await _playCurrent();
  }

  /// 跳转队列指定位置（同曲仅恢复播放，对齐原项目 playAtIndex）。
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

  /// 设置播放模式（'list' 列表循环 / 'one' 单曲循环）。
  void setRepeatMode(String mode) {
    if (!repeatModeCycle.contains(mode)) return;
    if (state.repeatMode == mode) return;
    state = state.copyWith(repeatMode: mode);
    _log('播放模式 → ${repeatModeLabels[mode] ?? mode}');
  }

  /// 循环切换播放模式：list → one → list（对齐原项目 cycleRepeatMode）。
  void cycleRepeatMode() {
    final cycle = repeatModeCycle;
    final next = cycle[(cycle.indexOf(state.repeatMode) + 1) % cycle.length];
    setRepeatMode(next);
  }

  /// 切换随机模式：开启洗牌（当前曲置顶）；关闭恢复原始顺序定位当前曲。
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

  /// 从队列移除指定位置（当前曲被移除时自动播下一首/停止）。
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

  /// 把 [track] 插入到当前曲目之后（「下一首播放」）；已在队列则移动过去。
  ///
  /// 返回曲目在队列中的位置。
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

  /// 移动队列中曲目位置（含 queueIndex 修正，对齐原项目 moveInQueue）。
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

  /// 清空播放队列（并停止当前播放，播放条随之自动收缩隐藏）。
  Future<void> clearQueue() async {
    state = state.copyWith(queue: const [], queueIndex: -1);
    _originalQueue = null;
    if (state.source != null) {
      await stop();
    }
  }

  /// 原始队列（关闭随机时恢复顺序用）。
  List<Track>? _originalQueue;

  /// 洗牌当前队列，当前曲置顶 index 0（对齐原项目 queue.shuffleQueue）。
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

  /// 在队列中定位 track（按 source + id 匹配，避免跨平台同 id 撞车）。
  static int _indexOfTrack(List<Track> q, Track track) {
    for (var i = 0; i < q.length; i++) {
      final t = q[i];
      if (t.id == track.id && t.source == track.source) return i;
    }
    return -1;
  }

  /// 队列自然播完（miniaudio EOF）：单曲循环重载当前曲从头播放，
  /// 否则下一首。EOF 后引擎可能已退出，seek+play 不可靠，故单曲循环
  /// 走重新加载（等价且健壮）。
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

  /// seek：miniaudio 本地 seek（完整 WAV 已就绪，无需重启引擎重转码）。
  ///
  /// [offset] 为**绝对位置**（进度条/快捷键语义）；恢复续播会话（偏移 > 0）
  /// 时引擎 WAV 仅含 offset 之后的音频，命令需换算为 WAV 相对位置。
  ///
  /// 目标早于会话起始偏移时（如记忆恢复后把进度条往回拖），当前 WAV 不含
  /// 更早的音频，本地 seek 会卡在恢复点（回到 offset 处，音频无法后退）。
  /// 此时从目标位置重启引擎会话重新转码，恢复后可自由前后拖动。
  Future<void> seek(Duration offset) async {
    final engine = _engine;
    final src = state.source;
    if (engine == null || src == null) return;
    try {
      final targetMs = offset.inMilliseconds;
      if (targetMs < _sessionOffsetMs) {
        _log(
          'seek 目标早于会话偏移，重启引擎重转码: '
          '${targetMs}ms < ${_sessionOffsetMs}ms',
        );
        final wasPlaying = state.playing;
        _pendingPauseAfterReady = !wasPlaying;
        state = state.copyWith(buffering: true);
        final passthrough = ref.read(appPrefsProvider).passthrough;
        await _startSession(
          src,
          offsetMs: math.max(0, targetMs),
          bitrate: qualityBitrate[state.quality] ?? 128000,
          passthrough: passthrough,
        );
        // _startSession 已置 position = 新偏移，EngineReady/Playing 回填时长
        return;
      }
      final relMs = targetMs - _sessionOffsetMs;
      await engine.seek(Duration(milliseconds: relMs));
      // 立即回填绝对位置（引擎 seek 后首帧位置事件前，UI 不闪回 0:00）
      state = state.copyWith(position: offset);
      _log('seek ok: ${targetMs}ms');
    } catch (e) {
      _pendingPauseAfterReady = false;
      _log('seek 失败: $e');
      rethrow;
    }
  }

  /// 停止（停引擎；播放器随引擎终止）。
  Future<void> stop() async {
    _fftActive = false;
    _sessionOffsetMs = 0;
    _pendingPauseAfterReady = false;
    await _stopEngine();
    state = state.copyWith(
      source: null,
      title: null,
      subtitle: null,
      trackId: null,
      track: null,
      sessionId: null,
      playing: false,
      position: Duration.zero,
      fft: null,
      buffering: false,
    );
    _log('已停止');
  }

  /// 启动引擎会话：全速完整转码 PCM 落盘 WAV，完成后引擎自播（miniaudio）。
  ///
  /// [passthrough] 原音质直通（来自设置开关）：true = 引擎保持源采样率；
  /// false = 统一 48kHz 转码管线。
  ///
  /// [gen] 为发起方捕获的加载代际号（见 [load]）；0 表示不参与抢占检查
  /// （seek 回退重启会话等内部路径）。创建中/转码中被更新的 load 取代时
  /// 立即停掉自身引擎，不再等待转码完成——缓冲中切歌的落点。
  Future<void> _startSession(
    String source, {
    required int offsetMs,
    required int bitrate,
    bool passthrough = true,
    int gen = 0,
  }) async {
    await _stopEngine();
    final engine = await AudioEngineProcess.start(
      source: source,
      offsetMs: offsetMs,
      bitrate: bitrate,
      passthrough: passthrough,
    );
    // 创建期间被更新的 load 取代：丢弃刚创建的引擎（不播放、不监听）
    if (gen != 0 && gen != _loadGen) {
      _log('会话被新 load 取代，丢弃刚创建的引擎');
      await engine.stop();
      return;
    }
    _engine = engine;
    _sessionOffsetMs = offsetMs;
    _engineSubs.add(engine.events.listen(_onEngineEvent));
    _fftStarted = false;
    // 新会话应用当前音量（引擎进程新起，默认 1.0）
    // ignore: discarded_futures
    unawaited(engine.setVolume(state.volume));
    state = state.copyWith(
      source: source,
      sessionId: engine.sessionId,
      playing: false,
      // 恢复续播：进度条/歌词直接展示保存位置（引擎 WAV 内游标为相对值，
      // 但尚未产生位置事件前，先以绝对偏移填充，避免显示 0:00）。
      position: Duration(milliseconds: offsetMs),
      duration: Duration.zero, // 待 ready 事件回填完整时长
      fft: null,
    );
    // 取帧由 _syncFftActive 门控：进入播放（EnginePlaying）才启用事件驱动取帧
    // 等待完整转码（done 时 WAV 已落盘完整）→ 引擎自播
    await engine.done;
    // 转码期间被更新的 load 取代（stop 已放行 done）：不进入自播阶段，
    // 引擎已被新会话停掉，此处仅收尾
    if (gen != 0 && gen != _loadGen) {
      _log('会话被新 load 取代（转码完成）');
      return;
    }
    _log('转码完成，引擎开始播放 WAV');
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case EngineReady():
        _log(
          '引擎就绪: v${event.version} ${event.durationMs}ms @${event.sampleRate}Hz/${event.channels}ch',
        );
        // 完整时长（原 SPlayer-Next 行为：前端拿到完整时长，转码中即可显示）
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
        // 位置为 WAV 相对值，转绝对（含会话偏移）
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
        // 播放器就绪（miniaudio 已加载 WAV）：回填完整时长 + 进入播放。
        // 引擎上报为 WAV 时长（= 全量 - offset），换算回全量绝对时长。
        final durMs = event.durationMs > 0
            ? event.durationMs + _sessionOffsetMs
            : 0;
        if (durMs > 0) {
          state = state.copyWith(duration: Duration(milliseconds: durMs));
        }
        if (_pendingPauseAfterReady) {
          // seek 回退重启会话且原为暂停态：miniaudio 加载即自动开播，
          // 立即暂停保持原暂停语义（不闪播）
          _pendingPauseAfterReady = false;
          // ignore: discarded_futures
          unawaited(_engine?.pause());
          state = state.copyWith(playing: false, buffering: false);
          _syncFftActive();
          _log('播放器就绪: miniaudio 已加载（保持暂停）');
          return;
        }
        state = state.copyWith(playing: true, buffering: false);
        _syncFftActive();
        _log('播放器就绪: miniaudio 播放 WAV');
      case EnginePosition():
        // 引擎游标为 WAV 相对位置，转绝对（含会话偏移）供进度条/歌词/FFT 使用
        final absMs = event.positionMs + _sessionOffsetMs;
        state = state.copyWith(position: Duration(milliseconds: absMs));
        // 事件驱动取帧（无轮询）：位置每前进 50ms 即按当前绝对位置取一帧
        // FFT（含脉冲强度），暂停/seek 时与播放位置天然对齐
        _pollSpectrum();
        // 诊断（AUTOPLAY）：每 5s 打印一次播放位置，验证引擎播放推进
        if (Platform.environment['ARCHOERA_AUTOPLAY'] == '1' &&
            absMs > 0 &&
            (_lastPosLogMs == null || absMs - _lastPosLogMs! >= 5000)) {
          _lastPosLogMs = absMs;
          _log('播放位置: ${absMs}ms / ${state.duration.inMilliseconds}ms');
        }
      case EnginePlayerEnded():
        state = state.copyWith(playing: false, buffering: false);
        _syncFftActive();
        _log('播放完成（miniaudio EOF）');
        // 队列播完自动切歌：单曲循环 seek 回开头，否则下一首
        unawaited(_onTrackEnded());
      case EngineError():
        _log('引擎错误: ${event.message}');
        state = state.copyWith(buffering: false);
      case EngineExited():
        if (_engine != null) {
          _log('引擎退出 code=${event.code}');
          state = state.copyWith(buffering: false);
        }
    }
  }

  Future<void> _stopEngine() async {
    _fftActive = false;
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      await engine.stop();
    }
  }

  /// 同步 FFT 拉取开关（事件驱动，无 Timer）：仅在引擎存在、播放中且
  /// 非性能模式时允许按 EnginePosition 事件取帧；暂停/停播即停（节能）。
  void _syncFftActive() {
    final performanceMode = ref.read(appPrefsProvider).performanceMode;
    _fftActive = !performanceMode && _engine != null && state.playing;
  }

  /// 播放/暂停切换（引擎 stdin 命令；音量/EQ 引擎参数化后续接入）。
  ///
  /// 恢复的暂停态会话（引擎未运行但有当前曲）点播放时，从保存位置续播。
  void toggle() {
    final engine = _engine;
    if (engine == null) {
      final track = state.currentQueueTrack;
      if (track == null || state.playing) return;
      _log('从保存位置续播: ${track.title} @${state.position.inMilliseconds}ms');
      // ignore: discarded_futures
      unawaited(_resumeFrom(track, offsetMs: state.position.inMilliseconds));
      return;
    }
    if (state.playing) {
      engine.pause();
      state = state.copyWith(playing: false);
    } else {
      engine.play();
      state = state.copyWith(playing: true);
    }
    _syncFftActive();
  }

  void _log(String line) {
    final ts = DateTime.now().toString().substring(11, 19);
    final logs = ['$ts $line', ...state.logs];
    if (logs.length > 200) logs.removeRange(200, logs.length);
    state = state.copyWith(logs: logs);
    // 诊断：镜像到 stdout（ARCHOERA_AUTOPLAY=1 时）
    if (Platform.environment['ARCHOERA_AUTOPLAY'] == '1') {
      stdout.writeln('[app:log] $ts $line');
    }
  }
}

/// 播放控制器（单一播放状态源，AppShell 渲染后可用）。
final playbackProvider = NotifierProvider<PlaybackNotifier, PlaybackState>(
  PlaybackNotifier.new,
);

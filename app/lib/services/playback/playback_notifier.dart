// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Curves;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../netease/track.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../cache/song_cache.dart';
import '../streaming/streaming_client.dart';
import '../streaming/streaming_provider.dart';
import '../streaming/streaming_session.dart';
import 'audio_engine_process.dart';
import 'dj_mode.dart';
import '../../widgets/dialogs/memory_alert.dart';
import 'engine_bindings.dart';
import 'playback_session.dart';
import 'playback_state.dart';
import 'store_source.dart';

export 'fft_frame.dart' show FftFrame;

part 'playback_notifier/playback_notifier_queue.dart';
part 'playback_notifier/playback_notifier_loading.dart';
part 'playback_notifier/playback_notifier_session.dart';

abstract class _PlaybackNotifierBase extends Notifier<PlaybackState> {
  final List<StreamSubscription<EngineEvent>> _engineSubs = [];

  AudioEngineProcess? _engine;

  /// 当前引擎会话关联的 SegStore 内存源句柄（0 = 无；在线纯内存会话，
  /// docs/audio-memory-source.md §2/§12）。与 [_engine] 同生命周期：会话被
  /// stop / 被新会话取代 / 播放自然结束后，由 [_stopEngine] 在
  /// engine.stop()（join 解码线程）之后 segstore_destroy，避免同句柄重复释放。
  SegStoreHandle _engineStore = 0;

  /// M2.3b：在途整首下载（新 load 取代时 cancel，避免浪费拉流）。
  WholeTrackFetch? _storeFetch;

  /// 输出设备切换失败通知（set_sink 回执 !ok）：设置页订阅后弹错误 toast。
  ///
  /// 仅通知当前引擎会话存在的失败；无会话时偏好已落盘，下次会话由引擎
  /// 会话创建流程自动补发（失败只入日志，设置页已不在场无从提示）。
  final StreamController<String> _sinkFailureCtrl =
      StreamController<String>.broadcast();

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

  /// 冷启动「启动时自动播放」续播尝试进行中（见 [restore]）。
  ///
  /// 目的：防止**中间态落盘覆盖「可续播」快照**。restore 先把现场恢复为
  /// 暂停展示态（playing=false、position=恢复点）再异步启动引擎；若此刻
  /// 正常持久化，会把磁盘上 `playing=true@offset` 的旧快照覆盖成
  /// `playing=false`——当续播因冷启动瞬时原因失败（登录态/网络/解析未就绪、
  /// 源文件暂不可达等）时，降级快照会被永久保留，之后**每次冷启动都不再
  /// 自动续播**（表现为「断点续播失效」）。
  ///
  /// 置位期间 [_persistSession] 不允许把 paused 写盘覆盖可续播快照：
  /// [_retryableSnapshot] 非空时暂停态写盘改为写回该「可续播」快照，只有
  /// 真正进入播放（EnginePlaying）或续播尝试收敛（引擎错误/退出、stop）后
  /// 才解除。失败时磁盘保留 `playing=true@位置` 现场，下次冷启动可重试。
  bool _autoResumeInFlight = false;

  /// 自动续播保护期间，暂停态写盘应写回的可续播快照（restore 开始时读取）。
  PlaybackSnapshot? _retryableSnapshot;

  /// 会话记忆偏好缓存（退出 dispose 时 Riverpod 已进入生命周期禁用期，
  /// 不能再 `ref.read(appPrefsProvider)`，见 [build] 的 onDispose）。
  bool _sessionMemoryEnabled = true;

  /// 退出确认弹窗 duck 前保存的用户音量（null = 非 duck 中）。
  ///
  /// duck（降半）不写 prefs：弹窗出现期间引擎音量临时减半，
  /// [restoreVolume] 恢复该基值，保证「其他时间保持在原音量」。
  double? _duckBaseVolume;

  /// 音量滑条拖动合并定时器：拖动中引擎命令 80ms 合并一次（只发最新值），
  /// 避免高频 FFI 命令风暴打扰引擎线程；prefs 仅在确定操作时落盘。
  Timer? _volumeApplyTimer;

  /// FFT 拉模式（§10.1，事件驱动无轮询）：引擎每 50ms 音频发一条
  /// EnginePosition 事件 → 更新 position 后立即按当前位置从本地 PCM
  /// 分析器缓冲取一帧。暂停/seek 时位置事件天然对齐，无独立 Timer。
  bool _fftActive = false;

  /// 诊断计数：无帧可取时周期性打印 PCM 状态。
  int _diagCounter = 0;

  /// 最近一次取帧位置（毫秒）：取帧节流基准（性能优化）。
  ///
  /// 引擎位置事件 ~50ms 一条，但频谱取帧含同步磁盘 IO + 下混 + FFT，
  /// 按 [_fftPollIntervalMs] 节流后 UI 线程负担减半；插值/平滑由
  /// _SpectrumPainter 承担，10Hz 推送下视觉依旧流畅（原 Web 端也是
  /// 50ms 推送 + 帧间插值消除阶梯）。初始 -1000 保证首帧立即取。
  int _lastSpectrumAtMs = -1000;

  /// 频谱取帧节流间隔（ms）：默认 100ms 基线；节能模式开 → 300ms
  /// 进一步降帧省电（见 _syncFftActive，随偏好实时更新）。
  int _fftPollIntervalMs = 100;

  /// 引擎当前实际生效的位置事件间隔（ms，降频协商回执 event_interval 更新；
  /// 默认 50 = normal 档）。_fftPollIntervalMs 取帧节流跟随该档位。
  int _engineIntervalMs = 50;

  /// 串行播放队列（见 [load]）。
  Future<void> _loadChain = Future<void>.value();

  /// 加载代际号：每次 [load] 递增。旧代际会话（创建中/转码中）发现被取代后
  /// 立即停掉自身引擎，不再等待转码完成——缓冲中切歌不再排队干等旧转码。
  int _loadGen = 0;

  /// 连续加载失败计数（成功播放时归零；对齐 SPlayer-Next consecutiveFailures）。
  int _consecutiveFailures = 0;

  /// 当前会话历史是否已记录（真正开始播放时置位，避免重复记录；
  /// [load] 开新会话时复位）。
  bool _historyRecorded = false;

  /// 本失败序列中已尝试过平台换源的曲目内容键（规范化标题|歌手，见
  /// [_tryFallbackSource]）：防止网/狗同曲互切死循环；播放成功时清空。
  final Set<String> _fallbackAttempted = {};

  /// 原始队列（关闭随机时恢复顺序用）。
  List<Track>? _originalQueue;

  Future<void> load(
    String source, {
    int bitrate = 128000,
    String? title,
    String? subtitle,
    String? trackId,
    Track? track,
    String quality = 'hq',
    int offsetMs = 0,
  });

  Future<void> stop();

  Future<void> _startSession(
    String source, {
    required int offsetMs,
    required int bitrate,
    bool passthrough = true,
    int gen = 0,
    SegStoreHandle store = 0,
    bool memoryStore = false,
  });

  Future<void> _stopEngine();

  /// 释放 SegStore 句柄（幂等：0 / 重复调用安全，见 engine_bindings）。
  ///
  /// 仅在引擎会话已 destroy（join 完成）后调用（docs/audio-memory-source.md
  /// §12 释放顺序 = 唤醒 → join → free，杜绝 use-after-free）。释放失败静默
  /// 忽略：不中断播放主流程，且本方法可能在 provider dispose 收尾期被调用
  /// （届时不能触碰 state/_log）。
  void _destroyStore(SegStoreHandle store) {
    if (store == 0) return;
    try {
      EngineBindings.instance.segstoreDestroy(store);
    } catch (_) {
      // 罕见；静默（dispose 收尾期不可记日志）
    }
  }

  void _pollSpectrum();

  void _syncFftActive();

  void _log(String line);
}

/// 播放控制器（Notifier）：应用层单一播放状态源（架构文档 §5.3）。
///
/// 组合：AudioEngineProcess（直连 C 引擎：FFI create + 命令/事件 FIFO，
/// 流式起播：边解码边出声）+ 引擎内置播放/出声。
/// 输出形态（2026-09-08 起）：**默认内存播放模式**——解码 PCM 驻留引擎内存块列表、
/// 频谱走 pcm_window FFI，不写 stream.wav/.pcm；**文件模式**（设置「内存播放」关 /
/// env `ARCHOERA_ENGINE_FILE_MODE=1`）保留「PCM 落盘 WAV + 文件拉模式 FFT」旧路径
/// （详见 docs/audio-memory-playback.md）。
/// 会话启动门槛 = ready（见 [AudioEngineProcess.started]，done 在流式下只在
/// 曲尾到达）；完整时长（ready/playing 事件回填）、seek 走引擎本地 seek
/// （不重启引擎重转码）、位置/播放状态经引擎事件推送。文件模式无声设备回退旧路径：
/// 全速完整转码落盘 WAV 后再自播；内存模式无设备直接 error（不文件回退）。
class PlaybackNotifier extends _PlaybackNotifierBase
    with
        _PlaybackNotifierQueue,
        _PlaybackNotifierLoading,
        _PlaybackNotifierSession {
  @override
  PlaybackState build() {
    ref.onDispose(() {
      // 退出前同步落盘「关闭前最后一次」现场（同步写，进程销毁也能保住）。
      // 注意：此时不能经 ref 读其它 provider（Riverpod dispose 生命周期禁读，
      // 会抛断言）；会话记忆开关改用 build 期缓存的 [_sessionMemoryEnabled]。
      _autoResumeInFlight = false;
      _retryableSnapshot = null;
      _persistSession();
      _volumeApplyTimer?.cancel();
      _fftActive = false;
      for (final s in _engineSubs) {
        s.cancel();
      }
      _engineSubs.clear();
      _sinkFailureCtrl.close();
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
    // 偏好变化时同步会话记忆缓存与 FFT 轮询启停，无需重启引擎。
    _sessionMemoryEnabled = ref.read(appPrefsProvider).sessionMemory;
    ref.listen(appPrefsProvider, (_, next) {
      _sessionMemoryEnabled = next.sessionMemory;
      _syncFftActive();
    });
    // 初始音量 = 用户偏好（后续 setVolume 同步 prefs 与引擎）。
    return PlaybackState(volume: ref.read(appPrefsProvider).volume);
  }

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

  /// 输出设备切换失败流（err 文本；见 [_sinkFailureCtrl]）。
  Stream<String> get sinkFailures => _sinkFailureCtrl.stream;

  /// 把输出设备偏好下发到当前引擎会话（`set_sink`，id 空串 = 系统默认）。
  ///
  /// 无会话时忽略——偏好已落盘，下次会话创建后由 [_startSession] 读取
  /// 自动补发（重启后亦保持）。
  Future<void> applyOutputSink(String sinkId) async {
    final engine = _engine;
    if (engine == null) return;
    await engine.sendCommand('set_sink', {'id': sinkId});
  }

  @override
  void _pollSpectrum() {
    if (!_fftActive) return;
    final posMs = state.position.inMilliseconds;
    // 降帧协商：位置回退（seek 后退 / 切歌 / 会话重启）时视为节流基准
    // 失效，立即重置并取帧——否则 posMs - _lastSpectrumAtMs 恒为负，
    // FFT 被节流永久拦截（冻结到播放位置追平旧基准，表现如 FFT 崩溃）。
    final sinceLast = posMs - _lastSpectrumAtMs;
    if (sinceLast >= 0 && sinceLast < _fftPollIntervalMs) {
      return; // 正常降帧节流（间隔由节能模式协商）
    }
    _lastSpectrumAtMs = posMs;
    final pcm = _engine?.pcm;
    if (pcm == null) return;
    final frame = pcm.frameAt(posMs);
    if (frame == null) {
      _diagCounter++;
      if (_diagCounter % 40 == 0) {
        _log(
          'FFT 诊断: pos=${state.position.inMilliseconds}ms '
          '块=${pcm.blockCount} 字节=${pcm.bytesIn} epoch=${pcm.epoch}',
        );
      }
      return;
    }
    if (!_fftStarted) {
      _fftStarted = true;
      _log(
        'FFT 频谱已启动: 本地 ${pcm.blockCount} 块，epoch=${pcm.epoch}，'
        '位置事件驱动拉模式',
      );
    }
    state = state.copyWith(fft: frame);
  }

  // ── 会话记忆（关闭前最后一次现场：队列 + 位置 + 模式）───────────────

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
  @override
  Future<void> stop() async {
    // 作废排队/在途的 load（含内存源整首下载完成后不再续播；见 loading.load 的
    // gen 校验）。注意 stop 后仍会经用户再触发 load，gen 单调递增无副作用。
    _loadGen++;
    _fftActive = false;
    _sessionOffsetMs = 0;
    _pendingPauseAfterReady = false;
    // 用户主动停止：快照保护解除（paused 可落盘，覆盖自动续播现场）
    _autoResumeInFlight = false;
    _retryableSnapshot = null;
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

  /// 同步 FFT 拉取开关（事件驱动，无 Timer）：仅在引擎存在、播放中且
  /// 非性能模式时允许按 EnginePosition 事件取帧；暂停/停播即停（节能）。
  /// 取帧节流间隔 = 基线（100ms / 节能 300ms）与引擎事件间隔的较大者——
  /// 降频档位下 position 事件本身变稀，FFT 取帧跟随（engine-event-push-plan）。
  @override
  void _syncFftActive() {
    final prefs = ref.read(appPrefsProvider);
    _fftPollIntervalMs = math.max(
      prefs.energySavingMode ? 300 : 100,
      _engineIntervalMs,
    );
    _fftActive = !prefs.performanceMode && _engine != null && state.playing;
  }

  /// 降频协商（engine-event-push-plan §4.1）：按节能档位向引擎请求位置事件
  /// 间隔（normal 50 / minimized 500 / unfocused+screenOff 1000）。引擎未
  /// 就绪时忽略——转码期协商被 C 侧记录，播放器启动即应用。
  /// 恢复前台（≤50ms）时顺带拉一次 get_status 精确对齐位置/歌词。
  Future<void> setEngineEventInterval(int intervalMs) {
    final engine = _engine;
    if (engine == null) return Future.value();
    if (intervalMs <= 50) {
      // ignore: discarded_futures
      unawaited(engine.requestStatus());
    }
    return engine.setEventInterval(intervalMs);
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

  @override
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

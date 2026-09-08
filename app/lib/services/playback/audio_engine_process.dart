// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../stores/app_prefs.dart';
import 'engine_bindings.dart';
import 'pcm_analyzer.dart';

/// 引擎控制事件（事件驱动推送 / 回退轮询接收的 JSON 行）。
sealed class EngineEvent {
  const EngineEvent();
}

/// 引擎就绪（管线创建完成，开始转码）。
class EngineReady extends EngineEvent {
  const EngineReady({
    required this.version,
    required this.durationMs,
    required this.sampleRate,
    required this.outSampleRate,
    required this.channels,
  });

  final String version;
  final int durationMs;

  /// 源采样率（诊断）。
  final int sampleRate;

  /// 管线实际输出采样率（player 模式跟随源时即源采样率；PCM/FFT 分析据此建频轴）。
  final int outSampleRate;
  final int channels;
}

/// 引擎状态（get_status 响应；播放模式含 playing 字段）。
class EngineStatus extends EngineEvent {
  const EngineStatus({
    required this.positionMs,
    required this.durationMs,
    this.playing,
  });

  final int positionMs;
  final int durationMs;
  final bool? playing;
}

/// 内容完整解码到 EOF（引擎发 done；内存模式 = 块列表收全，文件模式 = WAV/PCM 完整）。
///
/// 流式起播下此事件在曲目末尾才到达，**不是**「播放已开始」信号——启动
/// 收敛请用 [AudioEngineProcess.started]（ready）。
class EngineDone extends EngineEvent {
  const EngineDone();
}

/// 播放已开始（声音输出已建立；文件模式指 miniaudio 加载 WAV 后开始播放，
/// duration_ms 为完整时长）。
class EnginePlaying extends EngineEvent {
  const EnginePlaying({required this.durationMs});

  final int durationMs;
}

/// 输出设备切换回执（set_sink 的引擎确认，含失败原因）。
class EngineSinkChanged extends EngineEvent {
  const EngineSinkChanged({required this.ok, this.err});

  final bool ok;
  final String? err;
}

/// 播放位置事件（播放模式，每 50ms 音频 1 帧；驱动 FFT 事件取帧）。
class EnginePosition extends EngineEvent {
  const EnginePosition({required this.positionMs});

  final int positionMs;
}

/// 降频协商回执（set_event_interval 的 C 侧确认，engine-event-push-plan §4.2）。
/// Dart 收到后确认档位生效，后续 position 事件按新间隔到达。
class EngineEventInterval extends EngineEvent {
  const EngineEventInterval({required this.intervalMs});

  final int intervalMs;
}

/// 播放自然结束（miniaudio EOF）。
class EnginePlayerEnded extends EngineEvent {
  const EnginePlayerEnded();
}

/// 引擎错误（pipeline error）。
class EngineError extends EngineEvent {
  const EngineError(this.message);

  final String message;
}

/// 引擎线程退出（stop 主动销毁也触发，code 为退出码）。
class EngineExited extends EngineEvent {
  const EngineExited(this.code);

  final int code;
}

/// 音频引擎会话（桌面端 FFI 直连 libarchoera_mediaengine，替代进程 spawn + UDS）。
///
/// 生命周期：start（FFI create + 引擎线程转码）→ [started]（收到 ready，管线
/// 建立、开始解码/出声）→ 播放 → stop（destroy，清理会话目录）。
///
/// 事件语义（与 C 侧 mediaengine_lib.c 时序对应）：
///   - [started]：`ready` 事件（管线建立）到达即完成——**会话启动门槛**。
///     流式起播下首块 PCM 即出声（playing 紧跟 ready），done 只在曲尾 EOF
///     才到达，因此启动收敛必须以 ready 为准，不能等 done；
///   - [done]：内容完整解码到 EOF（内存块列表收全 / 文件模式下 WAV/PCM 完整）。
///     流式下 ≈ 曲目末尾，仅作「整曲解码完成」标记，不再作为启动门槛。
///
/// 通信模型（2026-08-07 用户决策，摆脱 AF_UNIX/TCP 兼容问题；事件推送
/// 2026-09-05 落地，取代 50ms 轮询）：
///   - 引擎在库内自有线程全速转码 + 播放，FFI 调用均为短调用；
///   - 事件经线程安全 FIFO，Dart 侧用**独立接收 isolate 阻塞等待**
///     `wait_event(..., -1)` 推送到主 isolate（空闲零唤醒/零轮询开销）；
///   - 控制命令（play/pause/seek/...）经 [sendCommand] 入命令 FIFO；
///   - PCM 取用（2026-09-08）：默认**内存播放模式**——引擎内存块列表经
///     `pcm_window` FFI（[MemoryPcmAnalyzer]）；文件模式下引擎直写
///     `stream.pcm`，[PcmAnalyzer] 按需读文件。见 [memoryMode] 与
///     `docs/audio-memory-playback.md`。
///
/// 事件驱动失败/调试可用 `ARCHOERA_EVENT_POLL_FALLBACK=1` 切回旧的 50ms
/// `pollEvent` 轮询（[AudioEngineProcess.start] 时读取，需冷启动生效）。
class AudioEngineProcess {
  AudioEngineProcess._({
    required this.handle,
    required this.sockDir,
    required this.outSampleRate,
    this.memoryMode = false,
    bool startPoller = true,
  }) {
    _eventsCtrl = StreamController<EngineEvent>.broadcast();
    if (startPoller) {
      if (_usePollFallback) {
        // 回退模式：旧 50ms Timer 轮询（调试/事件泵不可用时的降级路径）。
        _pollTimer = Timer.periodic(_pollInterval, (_) => _drainEvents());
      } else if (handle != 0) {
        // 推模式：接收 isolate 阻塞 wait_event → SendPort 事件 → 本类分发。
        _pumpReady = Completer<void>();
        _startEventPump();
      }
    }
    // 兜底吞掉无人 await 的异步错误：error/exited 事件会给 started/done 补
    // completeError（见 _onControlLine），若此刻调用方已越过该门槛（如会话
    // 播放中被新会话取代/自然收尾），错误无监听者会落成 zone 未处理异常。
    // catchError 派生 future 忽略即可——原 future 仍可被后续任何真实监听者
    // （await / .timeout）收到同一结果，不影响语义。
    // ignore: discarded_futures
    _startedCompleter.future.catchError((_) {});
    // ignore: discarded_futures
    _doneCompleter.future.catchError((_) {});
    // 转码在引擎线程进行，无需消费 stdout（无进程管道）
  }

  /// 事件轮询间隔（仅回退模式使用：引擎事件低频，position 每 100ms 音频
  /// 1 帧）。
  static const _pollInterval = Duration(milliseconds: 50);

  /// 事件接收推送模式开关：设 `ARCHOERA_EVENT_POLL_FALLBACK=1` 切回旧的
  /// 50ms 轮询（默认关，走接收 isolate 阻塞等待 push）。
  static bool get _usePollFallback =>
      Platform.environment['ARCHOERA_EVENT_POLL_FALLBACK'] == '1';

  /// C 侧引擎句柄（ArchoeraMediaEngine* 地址）。
  final int handle;

  final Directory sockDir;

  /// 管线实际输出采样率（ready 事件回填前为 0/48000 兜底）。
  final int outSampleRate;

  /// 内存播放模式（EngineConfig.no_disk_cache=1）：PCM 驻留引擎内存块列表，
  /// 频谱走 [MemoryPcmAnalyzer]（`pcm_window` FFI），不写 stream.wav/.pcm。
  final bool memoryMode;

  late final StreamController<EngineEvent> _eventsCtrl;
  PcmFftSource? _pcm;
  Timer? _pollTimer;
  bool _stopped = false;

  /// 接收 isolate 事件泵（推模式）：
  ///   - [_eventPort]：主 isolate 收事件串的端口（isolate 首条为就绪握手）；
  ///   - [_eventIsolate]：接收 isolate 句柄（阻塞在 `wait_event(-1)`）；
  ///   - [_pumpReady]：握手完成信号（首条消息到达即就绪）；
  ///   - [_pumpExitPort]：接收 isolate 退出通知（stop 等待其自行退场）。
  ReceivePort? _eventPort;
  Isolate? _eventIsolate;
  Completer<void>? _pumpReady;
  ReceivePort? _pumpExitPort;
  Completer<void>? _pumpExited;

  final Completer<void> _doneCompleter = Completer<void>();

  /// 会话启动门槛：收到引擎 `ready`（管线建立、开始解码）即完成；
  /// 启动失败（error/exited 先于 ready 到达）或 [stop] 主动放弃则释放。
  ///
  /// 语义随流式起播收敛：首块 PCM 即出声后，`done` 只在曲尾 EOF 到达，
  /// 「会话已可播放」必须以 ready（其后紧跟 playing/出声）为界，而非等
  /// 整曲转码结束——否则启动/切歌流程会卡到曲目播完（playAll 等按钮
  /// 全程 loading、期间无法切换曲目）。
  final Completer<void> _startedCompleter = Completer<void>();

  /// 会话已就绪（收到引擎 ready）或已失败/被 [stop] 放弃。
  Future<void> get started => _startedCompleter.future;

  /// 引擎控制事件流（ready/status/done/playing/position/player:ended/error/exited）。
  Stream<EngineEvent> get events => _eventsCtrl.stream;

  /// PCM 拉模式源（文件版 [PcmAnalyzer] 读 stream.pcm / 内存版
  /// [MemoryPcmAnalyzer] 走引擎 pcm_window FFI；UI 拉模式取帧）。
  PcmFftSource? get pcm => _pcm;

  /// 播放器 WAV 文件路径（**仅文件模式**使用；内存模式下引擎不写盘，
  /// 此值仅为会话目录占位，见 [memoryMode] / audio-memory-playback.md）。
  String get wavFilePath => '${sockDir.path}/stream.wav';

  /// 原始 PCM 文件路径（**仅文件模式**：引擎直写、[PcmAnalyzer.frameAt] 按需读取；
  /// 内存模式无此文件）。
  String get pcmFilePath => '${sockDir.path}/stream.pcm';

  /// 内容完整解码到 EOF（引擎发 done；WAV/PCM 文件完整）。
  ///
  /// 注意：流式起播下该事件在曲目末尾才到达，**不是**「播放已开始」的信号，
  /// 请用 [started] 作为会话启动门槛。
  Future<void> get done => _doneCompleter.future;

  /// 会话标识（UI 显示用：socket 目录名）。
  String get sessionId => sockDir.uri.pathSegments.last;

  /// 测试专用：构造不连真实引擎、可手工投喂控制行的会话实例（handle=0 →
  /// 轮询/销毁不触碰 FFI；事件解析与 started/done 完成语义与真实会话一致）。
  @visibleForTesting
  factory AudioEngineProcess.testHarness() {
    final sockDir = Directory(
      '${Directory.systemTemp.path}/archoera-test-$pid-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    return AudioEngineProcess._(
      handle: 0,
      sockDir: sockDir,
      outSampleRate: 48000,
      startPoller: false,
    );
  }

  /// 测试专用：以一条 C 侧原始控制行（JSON）驱动事件/门槛状态机。
  @visibleForTesting
  void feedControlLine(String line) => _onControlLine(line);

  /// 启动引擎会话（FFI；pipeline_create 可能阻塞于网络 IO，放后台 isolate）。
  ///
  /// 参数覆盖架构文档 §5.6：bitrate/EQ/preamp/normalization/tempo/offset。
  /// [passthrough] 原音质直通：true = 引擎保持源采样率（默认）；false = 统一 48kHz。
  static Future<AudioEngineProcess> start({
    required String source,
    int offsetMs = 0,
    int bitrate = 128000,
    bool passthrough = true,
    List<double>? eqGains,
    double preamp = 0,
    bool normalization = false,
    double? tempoSpeed,
    double? tempoPitch,
  }) async {
    // 会话目录统一走系统临时目录（Windows %TEMP% / POSIX /tmp）。
    // 文件模式：引擎 WAV/PCM 落盘 + PcmAnalyzer 按需读取在此；
    // 内存模式：仅作会话句柄目录（引擎不落盘，PCM 走 pcm_window FFI）。
    final sockDir = Directory(
      '${Directory.systemTemp.path}/archoera-${Platform.localHostname}-$pid-${DateTime.now().millisecondsSinceEpoch}',
    )..createSync(recursive: true);
    final playerFile = '${sockDir.path}/stream.wav';

    // 内存播放偏好（每次新会话读取，对下一首生效；文档 audio-memory-playback.md）：
    //   engineMemoryPlay=true → no_disk=1；cap：auto=0 / 用户 limit=MB×1024 / unlimited=-1。
    final mp = AppPrefs.load();
    final memoryOn = mp.engineMemoryPlay;
    final int memCapKb;
    if (!memoryOn) {
      memCapKb = 0;
    } else if (mp.pcmMemPolicy == 'unlimited') {
      memCapKb = -1;
    } else if (mp.pcmMemPolicy == 'limit') {
      memCapKb = mp.pcmMemLimitMb.clamp(1, 1 << 18) * 1024; // KB
    } else {
      memCapKb = 0; // auto
    }

    // FFI create 在后台 isolate 执行：pipeline_create 打开解码器/网络 IO 可能
    // 耗时数百 ms，避免阻塞 UI isolate。config 参数以标量值跨 isolate 传递。
    final handleAddr = await Isolate.run<int>(() {
      // 解码引擎偏好（'eraudio' → engineMode 1；其余稳定 FFmpeg → 0）：
      // 引擎模式在会话创建时读取持久化偏好，不随会话热替换，改动需冷启动生效。
      final engineMode = AppPrefs.load().engine == 'eraudio' ? 1 : 0;
      final cfg = engineConfigFromParams(
        bitrate: bitrate,
        passthrough: passthrough,
        offsetMs: offsetMs,
        eqGains: eqGains,
        preamp: preamp,
        normalization: normalization,
        tempoSpeed: tempoSpeed,
        tempoPitch: tempoPitch,
        engineMode: engineMode,
        noDiskCache: memoryOn ? 1 : 0,
        pcmMemCapKb: memCapKb,
      );
      try {
        final h = EngineBindings.instance.create(
          source: source,
          sessionDir: sockDir.path,
          playerFile: playerFile,
          config: cfg,
        );
        return h.address;
      } finally {
        calloc.free(cfg);
      }
    });

    final engine = AudioEngineProcess._(
      handle: handleAddr,
      sockDir: sockDir,
      outSampleRate: passthrough ? 0 : 48000,
      memoryMode: memoryOn,
    );
    // 事件泵就绪（接收 isolate 已进入阻塞等待）：返回前确认事件通道可用，
    // 失败自动回退 50ms 轮询。引擎事件在 C FIFO 中排队，晚几 ms 不丢失。
    await engine._ensureEventDelivery();
    return engine;
  }

  /// 事件缓冲容量（对齐 pollEvent；事件行上限 EV_LINE 511，留余量）。
  static const _eventBufCap = 2048;

  /// 接收 isolate 就绪握手哨兵（主 isolate 收到的首条消息；其后均为事件串）。
  static const int _enginePumpHandshake = 0x50_4D_50_21; // 'PMP!'

  /// 轮询事件队列并分发（**回退模式**：ARCHOERA_EVENT_POLL_FALLBACK=1 或
  /// 事件泵不可用时，50ms 定时 pollEvent 排空 FIFO）。
  void _drainEvents() {
    final bindings = EngineBindings.instance;
    final ptr = Pointer<Opaque>.fromAddress(handle);
    while (true) {
      final line = bindings.pollEvent(ptr);
      if (line == null) break;
      _onControlLine(line);
    }
  }

  /// 事件泵就绪确认（推模式）：等接收 isolate 握手。失败/超时 → 回退轮询，
  /// 保证事件通道始终可用。
  Future<void> _ensureEventDelivery() async {
    final ready = _pumpReady;
    if (ready == null) return; // 回退模式 / 测试 harness，无事件泵
    try {
      await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      _switchToPollFallback();
    }
  }

  /// 启动接收 isolate 事件泵：隔离线程阻塞 `wait_event(handle,...,-1)`，
  /// 事件串经 SendPort 送回主 isolate 走 [_onControlLine] 分发。
  void _startEventPump() {
    final h = handle;
    if (h == 0) return;
    final port = ReceivePort();
    _eventPort = port;
    port.listen(_onPumpMessage, onError: (Object e, StackTrace _) {
      final ready = _pumpReady;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(StateError('事件泵端口错误: $e'));
      }
    });
    final exitPort = ReceivePort();
    _pumpExitPort = exitPort;
    _pumpExited = Completer<void>();
    unawaited(_spawnEventPump(h, port, exitPort));
  }

  Future<void> _spawnEventPump(int h, ReceivePort port, ReceivePort exitPort) async {
    try {
      final iso = await Isolate.spawn(
        _engineEventPumpEntry,
        <Object?>[h, port.sendPort],
        debugName: 'engine-event-pump-0x${h.toRadixString(16)}',
        onExit: exitPort.sendPort,
        onError: exitPort.sendPort,
      );
      _eventIsolate = iso;
      exitPort.listen((_) {
        // 事件泵退出：
        //   - 正常销毁路径：stop() 已置 _stopped → 忽略（接收线程已自退）；
        //   - 意外崩溃/启动失败 → 补 failed ready + 回退 50ms 轮询兜底。
        final exited = _pumpExited;
        if (exited != null && !exited.isCompleted) exited.complete();
        final ready = _pumpReady;
        if (!_stopped) {
          if (ready != null && !ready.isCompleted) {
            ready.completeError(StateError('事件泵退出'));
          }
          _switchToPollFallback();
        }
      });
    } catch (e) {
      final ready = _pumpReady;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(StateError('事件泵 spawn 失败: $e'));
      }
    }
  }

  /// 事件泵首条消息（握手）后均为事件串 → 分发。
  void _onPumpMessage(Object? msg) {
    final ready = _pumpReady;
    if (ready != null && !ready.isCompleted) {
      ready.complete(); // 握手：接收 isolate 已就绪、即将阻塞 wait_event
      if (msg is int) return; // 哨兵本身不是事件
    }
    if (msg is String && !_stopped) {
      _onControlLine(msg);
    }
  }

  /// 事件泵不可用 → 关停推模式，切回旧 50ms 轮询（调试/兜底）。
  void _switchToPollFallback() {
    if (_stopped || handle == 0 || _pollTimer != null) return;
    _teardownEventPump();
    // ignore: discarded_futures
    _pollTimer = Timer.periodic(_pollInterval, (_) => _drainEvents());
  }

  /// 关停事件泵（stop/回退时）：关闭端口、释放 isolate 引用。
  void _teardownEventPump() {
    final ready = _pumpReady;
    _pumpReady = null;
    _pumpExited = null;
    // 放行仍 await 就绪的调用方（start 收尾不悬空）
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
    _eventPort?.close();
    _eventPort = null;
    final iso = _eventIsolate;
    _eventIsolate = null;
    _pumpExitPort?.close();
    _pumpExitPort = null;
    // 泵已死/即将自退；兜底 kill（非 native 阻塞中则立即生效）
    iso?.kill(priority: Isolate.immediate);
  }

  /// 等待接收 isolate 完全退场（stop 已 destroy，wait_event 返回 -1 自退）。
  Future<void> _awaitPumpExit() async {
    final exited = _pumpExited;
    if (exited != null) {
      try {
        await exited.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        // 异常场景未及时退场：兜底 kill（已不在 native 阻塞内则立即生效）
        _eventIsolate?.kill(priority: Isolate.immediate);
      }
    }
  }

  void _onControlLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      switch (map['type']) {
        case 'ready':
          final outRate =
              (map['out_sample_rate'] as num?)?.toInt() ??
              (map['sample_rate'] as num?)?.toInt() ??
              0;
          _emit(
            EngineReady(
              version: map['version'] as String? ?? '',
              durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
              sampleRate: (map['sample_rate'] as num?)?.toInt() ?? 0,
              outSampleRate: outRate,
              channels: (map['channels'] as num?)?.toInt() ?? 0,
            ),
          );
          // PCM 分析器按管线实际输出采样率打开（FFI 频轴正确）
          unawaited(_openPcm(outRate));
          // 会话启动门槛：ready（管线建立、开始解码/出声）即放行。流式起播
          // 下此处后紧跟 playing（首块 PCM），done 仍在曲尾；启动收敛必须
          // 以 ready 为准（_startSession 由 `await done` 改为 `await started`）。
          if (!_startedCompleter.isCompleted) {
            _startedCompleter.complete();
          }
        case 'status':
          _emit(
            EngineStatus(
              positionMs: (map['position_ms'] as num?)?.toInt() ?? 0,
              durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
              playing:
                  (map['playing'] as bool?) ?? (map['playing'] as num?) == 1,
            ),
          );
        case 'playing':
          _emit(
            EnginePlaying(
              durationMs: (map['duration_ms'] as num?)?.toInt() ?? 0,
            ),
          );
        case 'position':
          _emit(
            EnginePosition(
              positionMs: (map['position_ms'] as num?)?.toInt() ?? 0,
            ),
          );
        case 'event_interval':
          _emit(
            EngineEventInterval(
              intervalMs: (map['interval_ms'] as num?)?.toInt() ?? 0,
            ),
          );
        case 'player:ended':
          _emit(const EnginePlayerEnded());
        case 'sink_changed':
          _emit(
            EngineSinkChanged(
              ok: (map['ok'] as bool?) ?? (map['ok'] as num?) == 1,
              err: map['err'] as String?,
            ),
          );
        case 'done':
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.complete();
          }
          _emit(const EngineDone());
        case 'error':
          final msg = map['message'] as String? ?? 'unknown';
          // done 兼容语义保留：引擎错误也终结「整曲转码」等待（done 仅在
          // 内容 EOF 完成；错误提前到达即失败）。
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.completeError(StateError('引擎错误: $msg'));
          }
          // started 门槛：错误若先于 ready 到达（如管线创建失败）→ 启动失败；
          // ready 已到达后的运行期错误不重放门槛（由 EngineError 事件通知）。
          if (!_startedCompleter.isCompleted) {
            _startedCompleter.completeError(StateError('引擎错误: $msg'));
          }
          _emit(EngineError(msg));
        case 'exited':
          // 引擎线程退出：正常收尾时 done 已完成；若 ready/done 尚未到达就
          // 退出——如启动失败 / 解码异常 / 被 destroy 抢占（此时 _stopEngine
          // 已先经 stop() 放行门槛，这里不重复）——补失败结果，否则启动/切歌
          // 流程会永久挂等（buffering 卡死、表现为「启动后无法播放」）。
          final code = (map['code'] as num?)?.toInt() ?? 0;
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.completeError(StateError('引擎异常退出（code=$code）'));
          }
          if (!_startedCompleter.isCompleted) {
            _startedCompleter.completeError(StateError('引擎异常退出（code=$code）'));
          }
          _emit(EngineExited(code));
      }
    } catch (_) {
      // 非协议行忽略
    }
  }

  /// 打开 PCM 拉模式源（ready 后调用）：
  ///   内存模式 → MemoryPcmAnalyzer（引擎 pcm_window，无文件）；
  ///   文件模式 → PcmAnalyzer（读 stream.pcm，scan 增量补索引）。
  Future<void> _openPcm(int sampleRate) async {
    if (_pcm != null) return;
    final rate = sampleRate > 0 ? sampleRate : 48000;
    try {
      if (memoryMode) {
        _pcm = MemoryPcmAnalyzer(handle: handle, sampleRate: rate);
      } else {
        _pcm = await PcmAnalyzer.open(pcmFilePath, sampleRate: rate);
      }
    } catch (e) {
      // PCM 源不可用：频谱不可用，不影响播放。记录根因便于排查
      // （如 libfft.so 缺失/符号隐藏导致的 FftAnalyzer 构造失败）。
      // ignore: avoid_print
      print('[audio-engine] PCM 分析器打开失败（频谱不可用）: $e');
    }
  }

  void _emit(EngineEvent event) {
    if (!_eventsCtrl.isClosed) {
      _eventsCtrl.add(event);
    }
  }

  /// 发送控制命令（JSON 行 → 引擎命令 FIFO，主 isolate 短调用）。
  Future<void> sendCommand(String type, Map<String, dynamic> fields) async {
    if (_stopped) return;
    final ptr = Pointer<Opaque>.fromAddress(handle);
    EngineBindings.instance.command(ptr, jsonEncode({'type': type, ...fields}));
  }

  /// 播放控制快捷命令（行协议，见 mediaengine_lib.c handle_command）。
  Future<void> play() => sendCommand('play', {});
  Future<void> pause() => sendCommand('pause', {});
  Future<void> seek(Duration position) =>
      sendCommand('seek', {'position_ms': position.inMilliseconds});
  Future<void> setVolume(double gain) =>
      sendCommand('set_volume', {'gain': gain});

  /// 降频协商：请求位置事件间隔（ms，normal 50 / minimized 500 / unfocused
  /// 1000）。C 侧以 `event_interval` 回执确认实际生效值（以回执为准，
  /// 不假设切换已生效）；恢复前台后主动发 [requestStatus] 精确对齐位置。
  Future<void> setEventInterval(int intervalMs) =>
      sendCommand('set_event_interval', {'interval_ms': intervalMs});

  /// 拉取一次精确播放位置（恢复前台时进度/歌词立即对齐）。
  Future<void> requestStatus() => sendCommand('get_status', {});

  /// 停止：destroy（join 引擎线程；唤醒事件泵自退）→ 收尾事件泵 → 清理
  /// 会话目录与本地通道。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _pcm?.dispose();
    _pcm = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    // 放行 pending started/done：stop 由新 load 抢占触发（缓冲中切歌）时，
    // 旧会话 `_startSession` 的 `await engine.started` 立即返回（gen 校验
    // 发现被取代而收尾），不再挂等 ready/曲尾 done 阻塞加载链。注意放行
    // 发生在 destroy/join 之前——engine 线程慢退出（如阻塞网络 IO）不阻塞
    // Dart 侧切歌，只留后台线程回收。
    if (!_startedCompleter.isCompleted) {
      _startedCompleter.complete();
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }

    if (handle != 0) {
      final h = handle;
      await Isolate.run<void>(() {
        // destroy join 引擎线程（最长数百 ms），后台 isolate 避免阻塞 UI；
        // 内部唤醒阻塞中的 wait_event → 接收 isolate 收到 -1 自行退出。
        EngineBindings.instance.destroy(Pointer<Opaque>.fromAddress(h));
      });
      // 事件泵自退（已收 -1）：有界等其完全退场，避免停用后还有事件串在途
      await _awaitPumpExit();
    }
    _teardownEventPump();
    try {
      sockDir.deleteSync(recursive: true);
    } catch (_) {}
    await _eventsCtrl.close();
  }
}

/// 事件泵接收 isolate 入口（Isolate.spawn 目标，须为顶层函数）。
///
/// 用 `Pointer.fromAddress` 重建句柄并阻塞在 `wait_event(handle,...,-1)`：
///   - 首条向主 isolate 发握手哨兵（[AudioEngineProcess._enginePumpHandshake]）
///     确认就绪，随后每次 `wait_event` 返回 >0 即把事件串经 [SendPort] 发回；
///   - 0（超时）/ -1（已销毁）→ 退出入口 → isolate 自行终止；
///   - 引擎事件由 C 线程入队时经条件变量唤醒，空闲零唤醒。
void _engineEventPumpEntry(List<Object?> args) {
  final handleAddr = args[0] as int;
  final SendPort toMain = args[1] as SendPort;
  // 本 isolate 独立加载动态库并绑定符号（isolate 间不共享静态态）。
  final bindings = EngineBindings.instance;
  final ptr = Pointer<Opaque>.fromAddress(handleAddr);
  toMain.send(AudioEngineProcess._enginePumpHandshake);
  final buf = calloc<Uint8>(AudioEngineProcess._eventBufCap);
  try {
    while (true) {
      final r = bindings.waitEventInto(ptr, buf, AudioEngineProcess._eventBufCap, -1);
      if (r == 0 || r == -1) break;
      toMain.send(buf.cast<Utf8>().toDartString(length: r));
    }
  } finally {
    calloc.free(buf);
  }
}

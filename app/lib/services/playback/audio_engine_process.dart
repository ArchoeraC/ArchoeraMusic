import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'engine_bindings.dart';
import 'pcm_analyzer.dart';

/// 引擎控制事件（经事件 FIFO 轮询接收的 JSON 行）。
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

/// 转码完成（引擎发 done；播放模式下 WAV 已落盘完整）。
class EngineDone extends EngineEvent {
  const EngineDone();
}

/// 播放器就绪（miniaudio 已加载 WAV，开始播放；duration_ms 为完整时长）。
class EnginePlaying extends EngineEvent {
  const EnginePlaying({required this.durationMs});

  final int durationMs;
}

/// 播放位置事件（播放模式，每 50ms 音频 1 帧；驱动 FFT 事件取帧）。
class EnginePosition extends EngineEvent {
  const EnginePosition({required this.positionMs});

  final int positionMs;
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
/// 生命周期：start（FFI create + 引擎线程转码）→ 等待 [done]（转码完成，
/// WAV/PCM 文件就绪）→ 引擎自播（`--player-file` 播放模式，miniaudio 输出，
/// §10.8 替代 libmpv）→ stop（destroy，清理会话目录）。
///
/// 通信模型（2026-08-07 用户决策，摆脱 AF_UNIX/TCP 兼容问题）：
///   - 引擎在库内自有线程全速转码 + 播放，FFI 调用均为短调用；
///   - 事件经线程安全 FIFO，Dart 侧 50ms 定时 [pollEvent] 轮询；
///   - 控制命令（play/pause/seek/...）经 [sendCommand] 入命令 FIFO；
///   - PCM 由引擎直写 `stream.pcm`，[PcmAnalyzer] 按需读文件做 FFT。
class AudioEngineProcess {
  AudioEngineProcess._({
    required this.handle,
    required this.sockDir,
    required this.outSampleRate,
  }) {
    _eventsCtrl = StreamController<EngineEvent>.broadcast();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _drainEvents());
    // 转码在引擎线程进行，无需消费 stdout（无进程管道）
  }

  /// 事件轮询间隔（引擎事件低频：position 每 100ms 音频 1 帧）。
  static const _pollInterval = Duration(milliseconds: 50);

  /// C 侧引擎句柄（ArchoeraMediaEngine* 地址）。
  final int handle;

  final Directory sockDir;

  /// 管线实际输出采样率（ready 事件回填前为 0/48000 兜底）。
  final int outSampleRate;

  late final StreamController<EngineEvent> _eventsCtrl;
  PcmAnalyzer? _pcm;
  Timer? _pollTimer;
  bool _stopped = false;

  final Completer<void> _doneCompleter = Completer<void>();

  /// 引擎控制事件流（ready/status/done/playing/position/player:ended/error/exited）。
  Stream<EngineEvent> get events => _eventsCtrl.stream;

  /// PCM 分析器（引擎直写文件 + 增量索引 + 按需 FFT，UI 拉模式取帧）。
  PcmAnalyzer? get pcm => _pcm;

  /// 播放器 WAV 文件（引擎转码 PCM 落盘，miniaudio 播放）。
  String get wavFilePath => '${sockDir.path}/stream.wav';

  /// 原始 PCM 文件（块格式，引擎直写，供 [PcmAnalyzer.frameAt] 按需读取）。
  String get pcmFilePath => '${sockDir.path}/stream.pcm';

  /// 转码完成（收到引擎 done）。成功即 WAV/PCM 文件完整。
  Future<void> get done => _doneCompleter.future;

  /// 会话标识（UI 显示用：socket 目录名）。
  String get sessionId => sockDir.uri.pathSegments.last;

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
    if (Platform.isWindows) {
      // 引擎动态库当前为 POSIX 构建；Windows 打包阶段需构建 archoera_mediaengine.dll
      throw UnsupportedError('Windows 桌面端暂未启用（需构建 Windows 动态库）');
    }
    final sockDir = Directory(
      '/tmp/archoera-${Platform.localHostname}-$pid-${DateTime.now().millisecondsSinceEpoch}',
    )..createSync(recursive: true);
    final playerFile = '${sockDir.path}/stream.wav';

    // FFI create 在后台 isolate 执行：pipeline_create 打开解码器/网络 IO 可能
    // 耗时数百 ms，避免阻塞 UI isolate。config 参数以标量值跨 isolate 传递。
    final handleAddr = await Isolate.run<int>(() {
      final cfg = engineConfigFromParams(
        bitrate: bitrate,
        passthrough: passthrough,
        offsetMs: offsetMs,
        eqGains: eqGains,
        preamp: preamp,
        normalization: normalization,
        tempoSpeed: tempoSpeed,
        tempoPitch: tempoPitch,
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
    );
    return engine;
  }

  /// 轮询事件队列并分发（50ms 定时；引擎线程写入 FIFO）。
  void _drainEvents() {
    final bindings = EngineBindings.instance;
    final ptr = Pointer<Opaque>.fromAddress(handle);
    while (true) {
      final line = bindings.pollEvent(ptr);
      if (line == null) break;
      _onControlLine(line);
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
        case 'player:ended':
          _emit(const EnginePlayerEnded());
        case 'done':
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.complete();
          }
          _emit(const EngineDone());
        case 'error':
          final msg = map['message'] as String? ?? 'unknown';
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.completeError(StateError('引擎错误: $msg'));
          }
          _emit(EngineError(msg));
        case 'exited':
          // 引擎线程退出：若转码尚未完成（未收到 done）就退出——如启动
          // 失败 / 解码异常——补完成 done，否则 _startSession 的
          // `await engine.done` 永远挂起 → buffering 卡死、表现为
          // 「启动后无法播放」。正常路径 done 已完成，此处不重复。
          final code = (map['code'] as num?)?.toInt() ?? 0;
          if (!_doneCompleter.isCompleted) {
            _doneCompleter.completeError(StateError('引擎异常退出（code=$code）'));
          }
          _emit(EngineExited(code));
      }
    } catch (_) {
      // 非协议行忽略
    }
  }

  /// 打开 PCM 文件读取器（ready 后调用；引擎直写，scan 增量补索引）。
  Future<void> _openPcm(int sampleRate) async {
    if (_pcm != null) return;
    final rate = sampleRate > 0 ? sampleRate : 48000;
    try {
      _pcm = await PcmAnalyzer.open(pcmFilePath, sampleRate: rate);
    } catch (e) {
      // PCM 文件不可读：频谱不可用，不影响播放。记录根因便于排查
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

  /// 停止：destroy（join 引擎线程）→ 清理会话目录与本地通道。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _pcm?.dispose();
    _pcm = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    // 放行 pending done：stop 由新 load 抢占触发（缓冲中切歌）时，旧会话
    // `_startSession` 的 `await engine.done` 立即返回，不再挂等转码完成阻塞
    // 加载链；正常 done 已完成的场景此处不重复。
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }

    if (handle != 0) {
      final h = handle;
      await Isolate.run<void>(() {
        // destroy join 引擎线程（最长数百 ms），后台 isolate 避免阻塞 UI
        EngineBindings.instance.destroy(Pointer<Opaque>.fromAddress(h));
      });
    }
    try {
      sockDir.deleteSync(recursive: true);
    } catch (_) {}
    await _eventsCtrl.close();
  }
}

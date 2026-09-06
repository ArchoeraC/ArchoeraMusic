// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 刮削控制器：封装 C 侧 [ScraperController]（FFI）为 Riverpod Notifier，
/// 供媒体库页（简化按钮）与设置页（详细参数）共用同一刮削会话。
///
/// C 侧引擎在库内独立 pthread 执行，状态经事件队列上报（progress / done /
/// empty / error）。事件获取默认走**接收 isolate 事件泵**（对齐音频引擎
/// audio_engine_process.dart）：接收 isolate 阻塞 `scraper_wait_event(handle,
/// buf, cap, -1)`，事件 JSON 经 SendPort 回主 isolate 分发（顺序不丢、空闲
/// 零唤醒），去掉原先 Dart 120ms `Timer.periodic` 轮询；
/// `ARCHOERA_SCRAPER_POLL_FALLBACK=1` 可切回旧的 120ms pollEvent 轮询
/// （事件泵 spawn/握手失败时也自动回退，便于调试）。
///
/// 生命周期：`start()` → 事件泵自动消费 → done/error/empty（终态事件）后
/// worker 退出，主 isolate 复查 isDone 自动收尾（destroy 唤醒泵自退）。
/// 同一时刻只允许一个刮削会话（正在运行时 start 直接忽略）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'scraper_bindings.dart';
import 'scraper_client.dart';

/// 事件缓冲容量（对齐 C 侧事件行；终态 done 可能携带失败明细，留足余量，
/// 防超长 JSON 被截断成非法 JSON 导致终态丢失 → 会话悬挂）。
const int _scraperEventBufCap = 65536;

/// 仅目录整理默认模板（对齐 SPlayer-Next organizer；只决定目录层级，不改文件名）。
const String kOrganizeDefaultPattern = '{artist}/{album}/{track}. {title}.{ext}';

/// 接收 isolate 就绪握手哨兵（主 isolate 收到的首条消息；其后均为事件串）。
const int _scraperPumpHandshake = 0x53_43_50_21; // 'SCP!'

/// 刮削进度快照（映射 C 侧事件 JSON 字段）。
class ScrapeState {
  const ScrapeState({
    this.scraping = false,
    this.organize = false,
    this.total = 0,
    this.scraped = 0,
    this.success = 0,
    this.failed = 0,
    this.skipped = 0,
    this.notFound = 0,
    this.current = '',
    this.canceled = false,
    this.error,
  });

  /// 是否运行中
  final bool scraping;

  /// 当前会话是否为「仅目录整理」（true 时 success=移动数、skipped=跳过数）。
  final bool organize;

  final int total;
  final int scraped;
  final int success;
  final int failed;
  final int skipped;
  final int notFound;

  /// 当前处理的文件（progress 事件带）。
  final String current;

  /// 被用户取消（done 事件 canceled=true）。
  final bool canceled;

  /// error 事件消息。
  final String? error;

  /// 已完成进度 0~1（total 未知时 null）。
  double? get percent => total > 0 ? (scraped / total).clamp(0.0, 1.0) : null;

  bool get hasActivity => total > 0 || scraped > 0;

  ScrapeState copyWith({
    bool? scraping,
    bool? organize,
    int? total,
    int? scraped,
    int? success,
    int? failed,
    int? skipped,
    int? notFound,
    String? current,
    bool? canceled,
    String? error,
  }) =>
      ScrapeState(
        scraping: scraping ?? this.scraping,
        organize: organize ?? this.organize,
        total: total ?? this.total,
        scraped: scraped ?? this.scraped,
        success: success ?? this.success,
        failed: failed ?? this.failed,
        skipped: skipped ?? this.skipped,
        notFound: notFound ?? this.notFound,
        current: current ?? this.current,
        canceled: canceled ?? this.canceled,
        error: error ?? this.error,
      );

  static const initial = ScrapeState();
}

/// 数据源开关（默认全开，对齐 SPlayer-Next 刮削器默认）。
class ScrapeSources {
  const ScrapeSources({
    this.musicBrainz = true,
    this.deezer = true,
    this.itunes = true,
    this.netease = true,
    this.qqMusic = true,
    this.kugou = true,
    this.kuwo = true,
    this.migu = true,
    this.acoustId = true,
  });

  final bool musicBrainz;
  final bool deezer;
  final bool itunes;
  final bool netease;
  final bool qqMusic;
  final bool kugou;
  final bool kuwo;
  final bool migu;
  final bool acoustId;
}

class ScrapeController extends Notifier<ScrapeState> {
  /// 当前会话的 C 句柄封装（push/回退共用；终态后置空）。
  ScraperController? _scraper;

  /// 当前会话句柄地址（push 模式传给接收 isolate）。
  int? _handleAddr;

  /// 回退模式：120ms 轮询定时器（仅 `ARCHOERA_SCRAPER_POLL_FALLBACK=1` 或
  /// 事件泵不可用时存在）。
  Timer? _timer;

  /// push 模式：终态事件后的「一次性 isDone 复查」——done 事件由 worker 在
  /// 收尾前一刻入队，主 isolate 收时 isDone 可能尚未置位，延迟一拍再确认；
  /// 非终态触发（如 daemon 周期内）isDone=false 直接返回，无残留定时器。
  Timer? _finishTimer;

  /// push 模式事件泵状态：
  ///   - [_eventPort]：主 isolate 收事件串的端口（首条为就绪握手）；
  ///   - [_pumpIsolate]：接收 isolate（阻塞在 `wait_event(-1)`）；
  ///   - [_pumpReady]：握手完成信号（首条消息到达即就绪，失败超时回退轮询）；
  ///   - [_pumpExitPort]：接收 isolate 意外退出通知（回退兜底）。
  ReceivePort? _eventPort;
  Isolate? _pumpIsolate;
  Completer<void>? _pumpReady;
  ReceivePort? _pumpExitPort;

  /// 当前是否有活动会话（start 置 false，finish 置 true）。事件泵意外退出时
  /// 仅在活动会话内回退轮询；主动收尾的 destroy 唤醒泵自退不触发回退。
  bool _stopped = true;

  /// 本轮是否被用户取消（终态事件丢失时的兜底标记；正常 done 事件自带 canceled）。
  bool _cancelRequested = false;

  /// 事件轮询间隔（仅回退模式使用）。
  static const _pollInterval = Duration(milliseconds: 120);

  /// 终态事件后复查 isDone 的延迟。
  static const _finishDelay = Duration(milliseconds: 120);

  /// 事件泵回退开关：设 `ARCHOERA_SCRAPER_POLL_FALLBACK=1` 切回旧的 120ms
  /// pollEvent 轮询（默认关，走接收 isolate 阻塞等待 push）。
  static bool get _usePollFallback =>
      Platform.environment['ARCHOERA_SCRAPER_POLL_FALLBACK'] == '1';

  @override
  ScrapeState build() {
    // provider 销毁时收尾（定时器 + 事件泵 + FFI 实例），避免泄漏
    ref.onDispose(_finish);
    return ScrapeState.initial;
  }

  /// 开始一次刮削。[dirs] 为刮削目录；[dbPath] 为 scraper-state.db 路径；
  /// [sources] 数据源开关；写入/高级参数对齐偏好（embed*/skipScraped/
  /// workers/batch/retries）。正在运行时忽略。
  void start({
    required List<String> dirs,
    required String dbPath,
    ScrapeSources sources = const ScrapeSources(),
    bool embedMetadata = true,
    bool embedCover = true,
    bool embedLyrics = true,
    bool skipScraped = true,
    int workers = 0,
    int batchSize = 10,
    int maxRetries = 5,
  }) {
    if (state.scraping) return;
    final cleanDirs = dirs.map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
    if (cleanDirs.isEmpty) {
      state = state.copyWith(error: 'scrape empty dirs');
      return;
    }
    // 收尾残留会话（上次会话未正常走终态收尾时）
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
    _launch(config, organize: false);
  }

  /// 开始一次「仅目录整理」（不联网）：按 [pattern] 把 [dirs] 内文件移动到
  /// [targetDir] 目录树，保留原文件名。事件与刮削同 schema（success=移动数）。
  void startOrganize({
    required List<String> dirs,
    required String dbPath,
    required String targetDir,
    String pattern = kOrganizeDefaultPattern,
  }) {
    if (state.scraping) return;
    final cleanDirs =
        dirs.map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
    final target = targetDir.trim();
    if (cleanDirs.isEmpty || target.isEmpty) {
      state = state.copyWith(error: 'organize dirs/target empty');
      return;
    }
    if (!_stopped || _scraper != null) _finish();
    _launch(
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

  /// 通用启动：创建 FFI 句柄 + 事件通道（刮削与仅目录整理共用）。
  void _launch(ScraperConfig config, {bool organize = false}) {
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
    if (_usePollFallback) {
      _timer = Timer.periodic(_pollInterval, (_) => _poll());
    } else {
      // 事件驱动：接收 isolate 阻塞 wait_event(-1)，事件经 SendPort 分发。
      _pumpReady = Completer<void>();
      _startEventPump();
      // 事件泵就绪（接收 isolate 已进入阻塞等待）：握手失败/超时自动回退
      // 120ms 轮询。引擎事件在 C FIFO 中排队，晚几 ms 不丢失。
      unawaited(_ensurePumpDelivery());
    }
  }

  /// 取消：引擎在下一个文件边界安全退出。
  void cancel() {
    if (!state.scraping) return;
    _cancelRequested = true;
    _scraper?.cancel();
  }

  /// 回退模式：清空事件队列并分发；C 侧线程已结束则收尾。
  void _poll() {
    final s = _scraper;
    if (s == null || _stopped) return;
    while (true) {
      final ev = s.pollEvent();
      if (ev == null) break;
      _handleEvent(ev);
    }
    if (s.isDone) {
      _finish();
    }
  }

  void _handleEvent(String json) {
    Map<String, dynamic> evt;
    try {
      evt = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (evt['type']) {
      case 'progress':
        state = state.copyWith(
          scraping: true,
          total: _num(evt, 'total', state.total),
          scraped: _num(evt, 'scraped', state.scraped),
          success: _num(evt, 'success', state.success),
          failed: _num(evt, 'failed', state.failed),
          skipped: _num(evt, 'skipped', state.skipped),
          notFound: _num(evt, 'notFound', state.notFound),
          current: evt['current']?.toString() ?? '',
        );
        break;
      case 'done':
        state = state.copyWith(
          scraping: false,
          total: _num(evt, 'total', state.total),
          scraped: _num(evt, 'scraped', state.scraped),
          success: _num(evt, 'success', state.success),
          failed: _num(evt, 'failed', state.failed),
          skipped: _num(evt, 'skipped', state.skipped),
          notFound: _num(evt, 'notFound', state.notFound),
          canceled: evt['canceled'] == true,
          current: '',
        );
        break;
      case 'empty':
        state = state.copyWith(
          scraping: false,
          current: evt['message']?.toString() ?? '',
        );
        break;
      case 'error':
        state = state.copyWith(
          scraping: false,
          error: evt['message']?.toString() ?? '未知错误',
        );
        break;
    }
  }

  static int _num(Map<String, dynamic> evt, String key, int fallback) {
    final v = evt[key];
    return v is num ? v.toInt() : fallback;
  }

  // ---------------------------------------------------------------------------
  // 事件泵（push 模式）
  // ---------------------------------------------------------------------------

  /// 事件泵就绪确认：等接收 isolate 握手。失败/超时 → 回退轮询，保证事件
  /// 通道始终可用。
  Future<void> _ensurePumpDelivery() async {
    final ready = _pumpReady;
    if (ready == null) return; // 回退模式，无事件泵
    try {
      await ready.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      if (!_stopped) _switchToPollFallback();
    }
  }

  /// 启动接收 isolate 事件泵：隔离线程阻塞 `wait_event(handle, buf, cap, -1)`，
  /// 事件串经 SendPort 送回主 isolate 走 [_handleEvent] 分发。
  void _startEventPump() {
    final h = _handleAddr;
    if (h == null || h == 0) return;
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
    unawaited(_spawnEventPump(h, port, exitPort));
  }

  Future<void> _spawnEventPump(int h, ReceivePort port, ReceivePort exitPort) async {
    try {
      final iso = await Isolate.spawn(
        _scraperPumpEntry,
        <Object?>[h, port.sendPort],
        debugName: 'scraper-event-pump-0x${h.toRadixString(16)}',
        onExit: exitPort.sendPort,
        onError: exitPort.sendPort,
      );
      _pumpIsolate = iso;
      exitPort.listen((_) {
        // 事件泵退出：
        //   - 主动收尾路径：_finish 已置 _stopped → 忽略（泵已收 -1 自退）；
        //   - 意外崩溃/启动失败 → 补 failed ready + 回退轮询兜底。
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

  /// 事件泵首条消息（握手）后均为事件串 → 分发；终态后复查收尾。
  void _onPumpMessage(Object? msg) {
    final ready = _pumpReady;
    if (ready != null && !ready.isCompleted) {
      ready.complete(); // 握手：接收 isolate 已就绪、即将阻塞 wait_event
      if (msg is int) return; // 哨兵本身不是事件
    }
    if (msg is String && !_stopped) {
      _handleEvent(msg);
      _kickFinishCheck();
    }
  }

  /// push 模式：每次事件后重启「一次性 isDone 复查」。终态事件（done）后
  /// worker 才把 running=false/done=true，此处延迟一拍确认后收尾；未完成
  /// （如仍在运行/daemon 周期内）isDone=false 直接返回，不重新调度、无残留。
  void _kickFinishCheck() {
    if (_stopped || _usePollFallback) return;
    _finishTimer?.cancel();
    _finishTimer = Timer(_finishDelay, () {
      _finishTimer = null;
      if (_stopped) return;
      final s = _scraper;
      if (s != null && s.isDone) _finish();
    });
  }

  /// 事件泵不可用 → 关停推模式，切回旧 120ms 轮询（调试/兜底）。
  void _switchToPollFallback() {
    if (_stopped || _timer != null) return;
    _teardownEventPump();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  /// 关停事件泵（收尾/回退时）：关闭端口、释放 isolate 引用。
  void _teardownEventPump() {
    final ready = _pumpReady;
    _pumpReady = null;
    // 放行仍 await 就绪的调用方（start 收尾不悬空）
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
    _eventPort?.close();
    _eventPort = null;
    final iso = _pumpIsolate;
    _pumpIsolate = null;
    _pumpExitPort?.close();
    _pumpExitPort = null;
    // 泵已收 -1/即将自退；兜底 kill（非 native 阻塞中则立即生效）
    iso?.kill(priority: Isolate.immediate);
  }

  /// 收尾：取消定时器 → destroy FFI 句柄（置销毁标志 + 唤醒阻塞中的
  /// wait_event → 接收 isolate 收 -1 自退；join worker；drain waiters 后才
  /// 释放内存）→ 关停事件泵。保留最终 state 供 UI 展示统计。
  void _finish() {
    if (_stopped &&
        _scraper == null &&
        _timer == null &&
        _finishTimer == null &&
        _eventPort == null &&
        _pumpIsolate == null) {
      return; // 已收尾
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
      // 兜底：终态事件（done/empty/error）可能因队列满丢帧 / 超长 JSON 截断 /
      // 事件泵异常而丢失——dispose 前再排空一次残留事件；若仍拿不到终态
      // （引擎异常退出、未发终态即 done=true），强制把 UI 从「运行中」复位，
      // 避免界面永久卡在刮削/整理中。
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

/// 事件泵接收 isolate 入口（Isolate.spawn 目标，须为顶层函数）。
///
/// 用 `Pointer.fromAddress` 重建句柄并阻塞在 `wait_event(handle, buf, cap, -1)`：
///   - 首条向主 isolate 发握手哨兵（[_scraperPumpHandshake]）确认就绪，随后
///     每次 `wait_event` 返回 >0 即把事件串经 [SendPort] 发回；
///   - 0（超时）/ -1（已销毁）→ 退出入口 → isolate 自行终止；
///   - scraper 事件由 C worker 入队时经条件变量唤醒，空闲零唤醒。
void _scraperPumpEntry(List<Object?> args) {
  final handleAddr = args[0] as int;
  final SendPort toMain = args[1] as SendPort;
  // 本 isolate 独立加载动态库并绑定符号（isolate 间不共享静态态）。
  final bindings = ScraperBindings.instance;
  final ptr = Pointer<Void>.fromAddress(handleAddr);
  toMain.send(_scraperPumpHandshake);
  final buf = calloc<Uint8>(_scraperEventBufCap);
  try {
    while (true) {
      final r = bindings.waitEventInto(ptr, buf, _scraperEventBufCap, -1);
      if (r == 0 || r == -1) break;
      toMain.send(buf.cast<Utf8>().toDartString(length: r));
    }
  } finally {
    calloc.free(buf);
  }
}

/// 全局刮削控制器（媒体库页与设置页共用）。
final scrapeControllerProvider =
    NotifierProvider<ScrapeController, ScrapeState>(ScrapeController.new);

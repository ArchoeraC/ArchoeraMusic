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

part 'scrape_controller/scrape_controller_core.dart';
part 'scrape_controller/scrape_controller_events.dart';
part 'scrape_controller/scrape_controller_pump.dart';

/// 事件缓冲容量（对齐 C 侧事件行；终态 done 可能携带失败明细，留足余量，
/// 防超长 JSON 被截断成非法 JSON 导致终态丢失 → 会话悬挂）。
const int _scraperEventBufCap = 65536;

/// 仅目录整理默认模板（只决定目录层级，不改文件名）。
const String kOrganizeDefaultPattern =
    '{artist}/{album}/{track}. {title}.{ext}';

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
  }) => ScrapeState(
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

/// 数据源开关（默认全开）。
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

class ScrapeController extends Notifier<ScrapeState>
    with _ScrapeControllerCore, _ScrapeControllerEvents, _ScrapeControllerPump {
  /// 当前会话的 C 句柄封装（push/回退共用；终态后置空）。
  @override
  ScraperController? _scraper;

  /// 当前会话句柄地址（push 模式传给接收 isolate）。
  @override
  int? _handleAddr;

  /// 回退模式：120ms 轮询定时器（仅 `ARCHOERA_SCRAPER_POLL_FALLBACK=1` 或
  /// 事件泵不可用时存在）。
  @override
  Timer? _timer;

  /// push 模式：终态事件后的「一次性 isDone 复查」——done 事件由 worker 在
  /// 收尾前一刻入队，主 isolate 收时 isDone 可能尚未置位，延迟一拍再确认；
  /// 非终态触发（如 daemon 周期内）isDone=false 直接返回，无残留定时器。
  @override
  Timer? _finishTimer;

  /// push 模式事件泵状态：
  ///   - [_eventPort]：主 isolate 收事件串的端口（首条为就绪握手）；
  ///   - [_pumpIsolate]：接收 isolate（阻塞在 `wait_event(-1)`）；
  ///   - [_pumpReady]：握手完成信号（首条消息到达即就绪，失败超时回退轮询）；
  ///   - [_pumpExitPort]：接收 isolate 意外退出通知（回退兜底）。
  @override
  ReceivePort? _eventPort;
  @override
  Isolate? _pumpIsolate;
  @override
  Completer<void>? _pumpReady;
  @override
  ReceivePort? _pumpExitPort;

  /// 当前是否有活动会话（start 置 false，finish 置 true）。事件泵意外退出时
  /// 仅在活动会话内回退轮询；主动收尾的 destroy 唤醒泵自退不触发回退。
  @override
  bool _stopped = true;

  /// 本轮是否被用户取消（终态事件丢失时的兜底标记；正常 done 事件自带 canceled）。
  @override
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
  ScrapeState build() => _buildState();

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
  }) => _start(
    dirs: dirs,
    dbPath: dbPath,
    sources: sources,
    embedMetadata: embedMetadata,
    embedCover: embedCover,
    embedLyrics: embedLyrics,
    skipScraped: skipScraped,
    workers: workers,
    batchSize: batchSize,
    maxRetries: maxRetries,
  );

  /// 开始一次「仅目录整理」（不联网）：按 [pattern] 把 [dirs] 内文件移动到
  /// [targetDir] 目录树，保留原文件名。事件与刮削同 schema（success=移动数）。
  void startOrganize({
    required List<String> dirs,
    required String dbPath,
    required String targetDir,
    String pattern = kOrganizeDefaultPattern,
  }) => _startOrganize(
    dirs: dirs,
    dbPath: dbPath,
    targetDir: targetDir,
    pattern: pattern,
  );

  /// 取消：引擎在下一个文件边界安全退出。
  void cancel() => _cancel();

  /// 关闭组织整理的结果视图，回到可编辑空闲态（未运行时可调）。
  void dismissResult() => _dismissResult();

  // ---------------------------------------------------------------------------
  // 事件泵（push 模式）
  // ---------------------------------------------------------------------------

  /// 事件泵就绪确认：等接收 isolate 握手。失败/超时 → 回退轮询，保证事件
  /// 通道始终可用。
}

/// 全局刮削控制器（媒体库页与设置页共用）。
final scrapeControllerProvider =
    NotifierProvider<ScrapeController, ScrapeState>(ScrapeController.new);

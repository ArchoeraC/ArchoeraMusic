/// 刮削器 Dart 封装：ScraperController。
///
/// 非端口化直连 libarchoera_scraper（FFI）：
///   - 引擎在库内独立 pthread 执行，不 spawn 进程、不占本地端口
///   - 状态/进度经 pollEvent 轮询（progress / done / empty / error）
///   - 队列模式：enqueue 注入曲目（内存表），无 HTTP
///
/// 典型用法：
///   final c = ScraperController(dirs: ['/music'], scraperDbPath: dbPath);
///   c.run();
///   while (!c.isDone) { final ev = c.pollEvent(); if (ev != null) ...; }
///   c.dispose();
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'scraper_bindings.dart';

/// 刮削配置（映射 C 侧 ScraperConfig + 宿主选项）。
class ScraperConfig {
  ScraperConfig({
    required this.scraperDbPath,
    this.dirs = const [],
    this.coverCacheDir = '',
    this.batchSize = 10,
    this.maxRetries = 5,
    this.embedMetadata = true,
    this.embedCover = true,
    this.embedLyrics = true,
    this.skipScraped = true,
    this.useMusicBrainz = true,
    this.useDeezer = true,
    this.useItunes = true,
    this.useNetease = true,
    this.useQQMusic = true,
    this.useKugou = true,
    this.useKuwo = true,
    this.useMigu = true,
    this.useAcoustID = true,
    this.concurrentWorkers,
    this.mode = 'once',
    this.interval = 60,
  });

  /// scraper-state.db 路径（必需）
  final String scraperDbPath;

  /// 刮削目录（空 → DB 队列模式）
  final List<String> dirs;

  /// 封面缓存目录（可选）
  final String coverCacheDir;

  final int batchSize;
  final int maxRetries;
  final bool embedMetadata;
  final bool embedCover;
  final bool embedLyrics;
  final bool skipScraped;
  final bool useMusicBrainz;
  final bool useDeezer;
  final bool useItunes;
  final bool useNetease;
  final bool useQQMusic;
  final bool useKugou;
  final bool useKuwo;
  final bool useMigu;
  final bool useAcoustID;

  /// 并发查询线程数（null → C 侧按硬件自动）
  final int? concurrentWorkers;

  /// 'once' | 'daemon'
  final String mode;
  final int interval;

  Map<String, Object> toJson() => {
        'scraperDbPath': scraperDbPath,
        'dirs': dirs,
        'coverCacheDir': coverCacheDir,
        'batchSize': batchSize,
        'maxRetries': maxRetries,
        'embedMetadata': embedMetadata,
        'embedCover': embedCover,
        'embedLyrics': embedLyrics,
        'skipScraped': skipScraped,
        'useMusicBrainz': useMusicBrainz,
        'useDeezer': useDeezer,
        'useItunes': useItunes,
        'useNetease': useNetease,
        'useQQMusic': useQQMusic,
        'useKugou': useKugou,
        'useKuwo': useKuwo,
        'useMigu': useMigu,
        'useAcoustID': useAcoustID,
        'concurrentWorkers': ?concurrentWorkers,
        'mode': mode,
        'interval': interval,
      };
}

/// 一次刮削任务的控制器（单实例语义，勿并发多实例）。
class ScraperController {
  ScraperController._(this._h, this._bindings);

  final Pointer<Void> _h;
  final ScraperBindings _bindings;
  bool _disposed = false;

  /// 创建刮削器（仅解析 config，立即返回；错误抛 StateError）。
  factory ScraperController(ScraperConfig config) {
    final bindings = ScraperBindings.instance;
    final jsonStr = jsonEncode(config.toJson());
    final configPtr = jsonStr.toNativeUtf8();
    try {
      final h = bindings.create(configPtr);
      if (h.address == 0) {
        throw StateError('archoera_scraper_create 失败（详见 stderr）');
      }
      return ScraperController._(h, bindings);
    } finally {
      calloc.free(configPtr);
    }
  }

  /// 注入一条曲目（队列模式）。trackJson 与 /api/db/tracks/:id 响应同构。
  bool enqueue(Map<String, Object> track) {
    _checkNotDisposed();
    final jsonStr = jsonEncode(track);
    final trackPtr = jsonStr.toNativeUtf8();
    try {
      return _bindings.enqueue(_h, trackPtr) != 0;
    } finally {
      calloc.free(trackPtr);
    }
  }

  /// 启动刮削（后台线程，立即返回）。返回是否成功启动。
  bool run() {
    _checkNotDisposed();
    return _bindings.run(_h) != 0;
  }

  bool get isDone {
    _checkNotDisposed();
    return _bindings.isDone(_h) != 0;
  }

  bool get isRunning {
    _checkNotDisposed();
    return _bindings.isRunning(_h) != 0;
  }

  /// 取消：引擎在下一个文件边界安全退出。
  void cancel() {
    _checkNotDisposed();
    _bindings.cancel(_h);
  }

  /// 取一条事件 JSON（progress/done/empty/error）；无则返回 null。
  String? pollEvent() {
    _checkNotDisposed();
    final p = _bindings.pollEvent(_h);
    if (p.address == 0) return null;
    return p.toDartString();
  }

  /// 销毁：取消 + 等待工作线程结束 + 释放资源。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.destroy(_h);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('ScraperController 已销毁');
  }
}

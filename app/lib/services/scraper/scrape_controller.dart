/// 刮削控制器：封装 C 侧 [ScraperController]（FFI）为 Riverpod Notifier，
/// 供媒体库页（简化按钮）与设置页（详细参数）共用同一刮削会话。
///
/// C 侧引擎在库内独立 pthread 执行，状态经事件队列上报（progress / done /
/// empty / error），此处用 [Timer.periodic] 轮询 [ScraperController.pollEvent]
/// —— scraper 的事件队列允许 poll（与下载引擎戒律 13.1 的 push-only 不同）。
///
/// 生命周期：`start()` → 自动轮询 → done/error/empty 后自动收尾（destroy）。
/// 同一时刻只允许一个刮削会话（正在运行时 start 直接忽略）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'scraper_client.dart';

/// 刮削进度快照（映射 C 侧事件 JSON 字段）。
class ScrapeState {
  const ScrapeState({
    this.scraping = false,
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
  ScraperController? _scraper;
  Timer? _timer;

  @override
  ScrapeState build() {
    // provider 销毁时收尾（定时器 + FFI 实例），避免泄漏
    ref.onDispose(_cleanup);
    return ScrapeState.initial;
  }

  /// 开始一次刮削。[dirs] 为刮削目录；[dbPath] 为 scraper-state.db 路径；
  /// [sources] 数据源开关。正在运行时忽略。
  void start({
    required List<String> dirs,
    required String dbPath,
    ScrapeSources sources = const ScrapeSources(),
  }) {
    if (state.scraping) return;
    final cleanDirs = dirs.map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
    if (cleanDirs.isEmpty) {
      state = state.copyWith(error: 'scrape empty dirs');
      return;
    }
    // 销毁残留实例（上次会话未正常收尾时）
    _scraper?.dispose();
    _scraper = null;

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
    );

    final ScraperController scraper;
    try {
      scraper = ScraperController(config);
    } catch (e) {
      state = state.copyWith(error: '$e');
      return;
    }
    _scraper = scraper;

    state = const ScrapeState(scraping: true);
    if (!scraper.run()) {
      state = state.copyWith(scraping: false, error: 'archoera_scraper_run 失败');
      _cleanup();
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _poll());
  }

  /// 取消：引擎在下一个文件边界安全退出。
  void cancel() {
    if (!state.scraping) return;
    _scraper?.cancel();
  }

  void _poll() {
    final s = _scraper;
    if (s == null) return;
    // 清空事件队列（scraper 事件为 JSON line，逐条应用）
    while (true) {
      final ev = s.pollEvent();
      if (ev == null) break;
      _handleEvent(ev);
    }
    // C 侧线程已结束 → 收尾（保留最终 state 供 UI 展示统计）
    if (s.isDone) {
      _cleanup();
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

  void _cleanup() {
    _timer?.cancel();
    _timer = null;
    _scraper?.dispose();
    _scraper = null;
  }
}

/// 全局刮削控制器（媒体库页与设置页共用）。
final scrapeControllerProvider =
    NotifierProvider<ScrapeController, ScrapeState>(ScrapeController.new);

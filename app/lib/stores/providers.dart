// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

import '../services/history/history_store.dart';
import '../services/kugou/kugou_api.dart';
import '../services/liked/liked_cache.dart';
import '../services/liked/liked_loader.dart';
import '../services/neko/neko_api.dart';
import '../services/neko/neko_lyric_rewriter.dart';
import '../services/netease/apis_netease_caller.dart';
import '../services/netease/netease_api.dart';
import '../services/platform/platform_capabilities.dart';
import '../services/qqmusic/qq_liked_store.dart';
import '../services/qqmusic/qqmusic_api.dart';
import '../services/weather/weather_notifier.dart';
import 'app_prefs.dart';
import 'event_bus.dart';
import 'like_controller.dart';

// ── 直连NT API ──────────────────────────────────────────────

/// 直连NT（纯 Dart：apis 包全量移植，weapi/eapi/xeapi 加密，不经侧车 RPC）。
final neteaseApiProvider = Provider<NeteaseApi>((ref) {
  return NeteaseApi(ApisNeteaseCaller());
});

/// NT登录态（login_status 账号）。null = 未登录。
///
/// [NeteaseAuthNotifier.init] 在应用启动时调用：先匿名注册（让推荐类接口
/// 可用），再读取持久化会话中的账号；[logout] 清空会话。
final neteaseAuthProvider =
    NotifierProvider<NeteaseAuthNotifier, NeteaseAccount?>(
      NeteaseAuthNotifier.new,
    );

class NeteaseAuthNotifier extends Notifier<NeteaseAccount?> {
  @override
  NeteaseAccount? build() => null;

  /// 启动初始化：匿名注册（幂等，LRU 缓存）+ 读取当前登录账号。
  Future<void> init() async {
    final api = ref.read(neteaseApiProvider);
    await api.ensureAnonymous();
    state = await api.loginStatus();
  }

  /// 扫码登录成功后刷新账号（由登录弹窗调用）。
  Future<void> refresh() async {
    state = await ref.read(neteaseApiProvider).loginStatus();
  }

  /// 退出登录。
  Future<void> logout() async {
    final uid = state?.userId;
    await ref.read(neteaseApiProvider).logout();
    state = null;
    // 清空该用户「我喜欢」磁盘缓存（后台 isolate，防串号；见
    // KugouApi.clearSession 同款逻辑）
    if (uid != null && uid.isNotEmpty) {
      unawaited(LikedCacheStore.shared.invalidate('netease', uid));
    }
  }

  /// 仅清空本地登录态（不发请求；安全销毁流程在主动失效 token 后兜底调用）。
  void clear() {
    final uid = state?.userId;
    state = null;
    if (uid != null && uid.isNotEmpty) {
      unawaited(LikedCacheStore.shared.invalidate('netease', uid));
    }
  }
}

// ── 直连KG API ────────────────────────────────────────────────

/// 直连KG（Dart 原生 HTTP + android 签名，不经侧车 RPC）。
///
/// [ChangeNotifierProvider]：登录态（session）变化时通知 UI 重建。
final kugouApiProvider = ChangeNotifierProvider<KugouApi>((ref) => KugouApi());

// ── 直连 QM API ───────────────────────────────────────────────

/// 直连 QM（apis/qqmusic Dart 移植，明文 JSON + UA/comm 伪装）。
///
/// [ChangeNotifierProvider]：登录态（cookie 落盘 vault）变化时通知 UI。
final qqMusicApiProvider = ChangeNotifierProvider<QqMusicApi>(
  (ref) => QqMusicApi(),
);

// ── 实验性音源 NekoMusic ────────────────────────────────────────

/// NekoMusic 直连（统一 REST + 不透明 token；纯 Dart，无签名加密）。
///
/// **实验性音源，默认关闭**（`source.neko.enabled`）：关闭时 UI 不展示
/// Neko 平台、也不发请求。登录态变化（token 恢复 / 登录 / 登出）时通知 UI。
final nekoApiProvider = ChangeNotifierProvider<NekoApi>((ref) => NekoApi());

/// Neko 下载歌词重写（Neko 元数据已规范，仅下载时把站点广告歌词换成标准 LRC）。
final nekoLyricRewriterProvider = Provider<NekoLyricRewriter>(
  (ref) => NekoLyricRewriter(),
);

/// 列表逐行读取最高音质时的并发限制器（避免瞬时几十个 `/api/music/info` 并发）。
class _AsyncLimiter {
  _AsyncLimiter(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

final _nekoMaxQualityLimiterProvider = Provider<_AsyncLimiter>(
  (ref) => _AsyncLimiter(3),
);

/// Neko 曲目实际最高音质（`/api/music/info/{id}` 的 `maxQuality`，已归一化为
/// 服务端四档 `standard`/`hq`/`sq`/`hires`）。
///
/// 播放页 / 详情弹窗 / 歌曲列表角标据此裁剪与展示；失败 / 未升级 / 无字段
/// → null。按曲目 id 缓存（非 autoDispose：一次请求终身命中，列表滚动不重发）。
final nekoMaxQualityProvider = FutureProvider.family<String?, String>(
  (ref, id) => ref
      .read(_nekoMaxQualityLimiterProvider)
      .run(() => ref.read(nekoApiProvider).fetchMaxQuality(id)),
);

// ── 顶栏微型天气 ────────────────────────────────────────────────

/// 天气状态（默认关闭，见 `appearance.weatherEnabled`；关闭时不发请求）。
final weatherProvider = ChangeNotifierProvider<WeatherNotifier>(
  (ref) => WeatherNotifier(),
);

// ── 事件总线 ────────────────────────────────────────────────────

/// 应用层事件总线（EventBus 作为统一事件通道）。
final eventBusProvider = Provider<EventBus>((ref) {
  final bus = EventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

// ── 播放历史 / 红心状态 ─────────────────────────────────────────

/// 播放历史本地存储（sqlite UI 线程同步直写，见 [HistoryStore]）。
final historyStoreProvider = Provider<HistoryStore>((ref) => HistoryStore.shared);

/// 红心状态（NT / KG「我喜欢」）。
final likeControllerProvider = ChangeNotifierProvider<LikeController>(
  (ref) => LikeController(ref),
);

/// 全局「我喜欢」列表数据源（KG / NT全量 Track + 缓存秒开；
/// 红心状态由 LikeController 独立轻量同步，不由此派生）。
///
/// **非 autoDispose**：跨页共享——[LikeController.toggle] 在任意页面成功后据此
/// 维护列表增量（`_applyStoreDelta`），设置弹窗（collection_platform）也以
/// `ref.read` 触发异步刷新/写入；autoDispose 会在这些异步 `await` 期间释放
/// ChangeNotifier，触发已释放实例上的 `notifyListeners`。内存释放由
/// 「最小化时卸载全部内存状态」的 invalidate 路径负责。
final likedStoreProvider = ChangeNotifierProvider<LikedStore>(
  (ref) => LikedStore(ref),
);

/// QM红心收藏本机数据源（见 QqLikedStore：本机主源 + 在线实验并入）。
/// 构造即异步加载本地 `qq_liked.json`；登录 QQ 后 LikeController 同步会把
/// 在线「我喜欢」并入红心集合，「我喜欢」页刷新时把在线 Track 并入本列表。
///
/// **非 autoDispose**：启动流程（bootstrap 登录 QQ 后并入在线收藏）与设置弹窗
/// 均以 `ref.read` + 异步 `await` 使用本 store（`mergeOnline` 内部 await 加载、
/// 再 notify）；autoDispose 会在页外释放它并导致已释放实例继续被写。
final qqLikedStoreProvider = ChangeNotifierProvider<QqLikedStore>(
  (ref) => QqLikedStore(),
);

/// 系统主题色（主题色来源 = default「跟随系统」时作为主色种子）。
///
/// 事件驱动：先读一次，再订阅平台桥接的主题色变更事件（KDE/GNOME/Windows/
/// macOS），变更时重读；无法读取返回 null，调用方回退默认亮蓝。
final systemAccentProvider = StreamProvider<Color?>((ref) async* {
  // 仅在「主题色来源 = 跟随系统」时订阅系统强调色；custom/cover/solid 下完全
  // 不接触系统色（不查询、不订阅）。
  final source = ref.watch(appPrefsProvider.select((p) => p.themeSource));
  if (source != 'default') return;
  final caps = PlatformCapabilities.instance();
  if (!caps.systemAccentAvailable) return;
  // 平台**推送**模型：订阅时桥接立即推当前值，之后推变化——Dart 不主动查询。
  if (caps.setAccentEvents(true) != 0) return;
  ref.onDispose(() => caps.setAccentEvents(false));
  yield* caps.accentEvents;
});

/// 系统深浅色（平台推送；dark=true 深色）。仅在主题模式为 `system` 时订阅，
/// 驱动 `ThemeMode.system` 的解析（见 `app.dart`）。桥接不可用时不产出。
final systemThemeProvider = StreamProvider<bool>((ref) async* {
  final mode = ref.watch(appPrefsProvider.select((p) => p.themeMode));
  if (mode != 'system') return;
  final caps = PlatformCapabilities.instance();
  if (!caps.systemThemeAvailable) return;
  // 平台**推送**模型：订阅即收当前值，之后收变化——Dart 不主动查询。
  if (caps.setSystemThemeEvents(true) != 0) return;
  ref.onDispose(() => caps.setSystemThemeEvents(false));
  yield* caps.systemThemeEvents;
});

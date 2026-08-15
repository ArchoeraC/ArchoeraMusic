import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

import '../services/history/history_store.dart';
import '../services/kugou/kugou_api.dart';
import '../services/liked/liked_cache.dart';
import '../services/liked/liked_loader.dart';
import '../services/netease/apis_netease_caller.dart';
import '../services/netease/netease_api.dart';
import '../services/weather/weather_notifier.dart';
import 'event_bus.dart';
import 'like_controller.dart';
import 'system_accent.dart';

// ── 直连网易云 API ──────────────────────────────────────────────

/// 直连网易云（纯 Dart：apis 包全量移植，weapi/eapi/xeapi 加密，不经侧车 RPC）。
final neteaseApiProvider = Provider<NeteaseApi>((ref) {
  return NeteaseApi(ApisNeteaseCaller());
});

/// 网易云登录态（login_status 账号）。null = 未登录。
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

// ── 直连酷狗 API ────────────────────────────────────────────────

/// 直连酷狗（Dart 原生 HTTP + android 签名，不经侧车 RPC）。
///
/// [ChangeNotifierProvider]：登录态（session）变化时通知 UI 重建。
final kugouApiProvider = ChangeNotifierProvider<KugouApi>((ref) => KugouApi());

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

/// 红心状态（网易云 / 酷狗「我喜欢」）。
final likeControllerProvider = ChangeNotifierProvider<LikeController>(
  (ref) => LikeController(ref),
);

/// 全局「我喜欢」列表数据源（酷狗 / 网易云全量 Track + 缓存秒开；
/// 红心状态由 LikeController 独立轻量同步，不由此派生）。
final likedStoreProvider = ChangeNotifierProvider<LikedStore>(
  (ref) => LikedStore(ref),
);

/// 系统主题色（主题色来源 = default「跟随系统」时作为主色种子）。
///
/// 实时读取系统（GNOME accent-color）；非 Linux / 无法读取返回 null，
/// 调用方回退设计体系默认亮蓝（对齐原版 themeSource=default 的
/// DEFAULT_PRIMARY 语义）。
final systemAccentProvider = FutureProvider<Color?>((ref) {
  return SystemAccent.read();
});

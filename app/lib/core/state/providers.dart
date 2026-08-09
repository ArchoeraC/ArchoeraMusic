import 'package:flutter/material.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

import '../history/history_store.dart';
import '../kugou/direct/kugou_api.dart';
import '../netease/apis_netease_caller.dart';
import '../netease/netease_api.dart';
import 'app_prefs.dart';
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
    await ref.read(neteaseApiProvider).logout();
    state = null;
  }
}

// ── 直连酷狗 API ────────────────────────────────────────────────

/// 直连酷狗（Dart 原生 HTTP + android 签名，不经侧车 RPC）。
///
/// [ChangeNotifierProvider]：登录态（session）变化时通知 UI 重建。
final kugouApiProvider = ChangeNotifierProvider<KugouApi>((ref) => KugouApi());

// ── 事件总线 ────────────────────────────────────────────────────

/// 应用层事件总线（EventBus 作为统一事件通道）。
final eventBusProvider = Provider<EventBus>((ref) {
  final bus = EventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

// ── 播放历史 / 红心状态 ─────────────────────────────────────────

/// 播放历史本地存储（sqlite，首次使用时惰性打开）。
final historyStoreProvider = Provider<HistoryStore>((ref) {
  final store = HistoryStore.open();
  ref.onDispose(store.close);
  return store;
});

/// 红心状态（网易云 / 酷狗「我喜欢」）。
final likeControllerProvider =
    ChangeNotifierProvider<LikeController>((ref) => LikeController(ref));

// ── 系统主题色 ──────────────────────────────────────────────────

/// 系统主题色（「跟随系统主题色」开启时作为主色种子）。
///
/// 未开启 / 非 Linux / 读取失败时为 null。结果按 prefs 缓存：
/// 切换开关会使其重新计算（Riverpod 依赖感知）。
final systemAccentProvider = FutureProvider<Color?>((ref) async {
  if (!ref.watch(appPrefsProvider).accentSystem) return null;
  return SystemAccent.read();
});

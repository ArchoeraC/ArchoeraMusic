import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'apis/runtime.dart';
import 'services/power/frame_governor.dart';
import 'services/streaming/streaming_store.dart';
import 'stores/app_prefs.dart';
import 'stores/vault_session_store.dart';
import 'app/app.dart';
import 'widgets/list/cover_image.dart';
import 'widgets/common/tray_integration.dart';

/// ArchoeraMusic — 应用入口。
///
/// 职责：ProviderScope 注入 + 宿主运行时注入（账号会话经凭据保险库
/// vault 加密落盘，登录态跨重启保留；vault 不可用时降级内存并告警）
/// + 窗口/托盘后台常驻。播放链路由 C 引擎内置 miniaudio 承担
/// （无 libmpv/media_kit 依赖）。
Future<void> main() async {
  // 全局帧节流 Binding（节能模式渲染层）：必须最先初始化，替代默认 binding
  PowerSavingFrameBinding.ensureInitialized();
  // 网易云封面 CDN 拒绝 Dart 默认 UA（403）；Image.network 经 NetworkImage
  // 以 add 语义追加自定义头，传 UA 会与默认 Dart UA 叠加成双头被拒收。
  // 改全局 HttpClient 默认 UA 为浏览器 UA，天然保证单头。
  HttpOverrides.global = _BrowserUserAgentOverrides();
  // 会话存储：vault 加密持久化（先加载/迁移旧明文，再注入宿主运行时，
  // 保证 kugou/netease 提供者首次读取时已就绪）。默认加密方案（crypto
  // 推荐 / vault 实验性）来自设置页偏好，控制惰性重建时初始化哪种方案。
  final prefs = AppPrefs.load();
  StreamingStore.defaultScheme = prefs.credentialScheme;
  final sessionStore =
      VaultSessionStore(defaultScheme: prefs.credentialScheme);
  await sessionStore.initialize();
  if (!sessionStore.vaultAvailable) {
    // 凭据保险库不可用：登录态仅内存保留（不静默降级为明文持久化）
    debugPrint('[vault] 凭据保险库不可用，登录态将不持久化（重启需重新登录）');
  }
  // 流媒体服务器凭据从 vault 预取进内存缓存（[load] 同步接口的凭据来源，
  // 首帧读取前完成，避免同步接口依赖异步会话）
  await StreamingStore.preloadSecrets();
  setRuntime(runtime: ApisRuntime(sessionStore: sessionStore));
  // 全局图片解码缓存：张数上限固定（防内存碎片）；字节上限由设置
  // 「封面图片缓存上限」动态控制（默认下限 8 MiB，见 ArchoeraMusicApp，
  // null = 无上限仅按张数约束）。
  PaintingBinding.instance.imageCache.maximumSize = 1000;
  // 窗口管理（后台常驻：关闭到托盘需拦截窗口关闭事件）
  await windowManager.ensureInitialized();
  runApp(
    const ProviderScope(child: TrayIntegration(child: ArchoeraMusicApp())),
  );
}

/// 让所有 HttpClient（含 Flutter Image.network 共享 client）默认携带浏览器 UA。
class _BrowserUserAgentOverrides extends HttpOverrides {
  _BrowserUserAgentOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.userAgent = coverUserAgent;
    return client;
  }
}

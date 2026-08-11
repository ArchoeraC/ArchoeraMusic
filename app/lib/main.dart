import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'apis/runtime.dart';
import 'services/power/frame_governor.dart';
import 'stores/netease_session.dart';
import 'app/app.dart';
import 'widgets/list/cover_image.dart';
import 'widgets/common/tray_integration.dart';

/// ArchoeraMusic — 应用入口。
///
/// 职责：ProviderScope 注入 + 宿主运行时注入（网易云会话落盘，登录态
/// 跨重启保留）+ 窗口/托盘后台常驻。播放链路由 C 引擎内置 miniaudio
/// 承担（无 libmpv/media_kit 依赖）。
Future<void> main() async {
  // 全局帧节流 Binding（节能模式渲染层）：必须最先初始化，替代默认 binding
  PowerSavingFrameBinding.ensureInitialized();
  // 网易云封面 CDN 拒绝 Dart 默认 UA（403）；Image.network 经 NetworkImage
  // 以 add 语义追加自定义头，传 UA 会与默认 Dart UA 叠加成双头被拒收。
  // 改全局 HttpClient 默认 UA 为浏览器 UA，天然保证单头。
  HttpOverrides.global = _BrowserUserAgentOverrides();
  setRuntime(runtime: ApisRuntime(sessionStore: FileSessionStore()));
  // 全局图片解码缓存上限（性能调优，借鉴 Electron/浏览器 HTTP 图片缓存
  // 思路）：桌面端内存充裕，封面已按显示尺寸降采样（见 CoverImage，单图
  // 约几十~几百 KB），缓存放宽到 1000 张 / 256MB——大列表快速滚动时避免
  // 封面被过早逐出导致反复网络请求 + 解码的卡顿。
  PaintingBinding.instance.imageCache
    ..maximumSize = 1000
    ..maximumSizeBytes = 256 * 1024 * 1024;
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

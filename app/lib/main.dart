import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'apis/runtime.dart';
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
  WidgetsFlutterBinding.ensureInitialized();
  // 网易云封面 CDN 拒绝 Dart 默认 UA（403）；Image.network 经 NetworkImage
  // 以 add 语义追加自定义头，传 UA 会与默认 Dart UA 叠加成双头被拒收。
  // 改全局 HttpClient 默认 UA 为浏览器 UA，天然保证单头。
  HttpOverrides.global = _BrowserUserAgentOverrides();
  setRuntime(runtime: ApisRuntime(sessionStore: FileSessionStore()));
  // 窗口管理（后台常驻：关闭到托盘需拦截窗口关闭事件）
  await windowManager.ensureInitialized();
  runApp(
    const ProviderScope(
      child: TrayIntegration(child: ArchoeraMusicApp()),
    ),
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

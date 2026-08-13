/// 统一退出入口（绕开 Flutter Linux GTK teardown 崩溃）。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/vault_session_store.dart';

/// 退出应用（所有退出路径统一走此入口）。
///
/// 背景：Flutter Linux GTK embedder 已知缺陷——`windowManager.destroy()`
/// （底层 gtk_window_close）触发 FlView teardown 竞态：
/// `FlutterEngineRemoveView returned kInvalidArguments（implicit view
/// cannot be removed）` 后 GTK 继续访问已释放 widget（use-after-free），
/// 退出必现 SIGSEGV（TriOS / MusicPod / yubioath-flutter / gleec-wallet
/// 同病，2026-08 尚无稳定修复）。规避：**不走 GTK 关闭链**，落盘关键
/// 状态后直接 `exit(0)`——进程退出由 OS 回收，天然绕开 GTK 销毁竞态。
///
/// 退出前保证：
/// - 播放现场同步落盘（原由 [PlaybackNotifier] dispose 承担，exit 不触发）；
/// - vault 会话写队列 flush（save/clear 为异步 enqueue，exit 会丢 pending）；
/// - 短暂等待引擎 FFI / 后台 isolate 收尾（引擎线程随进程退出回收）。
Future<void> quitApplication(WidgetRef ref) async {
  // 播放现场同步落盘（会话记忆关闭时 _persistSession 内部自行跳过）
  ref.read(playbackProvider.notifier).persistNow();
  // vault 会话写队列 flush（登录态/凭据不丢；仅 vault 实现有异步队列）
  final store = getRuntime().sessionStore;
  if (store is VaultSessionStore) {
    await store.flush();
  }
  // 给引擎 FFI / 后台 isolate 短暂收尾后退出
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(0);
}

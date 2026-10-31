// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../apis/netease/api.dart';
import '../apis/qqmusic/core/request.dart';
import '../services/downloader/download_controller.dart';
import '../services/log/log.dart';
import 'providers.dart';

/// 解锁成功后的**统一收尾**：丢弃「凭据库锁定期」固化的空会话缓存 → 重读登录态
/// → 重注下载引擎会话。
///
/// **所有解锁入口都必须调用本函数**（解锁门口令/恢复码、设置页口令/恢复码……）。
///
/// 2026-10-14 实录（两个同类缺口）：
/// 1) `_loadSession()` 会把锁定期间读到的**空会话**固化进缓存 → 解锁后
///    `loginStatus()` 仍读旧空值 → 「解锁了但登录态读不回来」；
/// 2) 设置页的恢复码解锁只解锁了库、**漏了这一步** → 同样读不回来。
/// 故把收尾集中到一处，并在 [NeteaseAuthNotifier.init] 内再做一次缓存失效（双保险）。
///
/// [ref] 传 `ref`（`WidgetRef`）或 `ProviderContainer`——两者都提供 `.read`，
/// 便于 widget 与单元测试共用同一条路径。
Future<void> refreshAfterVaultUnlock(dynamic ref) async {
  // ① 先丢弃「库锁定期间」可能固化的各平台内存缓存（否则解锁后仍读到空）。
  invalidateNeteaseSessionCache();
  qmReloadQQMusicCookies(); // QQ cookies 为进程级缓存，须显式失效

  // ② 逐平台重读登录态。四个平台的"登录态来源"各不相同：
  //    NetEase：Notifier（显式 init）
  //    Kugou  ：API 实例在**构造期**从库内会话恢复 → 重建实例
  //    Neko   ：显式 `restore()`（bootstrap 入口）
  //    QQ     ：进程级 cookie 缓存 → 已在 ① 失效，此后按需重取
  try {
    await ref.read(neteaseAuthProvider.notifier).init();
  } catch (e) {
    // 网络异常不阻断解锁（登录态可能仍为空，用户可后续重登）。
    Log.e('vault', '解锁后登录态刷新失败（NetEase）：$e');
  }
  // B 站：请求层每次从 store 读取 Cookie，无需重建实例；显式拉一次资料。
  try {
    await ref.read(bilibiliApiProvider).loadProfileSilently();
  } catch (e) {
    Log.e('vault', '解锁后登录态刷新失败（Bilibili）：$e');
  }
  ref.invalidate(kugouApiProvider);
  try {
    await ref.read(nekoApiProvider).restore();
  } catch (e) {
    Log.e('vault', '解锁后登录态刷新失败（Neko）：$e');
  }
  ref.read(downloadControllerProvider.notifier).syncSessions();
}

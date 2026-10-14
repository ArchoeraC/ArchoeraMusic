// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/apis/netease/api.dart';
import 'package:archoera_music/apis/runtime.dart';

/// 回归（2026-10-14 实录）：**凭据库锁定期间的空会话被固化进缓存**，导致
/// m2a 用户用口令/恢复码解锁后 `loginStatus()` 仍读旧空缓存 → 登录态永远
/// 恢复不了（"恢复码解锁后没有读取登录态"）。
///
/// 根因：`_loadSession()` 无条件缓存 `sessionStore.get('netease')`，而启动阶段
/// （库仍锁定时）已有匿名注册/登录态查询调用过它。LEGACY 免密自动解锁故从未暴露。
class _FakeSessionStore implements SessionStore {
  final Map<String, Map<String, String>> data = {};
  bool locked = false;

  @override
  Map<String, String> get(String platform) => data[platform] ?? {};

  @override
  void save(String platform, Map<String, String> cookies) =>
      data[platform] = {...cookies};

  @override
  void clear(String platform) => data[platform] = {};

  @override
  bool get isLocked => locked;
}

void main() {
  late ApisRuntime prev;
  setUp(() {
    prev = getRuntime();
    invalidateNeteaseSessionCache(); // 模块级静态缓存：用例间显式复位
  });
  tearDown(() => setRuntime(runtime: prev));

  test('库锁定期间的空会话不得缓存：解锁后能读到登录态（核心回归）', () {
    final fake = _FakeSessionStore()..locked = true;
    setRuntime(runtime: ApisRuntime(sessionStore: fake));

    // 启动阶段（库锁定）读到空 —— 不得固化
    expect(debugLoadNeteaseSession(), isEmpty);

    // 用户解锁：库里出现会话
    fake.data['netease'] = {'MUSIC_U': 'logged-in-cookie'};
    fake.locked = false;

    expect(debugLoadNeteaseSession(), containsPair('MUSIC_U', 'logged-in-cookie'),
        reason: '锁定期间的空结果被固化 → 解锁后读不回来（本次实录的 bug）');
  });

  test('解锁入口显式失效缓存（双保险）', () {
    final fake = _FakeSessionStore()..locked = false;
    setRuntime(runtime: ApisRuntime(sessionStore: fake));

    fake.data['netease'] = {'MUSIC_U': 'a'};
    expect(debugLoadNeteaseSession(), containsPair('MUSIC_U', 'a'));

    fake.data['netease'] = {'MUSIC_U': 'b'}; // 重新登录 / 会话轮换
    expect(debugLoadNeteaseSession(), containsPair('MUSIC_U', 'a'),
        reason: '正常缓存语义：未失效前仍读旧值');

    invalidateNeteaseSessionCache();
    expect(debugLoadNeteaseSession(), containsPair('MUSIC_U', 'b'),
        reason: '失效后必须重读（解锁流程依赖此语义）');
  });
}

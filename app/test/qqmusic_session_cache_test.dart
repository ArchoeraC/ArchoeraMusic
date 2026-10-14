// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/apis/qqmusic/core/request.dart';
import 'package:archoera_music/apis/runtime.dart';

/// 回归（2026-10-14）：QQ cookies 与 NetEase 有**同源**的缓存污染 ——
/// `qmGetQQMusicCookies()` 无条件缓存 `sessionStore.get('qqmusic')`，
/// 而 m2a 启动期库必为锁定 → 空 cookies 被固化 → 解锁后仍读到空 ✗。
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
    qmReloadQQMusicCookies(); // 模块级静态缓存：用例间显式复位
  });
  tearDown(() => setRuntime(runtime: prev));

  test('库锁定期间的空 cookies 不得缓存：解锁后能读到登录态（核心回归）', () {
    final fake = _FakeSessionStore()..locked = true;
    setRuntime(runtime: ApisRuntime(sessionStore: fake));

    expect(qmGetQQMusicCookies(), isEmpty); // 启动期（锁定）

    fake.data['qqmusic'] = {'qm_keyst': 'logged-in-key'};
    fake.locked = false; // 用户解锁

    expect(qmGetQQMusicCookies(), containsPair('qm_keyst', 'logged-in-key'),
        reason: '锁定期间的空结果被固化 → 解锁后读不回来（与 NetEase 同源 bug）');
  });

  test('qmReloadQQMusicCookies 显式失效缓存（解锁收尾调用）', () {
    final fake = _FakeSessionStore()..locked = false;
    setRuntime(runtime: ApisRuntime(sessionStore: fake));

    fake.data['qqmusic'] = {'qm_keyst': 'a'};
    expect(qmGetQQMusicCookies(), containsPair('qm_keyst', 'a'));

    fake.data['qqmusic'] = {'qm_keyst': 'b'}; // 重新登录 / 会话轮换
    expect(qmGetQQMusicCookies(), containsPair('qm_keyst', 'a'),
        reason: '正常缓存语义：未失效前读旧值');

    qmReloadQQMusicCookies();
    expect(qmGetQQMusicCookies(), containsPair('qm_keyst', 'b'),
        reason: '解锁收尾失效后必须重读');
  });
}

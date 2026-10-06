// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 每日推荐书架控制器单测：`ensure()` / `refresh()` **直接返回当日曲目**。
//
// 回归背景：`dailyShelfProvider` 为 autoDispose，调用方多以 `ref.read`（不建立
// 监听）触发；若 `ensure()` 返回 void、调用方随后再 `ref.read(...).today`，provider
// 可能已被释放并重建为空态 → 每日推荐弹窗/聚光一直空白。此测试锁定「返回值即
// 当日曲目」这一契约。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/daily/daily_shelf.dart';
import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/daily_shelf_provider.dart';
import 'package:archoera_music/stores/providers.dart';

Track _t(String id) =>
    Track(id: id, title: 'T$id', source: 'netease', artists: const []);

/// 固定返回预设曲目的 NT API（不联网）。
class _FakeNeteaseApi extends NeteaseApi {
  _FakeNeteaseApi(this.songs) : super(ApisNeteaseCaller());
  final List<Track> songs;

  @override
  Future<List<Track>> recommendSongs() async => songs;
}

/// 固定登录账号的 auth 控制器。
class _FakeAuth extends NeteaseAuthNotifier {
  _FakeAuth(this._account);
  final NeteaseAccount? _account;

  @override
  NeteaseAccount? build() => _account;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('daily_shelf_provider');
    DailyShelfStore.overridePath = '${tmp.path}/daily_shelf.json';
  });
  tearDown(() {
    DailyShelfStore.overridePath = null;
    tmp.deleteSync(recursive: true);
  });

  test('登录态：ensure() 返回当日曲目', () async {
    final container = ProviderContainer(
      overrides: [
        neteaseAuthProvider.overrideWith(
          () => _FakeAuth(const NeteaseAccount(userId: 'u1', nickname: 'n')),
        ),
        neteaseApiProvider.overrideWithValue(
          _FakeNeteaseApi([_t('a'), _t('b')]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final got = await container.read(dailyShelfProvider.notifier).ensure();
    expect(got.map((t) => t.id).toList(), ['a', 'b']);
  });

  test('未登录：ensure() 返回空', () async {
    final container = ProviderContainer(
      overrides: [
        neteaseAuthProvider.overrideWith(() => _FakeAuth(null)),
        neteaseApiProvider.overrideWithValue(_FakeNeteaseApi([_t('a')])),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(dailyShelfProvider.notifier).ensure(), isEmpty);
  });

  test('refresh() 返回刷新后的曲目', () async {
    final container = ProviderContainer(
      overrides: [
        neteaseAuthProvider.overrideWith(
          () => _FakeAuth(const NeteaseAccount(userId: 'u1', nickname: 'n')),
        ),
        neteaseApiProvider.overrideWithValue(_FakeNeteaseApi([_t('x')])),
      ],
    );
    addTearDown(container.dispose);

    final got = await container.read(dailyShelfProvider.notifier).refresh();
    expect(got.map((t) => t.id).toList(), ['x']);
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 首页「随机聚光」控制器：汇总候选来源、按逻辑日可复现地抽一组并支持换一批。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/daily/daily_shelf.dart';
import '../services/netease/track.dart';
import '../services/scanner/library_store.dart';
import '../services/spotlight/spotlight.dart';
import 'daily_shelf_provider.dart';
import 'providers.dart';

/// 本地来源每次随机抽取的曲目数（够覆盖预览与换一批）。
const int kSpotlightLocalSampleSize = 60;

/// 聚光状态。
class SpotlightState {
  const SpotlightState({
    this.pick,
    this.loading = false,
    this.ready = false,
    this.lastSource,
    this.recent = const [],
  });

  final SpotlightPick? pick;
  final bool loading;
  final bool ready;
  final SpotlightSource? lastSource;

  /// 最近展示过的起始曲 key（避让，最新在前）。
  final List<String> recent;

  SpotlightState copyWith({
    SpotlightPick? pick,
    bool? loading,
    bool? ready,
    SpotlightSource? lastSource,
    List<String>? recent,
  }) => SpotlightState(
    pick: pick ?? this.pick,
    loading: loading ?? this.loading,
    ready: ready ?? this.ready,
    lastSource: lastSource ?? this.lastSource,
    recent: recent ?? this.recent,
  );
}

/// 首页聚光控制器。
class SpotlightNotifier extends Notifier<SpotlightState> {
  /// 重掷次数（参与种子派生；重启归零 → 当日回到默认那一抽）。
  int _roll = 0;

  @override
  SpotlightState build() => const SpotlightState();

  /// 首次 / 重新汇总来源并抽一次（幂等，加载中忽略）。
  Future<void> ensure() async {
    // autoDispose：卡片用 `ref.watch` 正常持有；但页面子树可能在加载途中卸载
    // （后台卸载 / 播放页展开），届时写 `state` 会抛 UnmountedRefException。
    // 加载期间持有保活链接，完成后再交还释放（此时无监听才真正卸载）。
    final keepAlive = ref.keepAlive();
    try {
      if (state.loading) return;
      state = state.copyWith(loading: true);
      Map<SpotlightSource, List<Track>> pools;
      try {
        pools = await _gatherPools();
      } catch (_) {
        pools = const {};
      }
      final dayKey = dailyShelfDayKey(DateTime.now());
      final pick = rollSpotlight(
        pools: pools,
        rng: SpotlightRng(spotlightSeed(dayKey, _roll)),
        avoidSource: state.lastSource,
        recentLeadKeys: state.recent.toSet(),
      );
      state = SpotlightState(
        pick: pick,
        loading: false,
        ready: true,
        lastSource: pick?.source ?? state.lastSource,
        recent: pick == null
            ? state.recent
            : pushRecentLead(state.recent, pick.lead),
      );
    } finally {
      keepAlive.close();
    }
  }

  /// 换一批：递增重掷次数并重抽（避开上一轮来源与最近起始曲）。
  Future<void> reroll() async {
    _roll++;
    await ensure();
  }

  /// 汇总可用来源：每日推荐（登录）→ 我的收藏（已加载内存）→ 本地随机。
  Future<Map<SpotlightSource, List<Track>>> _gatherPools() async {
    final pools = <SpotlightSource, List<Track>>{};

    if (ref.read(neteaseAuthProvider) != null) {
      await ref.read(dailyShelfProvider.notifier).ensure();
      final daily = ref.read(dailyShelfProvider).today;
      if (daily.isNotEmpty) pools[SpotlightSource.daily] = daily;
    }

    final likedStore = ref.read(likedStoreProvider);
    final liked = <Track>[
      ...likedStore.tracks('netease'),
      ...likedStore.tracks('kugou'),
      ...ref.read(qqLikedStoreProvider).tracks,
    ];
    if (liked.isNotEmpty) pools[SpotlightSource.liked] = liked;

    final local = await ref
        .read(libraryStoreProvider.notifier)
        .randomTracks(kSpotlightLocalSampleSize);
    if (local.isNotEmpty) pools[SpotlightSource.local] = local;

    return pools;
  }
}

/// 首页聚光（随机来源 + 随机起始曲）。
///
/// autoDispose：聚光只服务首页卡片（卡片用 `ref.watch` 持有），页面子树卸载
/// （后台卸载页面 / 最小化卸载全部内存状态 / 播放页展开）后即释放内存；
/// 重进首页时卡片 initState 会再次触发 [SpotlightNotifier.ensure]。
final spotlightProvider =
    NotifierProvider.autoDispose<SpotlightNotifier, SpotlightState>(
      SpotlightNotifier.new,
    );

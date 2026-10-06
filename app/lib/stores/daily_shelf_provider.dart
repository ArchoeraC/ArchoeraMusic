// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 每日推荐「书架」控制器：按逻辑日缓存 / 归档，供首页聚光与日推弹窗共用。
///
/// 职责：登录态变化时切换账号档位；当日未拉取则从书架命中或网络拉取并落盘；
/// 暴露「今日 / 历史」两个视图与加载 / 错误态。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/daily/daily_shelf.dart';
import '../services/netease/track.dart';
import 'providers.dart';

/// 每日推荐视图状态。
class DailyShelfState {
  const DailyShelfState({
    this.userId,
    this.dayKey = '',
    this.today = const [],
    this.history = const [],
    this.loading = false,
    this.ready = false,
    this.error,
  });

  /// 当前账号 id（null = 未登录 / 未初始化）。
  final String? userId;

  /// 今日逻辑日 key。
  final String dayKey;

  /// 今日推荐曲目（未就绪为空）。
  final List<Track> today;

  /// 历史归档（不含今日，最新在前）。
  final List<DailyShelfDay> history;

  final bool loading;

  /// 是否已完成一次初始化（含未登录的空态）。
  final bool ready;

  final String? error;

  DailyShelfState copyWith({
    String? userId,
    String? dayKey,
    List<Track>? today,
    List<DailyShelfDay>? history,
    bool? loading,
    bool? ready,
    String? error,
    bool clearError = false,
  }) => DailyShelfState(
    userId: userId ?? this.userId,
    dayKey: dayKey ?? this.dayKey,
    today: today ?? this.today,
    history: history ?? this.history,
    loading: loading ?? this.loading,
    ready: ready ?? this.ready,
    error: clearError ? null : (error ?? this.error),
  );
}

/// 每日推荐书架控制器。
class DailyShelfNotifier extends Notifier<DailyShelfState> {
  bool _inflight = false;

  @override
  DailyShelfState build() =>
      DailyShelfState(dayKey: dailyShelfDayKey(DateTime.now()));

  /// 确保今日推荐可用：命中当日归档直接返回，否则（登录态下）拉取并落盘。
  ///
  /// 返回**当日曲目**（未登录 / 拉取失败为空）。返回值在 `keepAlive` 关闭前
  /// 已捕获，调用方应直接使用它——**切勿** `ensure()` 后再
  /// `ref.read(dailyShelfProvider)`：本 provider 为 autoDispose 且调用方多以
  /// `ref.read`（不建立监听）触发，`ensure` 结束即可能被释放并重建为空态
  /// （曾导致「每日推荐」弹窗/聚光一直空白）。
  ///
  /// [force] 为真时忽略当日缓存强制刷新（「刷新日推」）。
  Future<List<Track>> ensure({bool force = false}) async {
    // autoDispose：调用方普遍以 `ref.read(dailyShelfProvider.notifier).ensure()`
    // 触发（读取不建立监听），必须在本次异步操作期间持有保活链接，否则 provider
    // 会在首个事件循环后被释放，结果写进已释放实例。操作结束即闭链；状态随后
    // 由磁盘书架按需重建。
    final keepAlive = ref.keepAlive();
    try {
      final account = ref.read(neteaseAuthProvider);
      final nowKey = dailyShelfDayKey(DateTime.now());
      if (account == null) {
        state = DailyShelfState(dayKey: nowKey, ready: true);
        return state.today;
      }
      final uid = account.userId;
      if (state.userId != uid) {
        // 切号：读该账号的书架（避免串数据）。
        state = _fromDays(uid, nowKey, const DailyShelfStore().days(uid));
      }
      if (!force && state.dayKey == nowKey && state.today.isNotEmpty) {
        state = state.copyWith(ready: true, loading: false, clearError: true);
        return state.today;
      }
      if (_inflight) return state.today;
      _inflight = true;
      state = state.copyWith(loading: true, dayKey: nowKey, clearError: true);
      try {
        final tracks = await ref.read(neteaseApiProvider).recommendSongs();
        if (tracks.isNotEmpty) {
          const DailyShelfStore().put(
            uid,
            DailyShelfDay(
              key: nowKey,
              savedAtMs: DateTime.now().millisecondsSinceEpoch,
              tracks: tracks,
            ),
          );
        }
        // 以本次网络结果为准构造状态（不依赖磁盘回读：put 失败 / 磁盘不可写
        // 时不至于把当天推荐显示为空）；历史仍从磁盘归档取。
        final shelf = _fromDays(uid, nowKey, const DailyShelfStore().days(uid));
        state = (tracks.isNotEmpty && shelf.today.isEmpty)
            ? DailyShelfState(
                userId: uid,
                dayKey: nowKey,
                today: tracks,
                history: shelf.history,
                ready: true,
              )
            : shelf;
      } catch (e) {
        state = state.copyWith(loading: false, ready: true, error: '$e');
      } finally {
        _inflight = false;
      }
      return state.today;
    } finally {
      keepAlive.close();
    }
  }

  /// 强制刷新今日推荐；返回刷新后的当日曲目。
  Future<List<Track>> refresh() => ensure(force: true);

  DailyShelfState _fromDays(String uid, String nowKey, List<DailyShelfDay> days) {
    DailyShelfDay? today;
    final history = <DailyShelfDay>[];
    for (final d in days) {
      if (today == null && d.key == nowKey) {
        today = d;
      } else {
        history.add(d);
      }
    }
    return DailyShelfState(
      userId: uid,
      dayKey: nowKey,
      today: today?.tracks ?? const [],
      history: history,
      ready: true,
    );
  }
}

/// 每日推荐书架（今日 / 历史）。
///
/// autoDispose：书架只服务首页聚光与日推弹窗（均以 `ref.read` 按需触发
/// [DailyShelfNotifier.ensure]），无页面持有监听；页面子树卸载后释放内存，
/// 数据本身按逻辑日落盘（`DailyShelfStore`），重进时再从磁盘秒读。
final dailyShelfProvider =
    NotifierProvider.autoDispose<DailyShelfNotifier, DailyShelfState>(
      DailyShelfNotifier.new,
    );

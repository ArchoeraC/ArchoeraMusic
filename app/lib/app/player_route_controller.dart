// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../services/log/log.dart';

/// 全屏播放页路由路径（`openPlayerPage` / 栈内匹配判定共用）。
const String kPlayerRoutePath = '/player';

/// 全屏播放页的生命周期阶段。
///
/// **只由事件推进**：打开/关闭入口置位，页面自身回报「已绑定动画 / 动画走完 /
/// 路由卸载」。壳层、顶栏等消费方不再从「动画值 / 路由栈 / push future」里
/// 反推开没开——那类推断正是此前反复出现「关不掉 / 打不开 / 壳层停绘不恢复」
/// 的根因（见 `docs/` 与各提交历史）。
enum PlayerRoutePhase {
  /// 路由不在栈上（唯一可以让下次打开直接 push 的状态）。
  closed,

  /// 已收到打开事件并 push，等待页面建出 / 进入动画推进中。
  opening,

  /// 进入动画已完成，页面完全展开。
  open,

  /// 已收到关闭事件并 pop，收起动画推进中（路由仍在栈上）。
  closing,
}

/// 全屏播放页开关的**唯一状态机**（进程级单例，事件驱动）。
///
/// ## 约定
/// - **命令**：[open] / [close] / [toggle] 只由触发点调用（封面点击、快捷键、
///   深链、关闭按钮），不在 widget 生命周期里调用；
/// - **页面事件**：[routeAttached] / [routeOpened] / [routeDismissed] /
///   [routeDetached] 由 `PlayerPage` 在对应时刻回报（可以在生命周期里调用）。
///
/// ## 为什么状态是同步字段、通知却走微任务
/// 守卫（「已开着就别再 push」「收起中先排队」）必须读到**最新**状态，所以
/// 字段在事件当帧同步更新；但通知监听方（壳层/顶栏）在 build 期会触发
/// `setState`，Riverpod / Flutter 都会断言。通知统一压到微任务：状态已生效，
/// 重建仍发生在下一帧之前，观感与同步通知一致，且不可能被丢弃（这正是旧实现
/// 里 `ProviderScope` 断言把清理逻辑打断、壳层永久停在停绘态的直接原因）。
class PlayerRouteController extends ChangeNotifier {
  PlayerRouteController._();

  /// 进程级单例（路由只有一份，状态也只应该有一份）。
  static final PlayerRouteController instance = PlayerRouteController._();

  PlayerRoutePhase _phase = PlayerRoutePhase.closed;

  /// 当前播放页**自身路由**的进入/退出动画（0 = 收起，1 = 完全展开）。
  Animation<double>? _animation;

  /// 当前播放页的路由对象（用于确认「栈顶是不是播放页」再 pop）。
  ///
  /// 快捷键在弹窗打开时同样会触发：直接 `pop()` 会关掉弹窗而不是播放页，
  /// 盲目重试更会连续 pop 掉下层页面。只在这条路由是栈顶时才动它。
  ModalRoute<dynamic>? _route;

  /// 最近一次打开事件的路由器（挂起的打开请求要回到同一个；测试会注入独立实例）。
  GoRouter? _router;

  /// 收起动画期间收到的打开请求：等路由真正卸载后再 push。
  bool _pendingOpen = false;

  /// 开关动作的代次：每次 open/close 起始递增，过期帧末核对直接作废。
  ///
  /// 快速连按时旧动作的核对回调可能在新动作之后才跑——没有代次守卫就会
  /// 反复 push/pop 同一帧里的路由，最终把页面卡在永远构建不出来的状态。
  int _epoch = 0;

  /// 通知已排队（同一帧内的多个事件合并成一次通知）。
  bool _notifyScheduled = false;

  PlayerRoutePhase get phase => _phase;

  /// 当前播放页的路由动画；[PlayerRoutePhase.closed] 时为 null。
  ///
  /// **仅供状态机内部核对**（收起是否开始、路由是否栈顶），**不要给渲染层
  /// 消费**：壳层/顶栏必须继续读 `playerRouteAnimationProvider`（由 `PlayerPage`
  /// 帧末写入）。2026-11-17 实测把渲染改成从这里取动画后，打开播放页会出现
  /// 「整窗黑一帧」，恢复 provider 链路即消失。
  Animation<double>? get animation => _animation;

  /// 播放页在栈上（含正在展开 / 正在收起）。
  bool get isOpen => _phase != PlayerRoutePhase.closed;

  // ── 命令（打开 / 关闭触发点）─────────────────────────────────

  /// 打开事件（幂等）。
  ///
  /// - 已在展开 / 已展开：忽略；
  /// - 正在收起：记下请求，路由卸载后自动补发（收起动画期间点封面不能丢）；
  /// - 已关闭：进入 [PlayerRoutePhase.opening] 并 push。
  void open(GoRouter router) {
    switch (_phase) {
      case PlayerRoutePhase.opening:
      case PlayerRoutePhase.open:
        _logIgnored('open', '已在 $phase 阶段');
        return;
      case PlayerRoutePhase.closing:
        _pendingOpen = true;
        _logIgnored('open', '收起中，已排队');
        return;
      case PlayerRoutePhase.closed:
        break;
    }
    _router = router;
    final epoch = ++_epoch;
    // 栈上已经有播放页（例如深链 / 外部导航直接 `go('/player')`，页面还没来得及
    // 上报绑定）：按已绑定动画的状态补齐阶段，绝不再叠加一层播放页。
    if (hasPlayerRouteMatch(router)) {
      final animation = _animation;
      _setPhase(
        animation != null && animation.status == AnimationStatus.completed
            ? PlayerRoutePhase.open
            : PlayerRoutePhase.opening,
        'open：栈上已有播放页',
      );
      _notify();
      // 页面始终没挂载（匹配其实正在移除）时也要能收敛，别停在 opening。
      if (_animation == null) _verifyPushed(router, epoch, 0);
      return;
    }
    _setPhase(PlayerRoutePhase.opening, 'open');
    _notify();
    try {
      unawaited(router.push(kPlayerRoutePath));
    } catch (err, stack) {
      Log.e('player', 'open: push 失败：$err\n$stack');
      _finishClosed();
      return;
    }
    _verifyPushed(router, epoch, 0);
  }

  /// 关闭事件（幂等）。
  void close(GoRouter router) {
    if (_phase != PlayerRoutePhase.opening && _phase != PlayerRoutePhase.open) {
      _logIgnored('close', '不在 opening/open（$phase）');
      return;
    }
    // 播放页不是栈顶（顶上有弹窗 / 对话框）：这次关闭不处理，避免 pop 掉别的页面。
    final route = _route;
    if (route != null && !route.isCurrent) {
      Log.w('player', 'close: 播放页不是栈顶（存在弹窗？），忽略本次关闭');
      return;
    }
    // 状态说开着、栈上却没有（被整栈替换吞掉 / push 从未真正进栈）：
    // 直接收敛为 closed，绝不让「closing 永不结束」把后续打开请求全部吞掉。
    if (!hasPlayerRouteMatch(router)) {
      Log.w('player', 'close: 栈上没有播放页，状态复位为 closed');
      _finishClosed();
      return;
    }
    final epoch = ++_epoch;
    _router = router;
    _setPhase(PlayerRoutePhase.closing, 'close');
    _notify();
    // push 还没被 Navigator 处理时 `canPop()` 仍为 false、`pop()` 会落空：
    // 交给帧末核对去重试，不在这里放弃（否则页面会照常打开，用户以为关不掉）。
    if (router.canPop()) _popOnce(router);
    _verifyPopped(router, epoch, 0);
  }

  /// 切换（快捷键入口）：收起中视为「再打开」，其余按当前阶段取反。
  void toggle(GoRouter router) {
    if (_phase == PlayerRoutePhase.closed ||
        _phase == PlayerRoutePhase.closing) {
      open(router);
    } else {
      close(router);
    }
  }

  // ── 页面事件（由 PlayerPage 回报）────────────────────────────

  /// 页面已绑定自己的路由动画。
  ///
  /// 页面生命周期里调用是安全的（通知走微任务）。若此时状态仍是 closed，
  /// 说明路由不是经 [open] 进来的（启动时深链恢复 / 路由状态还原）：以页面
  /// 上报为准进入 opening，避免壳层永远收不起来。
  void routeAttached(Animation<double> animation, ModalRoute<dynamic>? route) {
    _route = route;
    if (identical(_animation, animation)) return;
    _animation = animation;
    if (_phase == PlayerRoutePhase.closed) {
      // 路由不是经 open() 进来的（启动时深链恢复 / 路由状态还原 /
      // 收起途中的外部导航）：以页面上报为准进入 opening，壳层才能收起。
      _setPhase(PlayerRoutePhase.opening, 'attach（非 open 入口）');
      _pendingOpen = false;
    }
    // closing 时保持 closing：这次挂上来的就是正在收起的那一页（push 与 pop
    // 挤在同一帧时它会晚一帧才构建），pop 的帧末核对会继续收尾。
    _notify();
  }

  /// 进入动画已完成（页面完全展开）。
  void routeOpened(Animation<double> animation) {
    if (!identical(_animation, animation)) return;
    if (_phase != PlayerRoutePhase.opening) return;
    _setPhase(PlayerRoutePhase.open, 'opened');
    _notify();
  }

  /// 收起动画已走完（路由即将卸载）。比 [routeDetached] 更早，作为正常收起的
  /// 主动收尾信号，让收起期间的挂起打开请求尽早补发。
  void routeDismissed(Animation<double> animation) {
    if (!identical(_animation, animation)) return;
    if (_phase != PlayerRoutePhase.closing) return;
    _finishClosed();
  }

  /// 路由已从树上卸载（`PlayerPage.dispose`）。这是「关闭完成」的兜底事件：
  /// 正常 pop、整栈替换（`go()` 丢弃 imperative 匹配）都会走到这里。
  ///
  /// [animation] 为 null 表示该页面没有绑定路由动画；带动画时必须与当前实例
  /// 一致——关闭后迅速重开时旧实例会晚于新实例卸载，不能把新实例的状态清掉。
  void routeDetached(Animation<double>? animation) {
    if (animation != null && !identical(_animation, animation)) return;
    _finishClosed();
  }

  // ── 内部 ────────────────────────────────────────────────────

  /// 阶段切换的唯一写入口。
  ///
  /// debug 下打印一行「阶段迁移 + 原因」：现场复现「卡在某个阶段」时，日志里
  /// 最后一条迁移就是停住的位置（release 不打印，避免刷日志）。
  void _setPhase(PlayerRoutePhase next, String reason) {
    if (_phase == next) return;
    if (kDebugMode) {
      Log.i('player-route', '${_phase.name} → ${next.name}（$reason）');
    }
    _phase = next;
  }

  void _logIgnored(String event, String reason) {
    if (kDebugMode) Log.i('player-route', '忽略 $event：$reason');
  }

  void _notify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  /// 收敛到 closed，并补发收起期间挂起的打开请求。
  void _finishClosed() {
    final changed = _phase != PlayerRoutePhase.closed || _animation != null;
    _setPhase(PlayerRoutePhase.closed, 'finish');
    _animation = null;
    _route = null;
    if (changed) _notify();
    _flushPendingOpen();
  }

  /// 挂起打开的补发间隔上限（帧数）：路由移出导航栈可能比 `routeDetached`
  /// 晚一两帧，见下。
  static const int _maxFlushFrames = 5;

  void _flushPendingOpen([int attempt = 0]) {
    if (!_pendingOpen) return;
    _pendingOpen = false;
    final router = _router;
    if (router == null) return;
    // 卸载事件落在 Navigator 的帧内收尾流程里：push 推迟到帧末，避免在 build
    // 阶段改路由（release 下会被静默丢弃）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_phase != PlayerRoutePhase.closed) return;
      if (hasPlayerRouteMatch(router)) {
        // 路由还没真正移出导航栈（收起动画先走完、卸载慢一两帧）：
        // 有限次重试补发，不能在这里把请求丢掉。
        if (attempt < _maxFlushFrames) {
          _pendingOpen = true;
          _flushPendingOpen(attempt + 1);
        } else {
          Log.w('player', 'open: 挂起的打开请求连续 $_maxFlushFrames 帧未补发，已丢弃');
        }
        return;
      }
      open(router);
    });
    // 挂起请求可能发生在帧末（此时没有待渲染的内容）：显式要一帧，
    // 保证上面的帧末回调一定会执行。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// push 之后核对：路由没进栈、或进了栈但页面迟迟没挂上，都复位为 closed。
  ///
  /// 这几帧核对是**事件收尾的兜底**（不是状态来源）：
  /// - `push` 可能被上游吞掉（路由解析事务被新导航覆盖、`go()` 整栈替换）；
  /// - 路由可能「进栈后立刻被移除」（打开的同时按了 Esc / 点了别的导航），
  ///   页面**从未构建** → 既没有 `routeAttached` 也没有 `routeDetached`，
  ///   只靠事件就会永久停在 opening（之后再按打开会被幂等判定静默吃掉）。
  ///
  /// 页面一旦挂上（[routeAttached]）就停止核对，后续完全由事件驱动。
  static const int _maxPushVerifyFrames = 6;

  void _verifyPushed(GoRouter router, int epoch, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (epoch != _epoch) return;
      if (_phase != PlayerRoutePhase.opening) return;
      if (_animation != null) return; // 页面已挂上，后续交给页面事件
      if (hasPlayerRouteMatch(router)) {
        if (attempt < _maxPushVerifyFrames) {
          _verifyPushed(router, epoch, attempt + 1);
        } else {
          Log.w(
            'player',
            'open: 播放页 $_maxPushVerifyFrames 帧内没有挂载，状态复位为 closed',
          );
          _finishClosed();
        }
        return;
      }
      // 还没进栈：push 的匹配由路由解析在微任务里写入，再等一帧。
      if (attempt < 2) {
        _verifyPushed(router, epoch, attempt + 1);
        return;
      }
      Log.w('player', 'open: 播放页没有进栈，状态复位为 closed（下次点击重试）');
      _finishClosed();
    });
    // 帧末核对必须真的有一帧可跑：push 若被吞掉，本轮可能不会再有人申请帧。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _popOnce(GoRouter router) {
    try {
      router.pop();
    } catch (err, stack) {
      Log.e('player', 'close: pop 失败：$err\n$stack');
      _finishClosed();
    }
  }

  /// pop 之后核对：收起动画没有真正开始就重试 pop。
  ///
  /// 关键场景（快捷键连按）：`push` 还没被 Navigator 处理就 `pop`，页面**从未
  /// 构建**，于是既不会有 `routeAttached`，也不会有 `routeDetached` /
  /// `dismissed` —— 只靠事件收尾就会永久停在 closing，后续打开请求全部挂起，
  /// 表现为「按快捷键快速开关一次，播放页从此打不开 / 界面卡死」。
  ///
  /// 因此这里做有限的帧末核对（最多 [_maxPopRetries] 次）：路由已移出栈 →
  /// 直接收敛；pop 没生效 → 再 pop 一次；始终不生效 → 强制复位并告警。
  static const int _maxPopRetries = 3;

  void _verifyPopped(GoRouter router, int epoch, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (epoch != _epoch) return;
      if (_phase != PlayerRoutePhase.closing) return;
      // 路由已移出导航栈：收起完成（页面可能从未构建，没有事件可等）。
      if (!hasPlayerRouteMatch(router)) {
        _finishClosed();
        return;
      }
      // 收起动画已开始（或已经结束）：正常路径，等 dismissed / detach 事件。
      final status = _animation?.status;
      if (status == AnimationStatus.reverse ||
          status == AnimationStatus.dismissed) {
        return;
      }
      if (attempt >= _maxPopRetries) {
        Log.w('player', 'close: pop 连续 $attempt 次未生效，状态复位为 closed');
        _finishClosed();
        return;
      }
      // 还在处理 push 的帧里 `canPop()` 可能仍为 false：下一帧再试。
      // 只有播放页仍是栈顶时才重新 pop（顶上多了弹窗时不能误 pop）。
      final route = _route;
      if (route == null || route.isCurrent) {
        if (router.canPop()) _popOnce(router);
      }
      _verifyPopped(router, epoch, attempt + 1);
    });
    // 重试必须真的有一帧可跑：pop 落空时本轮可能不会再有人申请帧
    // （否则状态永远停在 closing，后续打开请求全部挂起）。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 测试用：复位进程级状态（单例会跨用例泄漏）。生产路径不调用。
  void resetForTest() {
    _phase = PlayerRoutePhase.closed;
    _animation = null;
    _route = null;
    _router = null;
    _pendingOpen = false;
    _notifyScheduled = false;
  }
}

/// [router] 栈上是否存在全屏播放页（含 shell 内部，递归查找）。
///
/// 只用于**核对**路由动作是否生效（push 被吞 / 栈上没有可关的页面），
/// 不作为「播放页开没开」的状态来源——状态只来自事件（[PlayerRouteController]）。
/// imperative `push` 与普通 `go('/player')` 两种匹配形态都算。
bool hasPlayerRouteMatch(GoRouter router) =>
    _matchContainsPlayer(router.routerDelegate.currentConfiguration.matches);

bool _matchContainsPlayer(List<RouteMatchBase> matches) {
  for (final match in matches) {
    // imperative push 与普通 `go('/player')` 都算（后者是 GoRouteMatch）。
    if (match.matchedLocation == kPlayerRoutePath) return true;
    if (match is ShellRouteMatch && _matchContainsPlayer(match.matches)) {
      return true;
    }
  }
  return false;
}

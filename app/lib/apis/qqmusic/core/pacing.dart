// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQ 音乐请求节奏闸门（限并发 + 最小间隔 + 风控冷却）。
///
/// 实测（2026-11-11，同一出口连打 4 次 `DoSearchForQQMusicDesktop`，间隔 0s）：
/// 前两次正常返回，第 3~4 次全部变成 `inner=2001` / 空结果；静置 ~90s 后
/// 同一 payload 恢复。同类实测里 `code 0 + meta.is_filter<0` 也是同一族。
///
/// 结论：QQ 的账号/出口级限流是**按请求速率**判定的，与接口参数无关。
/// 旧实现每层都各自重试（请求层 2 次 + 搜索层 2 次），一次用户搜索最多能
/// 打出 9 个请求，等于主动撞阈值。因此这里统一做三件事：
///
/// 1. **限并发**：同时在途 ≤ [kQmMaxInFlight]；
/// 2. **最小间隔**：两次出站之间至少 [kQmMinIntervalMs]；
/// 3. **风控冷却**：一旦吃到 risk，全局冷却（逐次翻倍，上限 10 分钟），
///    冷却期内的调用**直接失败不联网**——继续打只会把阈值/处罚刷得更重。
library;

import 'dart:async';

/// 同时在途请求上限。
const int kQmMaxInFlight = 3;

/// 两次出站的最小间隔（毫秒）。
const int kQmMinIntervalMs = 150;

/// 首次风控冷却时长。
const Duration kQmRiskCooldown = Duration(seconds: 60);

/// 冷却时长上限（连续风控时指数退避到这里）。
const Duration kQmRiskCooldownMax = Duration(minutes: 10);

int _inFlight = 0;
int _lastStartMs = 0;
final List<Completer<void>> _waiters = <Completer<void>>[];

/// 连续风控次数（冷却期结束且请求成功后才清零）。
int _riskStreak = 0;

/// 当前冷却截止时间（毫秒；0 = 未冷却）。
int _cooldownUntilMs = 0;

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

Future<void> _sleep(int ms) =>
    ms <= 0 ? Future.value() : Future.delayed(Duration(milliseconds: ms));

void _drainWaiters() {
  while (_inFlight < kQmMaxInFlight && _waiters.isNotEmpty) {
    _waiters.removeAt(0).complete();
  }
}

/// 等待一个出站名额（限并发 + 最小间隔）。返回后必须配对调用 [qmReleaseSlot]。
Future<void> qmAcquireSlot() async {
  while (_inFlight >= kQmMaxInFlight) {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }
  _inFlight++;
  // 最小间隔：串行化出站起点，避免「并发 3 路同刻抵达」被一并计数。
  final wait = _lastStartMs + kQmMinIntervalMs - _nowMs();
  if (wait > 0) await _sleep(wait);
  _lastStartMs = _nowMs();
}

/// 释放出站名额。
void qmReleaseSlot() {
  if (_inFlight > 0) _inFlight--;
  _drainWaiters();
}

/// 走一次「带闸门」的请求：自动获取/释放名额。
Future<T> qmPaced<T>(Future<T> Function() run) async {
  await qmAcquireSlot();
  try {
    return await run();
  } finally {
    qmReleaseSlot();
  }
}

/// 风控冷却剩余时长（≤0 表示可正常请求）。
Duration qmRiskCooldownRemaining({DateTime? now}) {
  final left = _cooldownUntilMs - (now ?? DateTime.now()).millisecondsSinceEpoch;
  return left <= 0 ? Duration.zero : Duration(milliseconds: left);
}

/// 是否处于风控冷却中（此时**不应**发起网络请求）。
bool qmRiskCooling({DateTime? now}) => qmRiskCooldownRemaining(now: now) > Duration.zero;

/// 记录一次风控命中：进入指数冷却。
///
/// 只应由真正的风控信号调用（`inner/outer=2001`、`meta.is_filter<0`、
/// HTTP 429）。普通业务码/网络错误不应调用，否则会把偶发故障放大成
/// 长时间不可用。
Duration qmNoteRisk() {
  _riskStreak = (_riskStreak + 1).clamp(1, 8);
  final factor = 1 << (_riskStreak - 1); // 1,2,4,…,128
  var duration = Duration(
    milliseconds: kQmRiskCooldown.inMilliseconds * factor,
  );
  if (duration > kQmRiskCooldownMax) duration = kQmRiskCooldownMax;
  final until = _nowMs() + duration.inMilliseconds;
  if (until > _cooldownUntilMs) _cooldownUntilMs = until;
  return duration;
}

/// 记录一次成功请求（清空风控连击；冷却需自然到期，不提前解除）。
void qmNoteSuccess() {
  if (!qmRiskCooling()) {
    _riskStreak = 0;
    _cooldownUntilMs = 0;
  }
}

/// 测试用：复位闸门状态。
void qmResetPacing() {
  for (final w in _waiters) {
    if (!w.isCompleted) w.complete();
  }
  _waiters.clear();
  _inFlight = 0;
  _lastStartMs = 0;
  _riskStreak = 0;
  _cooldownUntilMs = 0;
}

/// 测试/诊断用：当前闸门快照。
({int inFlight, int riskStreak, Duration cooldown}) qmPacingSnapshot() => (
  inFlight: _inFlight,
  riskStreak: _riskStreak,
  cooldown: qmRiskCooldownRemaining(),
);

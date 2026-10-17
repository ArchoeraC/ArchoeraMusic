// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 挑战解题的**设备能力自适应**（纯 Dart，按真实解题样本热切）。
///
/// 为什么不用「合成基准」：实测证明短时爆发式 benchmark **测不出真实算力**。
/// 本机（i9-13980HX，24 物理核 / 32 线程，P+E 混合）用 8k 次/worker 的基准时，
/// 31 worker 的聚合吞吐最高；但真实 difficulty=20 解题里 31 worker 反而比 16
/// worker 慢 50 倍（功耗/热限制在几百毫秒内就把频率压下来）。老机器没有
/// SHA-NI / NEON、虚拟机有 CPU 配额、笔记本有功耗墙——**只有真实解题样本才代表
/// 真实算力**。
///
/// 做法（零额外 CPU：不复用解题之外的 benchmark）：
///  - 初始并发取 `min(核数 - 1, 16)`（保守上限，避免超订塌陷）；
///  - 每次真实解题由**胜出的 worker** 回报「试了多少候选 / 自身耗时」，折算成
///    该档位的**聚合吞吐**样本（per-worker 速率 × 并发数）；
///  - 判据必须是聚合吞吐而不是单 worker 速率：并发越低，单 worker 争用越少、
///    速率天然越高（实测 12w 的单 worker 速率比 16w 高 14%，但总吞吐仍低），
///    只比单 worker 速率会一路降到 1；
///  - 策略是**双向爬坡**：先用当前档采样，再试相邻档（先向下，收敛后周期性向上
///    复核）；相邻档的聚合吞吐高出 15% 才切换。健康机器只多花 1 次解题，之后每
///    16 次解题才复核一次；明显更差的向上档位会被拉黑，不再反复试探。
///
/// 未来引入原生 SHA-NI / NEON 后端（混合模块）时，在同一处用同一套 per-worker
/// 速率样本与 Dart 后端比较择优即可——本类是唯一的决策点。
library;

import 'dart:io';

/// 低于该难度不启用多 isolate：`2^16 = 65536` 次哈希在单核上是毫秒级，
/// 开 worker 的 spawn / 消息开销反而更大。
const int kNekoPowParallelMinBits = 16;

/// 每个 worker 至少分摊的候选数（低于此值 spawn 开销不划算，减少 worker 数）。
const int _kHashesPerWorkerBudget = 8192;

/// 并发候选梯度（按核数裁剪；上限 16 —— 更高只会触发功耗/热塌陷）。
const List<int> _kLadder = [1, 2, 3, 4, 6, 8, 12, 16];

/// per-worker 速率的指数滑动平均系数（命中位置是几何分布，单样本噪声大）。
const double _kEmaAlpha = 0.4;

/// 相邻档的聚合吞吐高出该比例才切换（避免在噪声里来回跳）。
const double _kSwitchMargin = 1.15;

/// 已收敛后每隔多少次解题向上复核一次（跟踪热状态恢复 / 负载下降）。
const int _kReProbeEvery = 16;

/// 设备解题能力自适应器（进程内单例）。
class NekoPowTuning {
  NekoPowTuning._();

  static final NekoPowTuning instance = NekoPowTuning._();

  /// 各档**聚合吞吐**的 EMA（candidates/s = per-worker 速率 × 并发数）。
  final Map<int, double> _rate = {};

  /// 各档样本数。
  final Map<int, int> _samples = {};

  int? _workers;

  /// 正在试探的相邻档；null = 无（已收敛或尚无样本）。
  int? _probe;

  /// 试探前的当前档（回退用）。
  int? _previous;

  /// 试探方向：-1 向下（减少并发）/ +1 向上（复核）。
  int _direction = -1;

  /// 是否已收敛（等待下一次向上复核）。
  bool _settled = false;

  /// 收敛后已过的解题次数（到 [_kReProbeEvery] 复核一次向上档位）。
  int _sinceSettle = 0;

  /// 拉黑的档位（向上试探明显更差，不再反复试）。
  final Set<int> _blocked = {};

  /// 测试接缝：覆盖梯度（默认按核数裁剪）。
  List<int>? debugLadder;

  /// 测试接缝：直接指定当前档位。
  void debugSetWorkers(int? workers) {
    _workers = workers;
    _probe = null;
    _previous = null;
    _direction = -1;
    _settled = false;
    _sinceSettle = 0;
  }

  /// 测试接缝：清空学习状态。
  void debugReset() {
    _rate.clear();
    _samples.clear();
    _blocked.clear();
    _workers = null;
    _probe = null;
    _previous = null;
    _direction = -1;
    _settled = false;
    _sinceSettle = 0;
    debugLadder = null;
  }

  /// 当前采用的并发数（未学习时为启发式上限）。
  int get workers => _workers ??= _ladder().last;

  /// 是否已收敛（不再试探）。
  bool get settled => _settled;

  /// 下一轮将使用的并发数（= 当前档，或正在试探的低档；诊断 / 基准用）。
  int get plannedWorkers => _probe ?? workers;

  /// 已学习的档位聚合吞吐（诊断）。
  Map<int, double> get learnedRates => Map.unmodifiable(_rate);

  /// 按难度选择本次解题的 worker 数。
  int workersFor(int difficulty) {
    if (difficulty < kNekoPowParallelMinBits) return 1;
    final ceiling = plannedWorkers;
    if (ceiling <= 1) return 1;
    // 期望命中数 ≈ 2^difficulty（≥ 2^40 视为超大，直接用满上限）。
    final expected = difficulty >= 40 ? (1 << 40) : (1 << difficulty);
    final byWork = (expected / _kHashesPerWorkerBudget).ceil();
    return byWork.clamp(1, ceiling);
  }

  /// 记录一次**真实解题**样本：该并发档下，胜出 worker 试了 [candidates] 个候选、
  /// 自身耗时 [elapsed]（不含 spawn）。
  ///
  /// 记账用**聚合吞吐**（`胜出 worker 速率 × 并发数`）：解题期望耗时 ∝ 聚合吞吐，
  /// 而单 worker 速率会随并发降低（争用少），不能单独用来比档位。
  void record({
    required int workers,
    required int candidates,
    required Duration elapsed,
  }) {
    final micros = elapsed.inMicroseconds;
    if (workers <= 1 || candidates <= 0 || micros <= 0) return;
    final rate = candidates / (micros / 1e6) * workers;
    final previous = _rate[workers];
    _rate[workers] = previous == null
        ? rate
        : previous + (rate - previous) * _kEmaAlpha;
    _samples[workers] = (_samples[workers] ?? 0) + 1;
    _advance(workers);
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  void _advance(int sampled) {
    final ladder = _ladder();
    if (!ladder.contains(workers)) {
      _workers = _nearest(ladder, workers);
      _probe = null;
      _previous = null;
    }

    // 1) 试探样本到齐：比较聚合吞吐，决定采纳 / 回退并收敛。
    final probe = _probe;
    if (probe != null && sampled == probe) {
      final probeRate = _rate[probe];
      final previousRate = _rate[_previous ?? workers];
      if (probeRate != null &&
          previousRate != null &&
          probeRate > previousRate * _kSwitchMargin) {
        // 更快 → 采纳，沿同方向继续探下一档。
        _workers = probe;
        _previous = probe;
        final next = _rung(ladder, probe, _direction);
        if (next == null || _blocked.contains(next)) {
          _probe = null;
          _settled = true;
          _sinceSettle = 0;
        } else {
          _probe = next;
        }
        return;
      }
      // 没有更快 → 回退收敛；向上试探明显更差的档位拉黑（避免反复试探）。
      if (_direction > 0 &&
          probeRate != null &&
          previousRate != null &&
          probeRate < previousRate * 0.5) {
        _blocked.add(probe);
      }
      _workers = _previous ?? workers;
      _probe = null;
      _previous = null;
      _settled = true;
      _sinceSettle = 0;
      return;
    }

    if (_probe != null) return; // 等试探样本

    // 2) 尚未收敛且当前档已有样本 → 先向下试一档。
    if (!_settled) {
      if (!_rate.containsKey(workers)) return;
      final lower = _rung(ladder, workers, -1);
      if (lower == null) {
        _settled = true;
        return;
      }
      _direction = -1;
      _previous = workers;
      _probe = lower;
      return;
    }

    // 3) 已收敛 → 每 [_kReProbeEvery] 次解题向上复核一次（热状态可能恢复）。
    _sinceSettle++;
    if (_sinceSettle < _kReProbeEvery) return;
    _sinceSettle = 0;
    final higher = _rung(ladder, workers, 1);
    if (higher == null || _blocked.contains(higher)) return;
    _direction = 1;
    _previous = workers;
    _probe = higher;
    _settled = false;
  }

  int? _rung(List<int> ladder, int current, int direction) {
    final index = ladder.indexOf(current);
    if (index < 0) return null;
    final next = index + direction;
    if (next < 0 || next >= ladder.length) return null;
    return ladder[next];
  }

  /// 可用并发梯度：按核数裁剪，**上限 16**（更高只会超订塌陷）。
  List<int> _ladder() {
    final override = debugLadder;
    if (override != null) return override;
    final cap = (Platform.numberOfProcessors - 1).clamp(1, 16);
    final rungs = <int>{
      for (final rung in _kLadder)
        if (rung <= cap) rung,
      cap,
    }.toList()..sort();
    return rungs;
  }

  static int _nearest(List<int> ladder, int value) {
    var best = ladder.first;
    for (final rung in ladder) {
      if ((rung - value).abs() < (best - value).abs()) best = rung;
    }
    return best;
  }
}

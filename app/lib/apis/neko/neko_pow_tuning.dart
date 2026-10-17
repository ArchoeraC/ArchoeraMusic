// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 挑战解题的**设备能力负反馈自适应**（纯 Dart，按真实解题样本热切）。
///
/// 为什么不用「合成基准」：实测证明短时爆发式 benchmark **测不出真实算力**。
/// 本机（i9-13980HX，24 物理核 / 32 线程，P+E 混合）用 8k 次/worker 的基准时，
/// 31 worker 的聚合吞吐最高；但真实 difficulty=20 解题里 31 worker 反而比 16
/// worker 慢 50 倍（功耗/热限制在几百毫秒内就把频率压下来）。老机器没有
/// SHA-NI / NEON、虚拟机有 CPU 配额、笔记本有功耗墙——**只有真实解题样本才代表
/// 真实算力**。
///
/// 控制环（**负反馈 + 双向试探**，不做永久拉黑）：
///
///  1. **误差驱动（负反馈）**：每次真实解题由胜出 worker 回报「试了多少候选 /
///     自身耗时」，折算该档位的**聚合吞吐**（per-worker 速率 × 并发）。当前档位的
///     EMA 掉到「已知最佳档」的 75% 以下 → **立即**切到最佳档，不等周期。
///     降档、以及「能力恢复后立刻抓住」都靠这条误差项。
///  2. **周期试探（探索）**：每 [ _kProbeEvery ] 次解题试一次相邻档（优先升档，
///     升档在冷却中则试降档）；相邻档聚合吞吐高出 15% 才采纳，否则回退。
///  3. **冷却而非拉黑**：试探失败只让该档位冷却若干次解题（失败次数越多冷却越久，
///     上限 128 次）——**设备更换 / 换电源 / 散热恢复后仍会再试**，不会永久锁在
///     低档位。
///  4. **升档永远保留**：误差项与周期试探都会向上；只要设备真的变快，就会爬回去。
///
/// 判据必须是**聚合吞吐**：并发越低争用越少、单 worker 速率天然更高（实测 12w 的
/// 单 worker 速率比 16w 高 14%，但总吞吐更低），只比单 worker 速率会一路降到 1。
///
/// 未来引入原生 SHA-NI / NEON 后端（混合模块）时，在同一处用同一套样本与 Dart
/// 后端比较择优即可——本类是唯一的决策点。
library;

import 'dart:io';

/// 低于该难度不启用多 isolate：`2^16 = 65536` 次哈希在单核上是毫秒级，
/// 开 worker 的 spawn / 消息开销反而更大。
const int kNekoPowParallelMinBits = 16;

/// 每个 worker 至少分摊的候选数（低于此值 spawn 开销不划算，减少 worker 数）。
const int _kHashesPerWorkerBudget = 8192;

/// 并发候选梯度（按核数裁剪；上限 16 —— 更高只会触发功耗/热塌陷）。
const List<int> _kLadder = [1, 2, 3, 4, 6, 8, 12, 16];

/// 聚合吞吐的 EMA 系数：上升快抓（能力恢复立刻反映），下降慢判（避免被单个
/// 慢样本带偏）。命中位置是几何分布，单样本噪声大。
const double _kEmaAlphaUp = 0.7;
const double _kEmaAlphaDown = 0.3;

/// 试探档聚合吞吐高出当前该比例才**进入试用**。
///
/// 每成功升一档，门槛再抬高 10%（上限 1.5）——越接近峰值，边际收益越小、
/// 断崖风险越大（P 核→E 核、功耗墙），涨得不够多就不该继续往上爬。
const double _kSwitchMargin = 1.15;

/// 试用期样本数：进入试用后连续采样这么多次再裁决（单次样本不可信）。
const int _kTrialSolves = 2;

/// 试用期平均吞吐高出「升档前档位」该比例才正式采纳（否则回退并惩罚该档）。
const double _kTrialMargin = 1.10;

/// 负反馈阈值：当前档 EMA 低于「最佳档」该比例 → 立即切换到最佳档。
const double _kFeedbackRatio = 0.75;

/// 每多少次解题做一次相邻档试探。
const int _kProbeEvery = 8;

/// 试探失败的冷却基数（第 1 次失败冷却 8 次解题，之后翻倍）。
const int _kCooldownBase = 8;

/// 冷却上限（再长的冷却对「设备变化」就不够灵敏了）。
const int _kCooldownMax = 128;

/// 设备解题能力自适应器（进程内单例）。
class NekoPowTuning {
  NekoPowTuning._();

  static final NekoPowTuning instance = NekoPowTuning._();

  /// 各档聚合吞吐 EMA（candidates/s）。
  final Map<int, double> _ema = {};

  /// 已完成的解题次数（冷却 / 试探计时用）。
  int _solves = 0;

  int? _workers;

  /// 正在试探的档位与试探前的档位（-1 = 向下，+1 = 向上）。
  int? _probe;
  int? _probeFrom;

  /// 上次试探结束时的解题计数。
  int _lastProbeAt = 0;

  /// 各档试探失败次数与冷却截止计数。
  final Map<int, int> _failures = {};
  final Map<int, int> _cooldownUntil = {};

  /// 试用期：进入试用后先用 [_kTrialSolves] 次真实解题确认，再决定采纳 / 回退。
  int? _trial;
  int? _trialFrom;
  double _trialBaseline = 0;
  double _trialSum = 0;
  int _trialSamples = 0;

  /// 连续成功升档次数（每多一次，下一次升档门槛抬高 10%）。
  int _consecutiveUp = 0;

  /// 测试接缝：覆盖梯度（默认按核数裁剪）。
  List<int>? debugLadder;

  /// 测试接缝：直接指定当前档位并清空试探状态。
  void debugSetWorkers(int? workers) {
    _workers = workers;
    _probe = null;
    _probeFrom = null;
    _trial = null;
    _trialFrom = null;
    _trialSamples = 0;
    _trialSum = 0;
    _consecutiveUp = 0;
    _lastProbeAt = 0;
  }

  /// 测试接缝：清空全部学习状态。
  void debugReset() {
    _ema.clear();
    _failures.clear();
    _cooldownUntil.clear();
    _trial = null;
    _trialFrom = null;
    _trialSamples = 0;
    _trialSum = 0;
    _consecutiveUp = 0;
    _solves = 0;
    debugSetWorkers(null);
    debugLadder = null;
  }

  /// 当前采用的并发数（未学习时为启发式上限）。
  int get workers => _workers ??= _ladder().last;

  /// 下一轮将使用的并发数（正在试探时 = 试探档；诊断 / 基准用）。
  int get plannedWorkers => _probe ?? workers;

  /// 是否正在试探相邻档（单次采样）。
  bool get probing => _probe != null;

  /// 是否处于试用期（已切到候选档，正在二次确认）。
  bool get trialing => _trial != null;

  /// 已学习的聚合吞吐（诊断）。
  Map<int, double> get learnedRates => Map.unmodifiable(_ema);

  /// 各档冷却剩余解题次数（诊断）。
  Map<int, int> get cooldownRemaining => {
    for (final entry in _cooldownUntil.entries)
      if (entry.value > _solves) entry.key: entry.value - _solves,
  };

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
  /// 记账用**聚合吞吐**（`胜出 worker 速率 × 并发数`）：解题期望耗时 ∝ 聚合吞吐。
  void record({
    required int workers,
    required int candidates,
    required Duration elapsed,
  }) {
    final micros = elapsed.inMicroseconds;
    if (workers <= 1 || candidates <= 0 || micros <= 0) return;
    final sample = candidates / (micros / 1e6) * workers;
    final previous = _ema[workers];
    final alpha = previous == null || sample > previous
        ? _kEmaAlphaUp
        : _kEmaAlphaDown;
    _ema[workers] = previous == null
        ? sample
        : previous + (sample - previous) * alpha;
    _solves++;
    _control(workers, sample);
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  void _control(int sampled, double sample) {
    final ladder = _ladder();
    if (!ladder.contains(workers)) {
      _workers = _nearest(ladder, workers);
      _probe = null;
      _probeFrom = null;
    }

    // 1) 试用期：只收集候选档的原始样本，攒够 [_kTrialSolves] 次再裁决。
    final trial = _trial;
    if (trial != null) {
      if (sampled == trial) {
        _trialSum += sample;
        _trialSamples++;
      }
      if (_trialSamples >= _kTrialSolves) {
        final average = _trialSum / _trialSamples;
        if (average > _trialBaseline * _kTrialMargin) {
          // 二次确认通过：正式采纳，连续升档计数 +1（下次门槛更高）。
          _workers = trial;
          _consecutiveUp++;
          _failures.remove(trial);
          _cooldownUntil.remove(trial);
        } else {
          // 只是短时爆发（或样本噪声）：回退并惩罚该档，避免反复爬上来。
          _workers = _trialFrom ?? _workers;
          _penalize(trial);
        }
        _trial = null;
        _trialFrom = null;
        _trialSamples = 0;
        _trialSum = 0;
        _lastProbeAt = _solves;
      }
      return;
    }

    // 2) 单次探测样本到齐：过了门槛就**进入试用**（不直接采纳）。
    final probe = _probe;
    if (probe != null && sampled == probe) {
      final probeRate = _ema[probe];
      final fromRate = _ema[_probeFrom ?? workers];
      if (probeRate != null &&
          fromRate != null &&
          probeRate > fromRate * _requiredMargin) {
        _trial = probe;
        _trialFrom = _probeFrom ?? workers;
        _trialBaseline = fromRate;
        _trialSamples = 0;
        _trialSum = 0;
        _workers = probe; // 试用期直接用它跑（样本即试用数据）
      } else {
        _workers = _probeFrom ?? workers;
        _penalize(probe);
        _lastProbeAt = _solves;
      }
      _probe = null;
      _probeFrom = null;
      return;
    }
    if (_probe != null) return; // 还在等探测样本

    // 3) 负反馈：当前档掉到「最佳档」的 75% 以下 → 立即切过去。
    //    若是**向下**切，说明当前档不可持续 → 惩罚它（冷却 + 清零连续升档计数），
    //    否则「升档成功 → 撑不住 → 降档 → 又爬上去」会反复踩断崖。
    final best = _bestRung(ladder);
    final currentRate = _ema[workers];
    if (best != null &&
        best != workers &&
        currentRate != null &&
        _ema[best]! > currentRate / _kFeedbackRatio) {
      if (best < workers) {
        _penalize(workers);
      } else {
        _consecutiveUp = 0;
      }
      _workers = best;
      _lastProbeAt = _solves;
      return;
    }

    // 4) 周期试探：优先升档（升档能力永久保留，热恢复/换机后可爬回）；
    //    只有「当前档是已测最高档、且从未测过更低档」时才向下探一次建立对照。
    if (_solves - _lastProbeAt < _kProbeEvery) return;
    final target = _probeTarget(ladder);
    if (target == null) return;
    _probe = target;
    _probeFrom = workers;
    _lastProbeAt = _solves;
  }

  /// 下一个升档所需门槛：越接近峰值要求越高（连续成功升档时逐次 +10%，上限 1.5）。
  double get _requiredMargin =>
      (_kSwitchMargin + 0.10 * _consecutiveUp).clamp(_kSwitchMargin, 1.5);

  /// 惩罚某档（试探失败 / 试用不达标 / 降档时发现不可持续）：冷却 + 清零升档计数。
  void _penalize(int rung) {
    _failures[rung] = (_failures[rung] ?? 0) + 1;
    final cooldown = (_kCooldownBase << (_failures[rung]! - 1))
        .clamp(_kCooldownBase, _kCooldownMax);
    _cooldownUntil[rung] = _solves + cooldown;
    _consecutiveUp = 0;
  }

  /// 试探目标：**优先升档**（升档能力永久保留，热恢复/换机后可爬回）；
  /// 只有「当前档是已测最高档、且从未测过更低档」时才向下探一次以建立对照
  /// （之后的降档由负反馈用已有数据触发，不必反复试探、零额外开销）。
  int? _probeTarget(List<int> ladder) {
    final index = ladder.indexOf(workers);
    if (index < 0) return null;
    if (index + 1 < ladder.length) {
      final up = ladder[index + 1];
      if (!_coolingDown(up)) return up;
    }
    if (!_hasLowerMeasurement(ladder, index)) {
      final down = ladder[index - 1];
      if (!_coolingDown(down)) return down;
    }
    return null;
  }

  /// 当前档以下是否已有测量数据（决定还要不要向下探一次）。
  bool _hasLowerMeasurement(List<int> ladder, int index) {
    for (var i = 0; i < index; i++) {
      if (_ema.containsKey(ladder[i])) return true;
    }
    return false;
  }

  bool _coolingDown(int rung) => (_cooldownUntil[rung] ?? 0) > _solves;

  int? _bestRung(List<int> ladder) {
    int? best;
    var bestRate = 0.0;
    for (final rung in ladder) {
      final rate = _ema[rung];
      if (rate != null && rate > bestRate) {
        bestRate = rate;
        best = rung;
      }
    }
    return best;
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

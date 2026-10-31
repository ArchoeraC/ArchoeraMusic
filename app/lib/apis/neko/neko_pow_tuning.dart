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
/// 控制策略（**负反馈 + 门槛惩罚，无冷却/无拉黑**）：
///
///  1. **误差驱动（负反馈）**：每次真实解题由胜出 worker 回报「试了多少候选 /
///     自身耗时」，折算该档位的**聚合吞吐**（per-worker 速率 × 并发）。当前档位
///     掉到「已知最佳档」的 75% 以下 → **立即**切到最佳档。
///  2. **升档二次确认**：单次探测「看起来更快」只进入**试用**（切过去跑 2 次真实
///     解题），试用平均吞吐仍高出升档前档位 10% 才正式采纳；否则回退。
///  3. **门槛惩罚（唯一的"记住"机制）**：某档位**被负反馈降过 2 次**（说明升上去
///     也撑不住，典型是峰值后的断崖：P 核→E 核 / 功耗墙），之后**升回该档的门槛
///     提高 50%**（15% → 22.5%）；不设冷却、不拉黑——设备更换 / 换电源 / 散热恢复
///     后只要涨得足够多，随时能再升回去。
///  4. **连续升档递增**：每连续成功升一档，下一次升档门槛 +10 个百分点（上限 100%），
///     越接近峰值越难继续爬。
///  5. **周期探测**：每 8 次解题探测一次相邻升档（升档能力永久保留）；只有「当前已
///     是已测最高档、且从未测过更低档」时才向下探一次以建立对照。
///
/// 判据必须是**聚合吞吐**：并发越低争用越少、单 worker 速率天然更高（实测 12w 的
/// 单 worker 速率比 16w 高 14%，但总吞吐更低），只比单 worker 速率会一路降到 1。
///
/// 未来引入原生 SHA-NI / NEON 后端（混合模块）时，在同一处用同一套样本与 Dart
/// 后端比较择优即可——本类是唯一的决策点。
library;

import 'dart:convert';
import 'dart:io';

import '../../stores/data_dir.dart';
import '../../utils/safe_file.dart';

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

/// 升档基础门槛：探测档聚合吞吐需高出当前档 15%。
const double _kBaseGain = 0.15;

/// 连续成功升档时，每次额外提高的门槛（百分点）。
const double _kUpGainStep = 0.10;

/// 升档门槛上限（100%：涨一倍才值得继续爬）。
const double _kMaxGain = 1.0;

/// 「被负反馈降档」达到该次数后，升回该档的门槛按 [_kPenaltyScale] 抬高。
const int _kDemotionsForPenalty = 2;

/// 门槛抬高倍数（用户要求：提升 50%）。
const double _kPenaltyScale = 1.5;

/// 试用期样本数：进入试用后连续采样这么多次再裁决（单次样本不可信）。
const int _kTrialSolves = 2;

/// 试用期平均吞吐需高出升档前档位的比例（正式采纳门槛）。
const double _kTrialGain = 0.10;

/// 负反馈阈值：当前档 EMA 低于「最佳档」该比例 → 立即切换到最佳档。
const double _kFeedbackRatio = 0.75;

/// 每多少次解题做一次相邻档探测。
const int _kProbeEvery = 8;

/// 调优结果文件名（落在应用数据目录；只存档位 + 设备指纹）。
const String _kCacheFileName = 'neko_pow_workers.json';

/// 设备能力缓存：**只记档位与设备指纹**，不记任何惩罚 / 降档历史。
class NekoPowSaved {
  const NekoPowSaved({
    required this.workers,
    required this.cores,
    required this.os,
  });

  final int workers;
  final int cores;
  final String os;
}

/// 调优结果持久化后端（默认落盘到数据目录；测试可注入内存实现）。
abstract class NekoPowStore {
  NekoPowSaved? read();
  void write(NekoPowSaved value);
}

/// 默认实现：`<数据目录>/neko_pow_workers.json`，安全读 + 原子写。
///
/// 读失败 / 字段缺失 / 版本不符一律当作「无缓存」（不阻断解题）。
class FileNekoPowStore implements NekoPowStore {
  const FileNekoPowStore();

  static const int _version = 1;

  String get _path => '${resolveDataDir()}/$_kCacheFileName';

  @override
  NekoPowSaved? read() {
    try {
      final text = SafeFile.readString(_path);
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      if (decoded['version'] != _version) return null;
      final workers = decoded['workers'];
      final cores = decoded['cores'];
      final os = decoded['os'];
      if (workers is! int || cores is! int || os is! String) return null;
      return NekoPowSaved(workers: workers, cores: cores, os: os);
    } catch (_) {
      return null;
    }
  }

  @override
  void write(NekoPowSaved value) {
    try {
      SafeFile.writeAtomicString(
        _path,
        jsonEncode({
          'version': _version,
          'workers': value.workers,
          'cores': value.cores,
          'os': value.os,
        }),
      );
    } catch (_) {
      // 写失败不影响本进程的调优（只丢缓存）。
    }
  }
}

/// 设备解题能力自适应器（进程内单例）。
class NekoPowTuning {
  NekoPowTuning._();

  static final NekoPowTuning instance = NekoPowTuning._();

  /// 各档聚合吞吐 EMA（candidates/s）。
  final Map<int, double> _ema = {};

  /// 各档「被负反馈降档」的次数（≥ [_kDemotionsForPenalty] 后升回门槛 ×1.5）。
  final Map<int, int> _demotions = {};

  /// 已完成的解题次数（探测节奏用）。
  int _solves = 0;

  int? _workers;

  /// 正在探测的档位与探测前的档位。
  int? _probe;
  int? _probeFrom;

  /// 上次探测结束时的解题计数。
  int _lastProbeAt = 0;

  /// 试用期：进入试用后先用 [_kTrialSolves] 次真实解题确认，再决定采纳 / 回退。
  int? _trial;
  int? _trialFrom;
  double _trialBaseline = 0;
  double _trialSum = 0;
  int _trialSamples = 0;

  /// 连续成功升档次数（每多一次，下一次升档门槛提高 10 个百分点）。
  int _consecutiveUp = 0;

  /// 测试接缝：覆盖梯度（默认按核数裁剪）。
  List<int>? debugLadder;

  /// 测试接缝：注入持久化后端（默认落盘到数据目录）。
  NekoPowStore? debugStore;

  /// 是否已尝试从缓存恢复初始档位（进程内只做一次）。
  bool _restored = false;

  /// 测试接缝：直接指定当前档位并清空探测 / 试用状态。
  void debugSetWorkers(int? workers) {
    _workers = workers;
    _restored = true;
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
    _demotions.clear();
    _solves = 0;
    _workers = null;
    _restored = false;
    _probe = null;
    _probeFrom = null;
    _trial = null;
    _trialFrom = null;
    _trialSamples = 0;
    _trialSum = 0;
    _consecutiveUp = 0;
    _lastProbeAt = 0;
    debugLadder = null;
  }

  /// 当前采用的并发数：优先用上次落盘的「已测最优档」，否则启发式上限。
  ///
  /// 缓存只含档位与设备指纹（核数 / OS）；指纹不符（换机器 / 虚拟机改配额）视为
  /// 无缓存，直接按启发式重新收敛。**惩罚 / 降档历史不落盘**，每次启动都是干净的。
  int get workers {
    if (_workers != null) return _workers!;
    _restore();
    return _workers ??= _ladder().last;
  }

  void _restore() {
    if (_restored) return;
    _restored = true;
    final saved = (debugStore ?? const FileNekoPowStore()).read();
    if (saved == null) return;
    if (saved.cores != Platform.numberOfProcessors ||
        saved.os != Platform.operatingSystem) {
      return; // 设备指纹不符：不沿用旧档位
    }
    final ladder = _ladder();
    _workers = _nearest(ladder, saved.workers.clamp(ladder.first, ladder.last));
  }

  /// 切换当前档位并落盘。
  ///
  /// [persistIfSame] 用于「试用期已临时切到该档」的情形：采纳时档位没变，但
  /// **必须**落盘（试用期不落盘，只有确认通过才算「已测最优」）。
  void _setWorkers(int value, {bool persistIfSame = false}) {
    final changed = _workers != value;
    _workers = value;
    if (!changed && !persistIfSame) return;
    try {
      (debugStore ?? const FileNekoPowStore()).write(
        NekoPowSaved(
          workers: value,
          cores: Platform.numberOfProcessors,
          os: Platform.operatingSystem,
        ),
      );
    } catch (_) {
      // 落盘失败不影响本进程调优。
    }
  }

  /// 下一轮将使用的并发数（探测 / 试用中 = 对应档位；诊断 / 基准用）。
  int get plannedWorkers => _probe ?? workers;

  /// 是否正在探测相邻档。
  bool get probing => _probe != null;

  /// 是否处于试用期（已切到候选档，正在二次确认）。
  bool get trialing => _trial != null;

  /// 已学习的聚合吞吐（诊断）。
  Map<int, double> get learnedRates => Map.unmodifiable(_ema);

  /// 各档被负反馈降档的次数（诊断）。
  Map<int, int> get demotions => Map.unmodifiable(_demotions);

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
        if (average > _trialBaseline * (1 + _trialGainFor(trial))) {
          // 二次确认通过：正式采纳，连续升档计数 +1（下次门槛更高）。
          _setWorkers(trial, persistIfSame: true);
          _consecutiveUp++;
        } else {
          // 只是短时爆发 / 噪声：回退（不计入「负反馈降档」）。
          _setWorkers(_trialFrom ?? workers);
        }
        _trial = null;
        _trialFrom = null;
        _trialSamples = 0;
        _trialSum = 0;
        _lastProbeAt = _solves;
      }
      return;
    }

    // 2) 单次探测样本到齐：过了该档门槛就进入试用（不直接采纳）。
    final probe = _probe;
    if (probe != null && sampled == probe) {
      // 用**本次原始样本**判断该档「现在」是否值得试：EMA 在塌陷/恢复时有滞后，
      // 拿它当探针值会过度保守（恢复后要很多次才爬得回去）。
      final fromRate = _ema[_probeFrom ?? workers];
      if (fromRate != null &&
          sample > fromRate * (1 + _requiredGainFor(probe))) {
        _trial = probe;
        _trialFrom = _probeFrom ?? workers;
        _trialBaseline = fromRate;
        _trialSamples = 0;
        _trialSum = 0;
        _workers = probe; // 试用期直接用它跑（样本即试用数据），落盘等确认通过后
      } else {
        _setWorkers(_probeFrom ?? workers);
      }
      _probe = null;
      _probeFrom = null;
      _lastProbeAt = _solves;
      return;
    }
    if (_probe != null) return; // 还在等探测样本

    // 3) 负反馈：当前档掉到「最佳档」的 75% 以下 → 立即切过去。
    //    若是**向下**切，说明当前档不可持续 → 记一次「被负反馈降档」，
    //    达到 2 次后升回该档的门槛提高 50%（不设冷却 / 不拉黑）。
    final best = _bestRung(ladder);
    final currentRate = _ema[workers];
    if (best != null &&
        best != workers &&
        currentRate != null &&
        _ema[best]! > currentRate / _kFeedbackRatio) {
      if (best < workers) {
        _demotions[workers] = (_demotions[workers] ?? 0) + 1;
        _consecutiveUp = 0;
      } else {
        _consecutiveUp = 0;
      }
      _setWorkers(best);
      _lastProbeAt = _solves;
      return;
    }

    // 4) 周期探测：优先升档（升档能力永久保留，热恢复 / 换机后可爬回）；
    //    只有「当前档是已测最高档、且从未测过更低档」时才向下探一次建立对照。
    if (_solves - _lastProbeAt < _kProbeEvery) return;
    final target = _probeTarget(ladder);
    if (target == null) return;
    _probe = target;
    _probeFrom = workers;
    _lastProbeAt = _solves;
  }

  /// 目标档的升档门槛（超出当前档的比例，0.15 = 15%）。
  ///
  /// 基础 15%；每连续成功升一档 +10 个百分点；该档被负反馈降过 2 次则再 ×1.5
  /// （用户要求：门槛提升 50%）；上限 100%。
  double _requiredGainFor(int rung) {
    var gain = _kBaseGain + _kUpGainStep * _consecutiveUp;
    if ((_demotions[rung] ?? 0) >= _kDemotionsForPenalty) {
      gain *= _kPenaltyScale;
    }
    return gain.clamp(_kBaseGain, _kMaxGain);
  }

  /// 试用期采纳门槛（同样对「被降过 2 次」的档位抬高）。
  double _trialGainFor(int rung) {
    final gain = _kTrialGain *
        ((_demotions[rung] ?? 0) >= _kDemotionsForPenalty ? _kPenaltyScale : 1);
    return gain.clamp(_kTrialGain, _kMaxGain);
  }

  /// 探测目标：**优先升档**；只有「当前档是已测最高档、且从未测过更低档」时
  /// 才向下探一次以建立对照（之后的降档由负反馈用已有数据触发）。
  int? _probeTarget(List<int> ladder) {
    final index = ladder.indexOf(workers);
    if (index < 0) return null;
    if (index + 1 < ladder.length) return ladder[index + 1];
    if (!_hasLowerMeasurement(ladder, index)) {
      return index - 1 >= 0 ? ladder[index - 1] : null;
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

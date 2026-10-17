// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 请求防重放的**挑战题解题**（领取 nonce 的前置计算）。
///
/// 服务端自「领取 nonce 必须携带挑战」起，`GET /api/replay/nonce` 不再接受裸领取：
/// 客户端必须先 `GET /api/replay/challenge` 换题、按 `sha256-leading-zero-bits`
/// 解出 `proof`，再带 `challenge` / `proof` 兑换 nonce。
///
/// 协议（与官方 PC 端 `ReplayNonceStore::solveProof` 一致，**proof 语义不变**）：
/// 找一个十进制计数器，使 `SHA-256(seed + ":" + counter)` 的前导零比特数达到
/// `difficulty`，把该计数器的十进制字符串作为 `proof`。服务端只验一次哈希，
/// 客户端要试 `2^difficulty` 量级次——这种成本不对称正是该方案的基础。
///
/// 本地加速（不改协议、不改提交的 proof 形态）：
///  - **前缀哈希**：`seed + ":"` 的完整块只压一次（midstate），逐候选只压尾部
///    1–2 块且零分配（见 [NekoPowHasher]）；
///  - **多 isolate 并行**：按 `counter ≡ i (mod N)` 切分候选空间，先解出者胜，
///    其余 worker 立即 kill；N 按核数封顶并给音频/UI 留一个核；
///  - **低难度不并行**：`2^difficulty` 很小时 spawn 开销大于收益，仍走单 isolate。
///
/// 两者叠加把「几十万～上千万次哈希」从秒级压到几十毫秒级（本机 32 核实测见
/// `tool/neko_pow_bench.dart`）。
library;

import 'dart:isolate';

import 'neko_pow_sha256.dart';
import 'neko_pow_tuning.dart';

export 'neko_pow_tuning.dart' show kNekoPowParallelMinBits;

/// 已支持的解题算法标识；换题响应里的 `algorithm` 必须与之一致，否则不盲解。
const String kNekoPowAlgorithm = 'sha256-leading-zero-bits';

/// 难度上限：服务端远低于此值，仅防止异常输入把后台 isolate 空转卡死。
const int kNekoMaxDifficultyBits = 64;

/// 并行 worker 的**启发式**上限（未完成设备标定前的兜底）。
///
/// 实际并发数由 [NekoPowTuning] 按**设备实测吞吐**决定：老机器/无 SIMD 加速、
/// P+E 混合核、功耗/热限制、虚拟机配额都会影响结果，写死核数一定不对。
/// 本机（i9-13980HX，24 物理核 / 32 线程）实测 difficulty=20：16 worker 22 ms、
/// 20 worker 52 ms、24 worker 237 ms —— 超订会塌陷，故兜底取 `min(核数-1, 16)`。
const int kNekoPowMaxWorkers = 16;

/// 摘要的前导零比特数是否达到 [bits]。
///
/// 与后端 `ReplayChallengeService.meetsDifficulty` 逐字节对齐：先比整整
/// `bits / 8` 个零字节，再按余数掩码比高位。`bits < 0` 视为不达标。
bool nekoMeetsDifficulty(List<int> digest, int bits) {
  if (bits < 0) return false;
  final fullBytes = bits ~/ 8;
  final remainingBits = bits % 8;
  if (digest.length < fullBytes + (remainingBits > 0 ? 1 : 0)) return false;
  for (var i = 0; i < fullBytes; i++) {
    if (digest[i] != 0) return false;
  }
  if (remainingBits == 0) return true;
  final mask = (0xFF << (8 - remainingBits)) & 0xFF;
  return (digest[fullBytes] & mask) == 0;
}

/// 同步解题：返回 `proof`（十进制计数器字符串）；难度非法时返回 null。
///
/// 计算量随难度指数增长（`2^difficulty`），**调用方应放到后台 isolate**
/// （见 [nekoSolveProof]），不要在 UI isolate 直接调用。单核路径：`counter`
/// 从 0 起逐个试（与官方实现一致，便于对照）。
String? nekoSolveProofSync(String seed, int difficulty) {
  if (difficulty < 0 || difficulty > kNekoMaxDifficultyBits) return null;
  return NekoPowHasher(seed).solve(0, 1, difficulty).toString();
}

/// 并行 worker 数（`difficulty` → worker 数）：委托设备自适应器。
///
/// 初始为启发式 `min(核数-1, 16)`；之后按**真实解题样本**的 per-worker 速率
/// 向下爬坡收敛（配额受限 / 降频机器会自动减少并发），并按难度分摊工作量。
int nekoPowWorkerCount(int difficulty) =>
    NekoPowTuning.instance.workersFor(difficulty);

/// 子 isolate 的搜索作业（字段都可跨 isolate 发送：字符串 / 整数 / SendPort）。
class NekoPowJob {
  const NekoPowJob({
    required this.seed,
    required this.difficulty,
    required this.offset,
    required this.stride,
    required this.port,
  });

  final String seed;
  final int difficulty;

  /// 本 worker 负责 `counter ≡ offset (mod stride)`。
  final int offset;
  final int stride;

  /// 解出后回传 `proof`（字符串）；worker 正常退出时由 `onExit` 回传 null。
  final SendPort port;
}

/// 子 isolate 入口（**顶层函数**：`Isolate.spawn` 只接受可发送的顶层入口，
/// 且不能捕获调用方实例——否则会重演「isolate 消息不可发送」那类问题）。
///
/// 回传 `[offset, counter, elapsedMicros]`：offset 用于反推该 worker 试了多少
/// 候选（供设备自适应采样），elapsed 是该 worker 自身的搜索耗时（不含 spawn）。
void nekoPowWorkerMain(NekoPowJob job) {
  final result = NekoPowHasher(job.seed).solveTimed(
    job.offset,
    job.stride,
    job.difficulty,
  );
  job.port.send(<int>[job.offset, result.counter, result.elapsedMicros]);
}

/// 在后台解出 [seed]/[difficulty] 对应的 `proof`；难度非法返回 null。
///
/// 高难度时开并行 worker（各试互不重叠的计数器同余类），任一 worker 解出即返回并
/// kill 其余 worker；低难度仍走单个临时 isolate。全程不阻塞 UI isolate。
///
/// [workerCount] 覆盖默认策略（[nekoPowWorkerCount]），供基准测试 / 未来「限制
/// 解题占用 CPU」的设置项使用；传 1 即退化为单 isolate。
Future<String?> nekoSolveProof(
  String seed,
  int difficulty, {
  int? workerCount,
}) async {
  if (difficulty < 0 || difficulty > kNekoMaxDifficultyBits) return null;

  final tuning = NekoPowTuning.instance;
  final workers = workerCount ?? tuning.workersFor(difficulty);
  if (workers <= 1) {
    return Isolate.run(() => nekoSolveProofSync(seed, difficulty));
  }

  final port = ReceivePort();
  final isolates = <Isolate>[];
  var exited = 0;
  try {
    for (var i = 0; i < workers; i++) {
      isolates.add(
        await Isolate.spawn(
          nekoPowWorkerMain,
          NekoPowJob(
            seed: seed,
            difficulty: difficulty,
            offset: i,
            stride: workers,
            port: port.sendPort,
          ),
          onExit: port.sendPort,
          debugName: 'neko-pow-$i',
        ),
      );
    }
    await for (final message in port) {
      if (message is List && message.length == 3) {
        final offset = message[0] as int;
        final counter = message[1] as int;
        final micros = message[2] as int;
        // 显式指定 workerCount（基准扫描）时不喂样本，避免污染自适应状态。
        if (workerCount == null && micros > 0) {
          final tried = (counter - offset) ~/ workers + 1;
          tuning.record(
            workers: workers,
            candidates: tried,
            elapsed: Duration(microseconds: micros),
          );
        }
        return '$counter'; // 任一 worker 解出即胜
      }
      if (message == null) {
        // worker 正常退出（仅可能因异常提前结束）：全部退出且无人解出才放弃。
        if (++exited >= workers) return null;
      }
    }
    return null;
  } finally {
    // 先解出者胜：其余 worker 立即停（`immediate` 不等待当前迭代收尾）。
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    port.close();
  }
}

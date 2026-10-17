// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// NekoMusic 挑战解题内核的回归：
//  1. 手写前缀 SHA-256 与 `package:crypto` **逐字节差分**（覆盖 1 / 2 块边界、
//     1～19 位计数器、ASCII / 中文 / emoji seed）；
//  2. `nekoMeetsDifficulty` 的位边界（0 / 7 / 8 / 32 / 64 / 负数）；
//  3. 同步解题的 proof 必须满足难度，且是**最小**计数器（与官方实现一致地从小往大试）；
//  4. 并行解题（多 isolate 同余类切分）的 proof 同样有效，且解出的计数器落在本
//     worker 的 `counter ≡ offset (mod stride)` 类里；
//  5. 难度非法 → null。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/neko/neko_pow_sha256.dart';
import 'package:archoera_music/apis/neko/neko_pow_tuning.dart';
import 'package:archoera_music/apis/neko/neko_replay.dart';

List<int> _referenceDigest(String seed, int counter) =>
    sha256.convert(utf8.encode('$seed:$counter')).bytes;

bool _meets(String seed, int counter, int difficulty) =>
    nekoMeetsDifficulty(_referenceDigest(seed, counter), difficulty);

void main() {
  final tuning = NekoPowTuning.instance;

  setUp(tuning.debugReset);
  tearDown(tuning.debugReset);

  group('设备能力自适应（按真实解题样本热切，不靠合成基准）', () {
    /// 注入一次样本：聚合吞吐 = per-worker 速率 × 并发（candidates/elapsed 为
    /// 胜出 worker 自身的速率）。
    void sample(int workers, double ratePerSecond) {
      tuning.record(
        workers: workers,
        candidates: (ratePerSecond / 1000).round(),
        elapsed: const Duration(milliseconds: 1),
      );
    }

    test('健康机器：低档聚合吞吐更低 → 回退并收敛（只多一次解题）', () {
      tuning
        ..debugLadder = [4, 8, 16]
        ..debugSetWorkers(16);
      sample(16, 2.5e6); // 当前档采样 → 安排试探 8
      expect(tuning.plannedWorkers, 8);
      sample(8, 2.5e6); // 单 worker 速率相同 → 聚合只有一半 → 不该降
      expect(tuning.workers, 16);
      expect(tuning.settled, isTrue);
    });

    test('配额受限/降频：低档聚合吞吐更高 → 降并发；再没有收益则收敛', () {
      tuning
        ..debugLadder = [4, 8, 16]
        ..debugSetWorkers(16);
      sample(16, 1.0e6); // 超订：每 worker 变慢
      expect(tuning.plannedWorkers, 8);
      sample(8, 2.6e6); // 8 档每 worker 明显更快 → 采纳并继续探 4
      expect(tuning.workers, 8);
      expect(tuning.plannedWorkers, 4);
      sample(4, 2.6e6); // 4 档没有更快 → 回退收敛在 8
      expect(tuning.workers, 8);
      expect(tuning.settled, isTrue);
    });

    test('收敛后定期向上复核：状态恢复时能爬回去', () {
      tuning
        ..debugLadder = [4, 8, 16]
        ..debugSetWorkers(8);
      sample(8, 2.0e6); // 当前档 → 向下试 4
      sample(4, 2.0e6); // 4 不更快 → 收敛在 8
      expect(tuning.workers, 8);
      expect(tuning.settled, isTrue);

      // 收敛后 15 次解题保持 8，第 16 次触发向上复核
      for (var i = 0; i < 15; i++) {
        sample(8, 2.0e6);
        expect(tuning.plannedWorkers, 8);
      }
      sample(8, 2.0e6);
      expect(tuning.plannedWorkers, 16);

      // 16 档聚合吞吐明显更高（48M/s vs 16M/s）→ 采纳
      sample(16, 3.0e6);
      expect(tuning.workers, 16);
    });

    test('低难度不 spawn；并发受难度工作量约束', () {
      tuning
        ..debugLadder = [4, 8, 16]
        ..debugSetWorkers(16);
      expect(tuning.workersFor(kNekoPowParallelMinBits - 1), 1);
      expect(tuning.workersFor(0), 1);
      // 难度 16：期望 2^16 / 每 worker 预算 8192 = 8
      expect(tuning.workersFor(16), 8);
      // 难度 20：期望 2^20 → 128，但封顶 16
      expect(tuning.workersFor(20), 16);
    });

    test('梯度上限不超过 16（更高只会超订塌陷）', () {
      final ladder = NekoPowTuning.instance..debugReset();
      expect(ladder.workers, lessThanOrEqualTo(16));
      expect(ladder.workers, greaterThanOrEqualTo(1));
      expect(ladder.workersFor(64), lessThanOrEqualTo(ladder.workers));
    });
  });

  group('前缀 SHA-256 与 package:crypto 逐字节一致', () {
    // seed 长度刻意覆盖：前缀尾部 0 / 55 / 56 / 63 字节（单块上限）与多块前端。
    final seeds = <String>[
      '',
      'a',
      'abc',
      'k' * 30,
      'k' * 31,
      'k' * 32,
      'k' * 54,
      'k' * 55,
      'k' * 56,
      'k' * 62,
      'k' * 63,
      'k' * 64,
      'k' * 65,
      'k' * 100,
      'k' * 127,
      '曲库' * 20,
      '🎵' * 12,
    ];
    // 计数器位数覆盖 1…19 位（位数变化会切换 pad / 长度模板）。
    final counters = <int>[
      0, 1, 9, 10, 11, 99, 100, 101, 999, 1000, 9999, 10000,
      123456, 999999, 1000000, 987654321, 1000000000000,
      999999999999999999,
    ];

    for (final seed in seeds) {
      test('seed=${seed.length} 字节', () {
        final hasher = NekoPowHasher(seed);
        for (final counter in counters) {
          expect(
            hasher.digestOf(counter),
            _referenceDigest(seed, counter),
            reason: 'seed=${seed.length}B counter=$counter',
          );
        }
      });
    }
  });

  group('nekoMeetsDifficulty 位边界', () {
    test('全零摘要：0…64 位全部达标', () {
      final zeros = List<int>.filled(32, 0);
      for (var bits = 0; bits <= 64; bits++) {
        expect(nekoMeetsDifficulty(zeros, bits), isTrue, reason: 'bits=$bits');
      }
    });

    test('非零高位：按位判定（逐字节对齐后端）', () {
      final digest = List<int>.filled(32, 0);
      digest[4] = 0x7F; // 前 4 字节全零，第 5 字节高 1 位为 0、其后为 1
      expect(nekoMeetsDifficulty(digest, 32), isTrue);
      expect(nekoMeetsDifficulty(digest, 33), isTrue); // 0x7F 的最高位为 0
      expect(nekoMeetsDifficulty(digest, 34), isFalse); // 次高位为 1
    });

    test('负数难度 / 摘要过短 → 不达标', () {
      expect(nekoMeetsDifficulty(List<int>.filled(32, 0), -1), isFalse);
      expect(nekoMeetsDifficulty(const [0, 0], 32), isFalse);
    });
  });

  group('同步解题', () {
    test('难度 0…12 的 proof 达标且为最小计数器', () {
      const seed = 'replay-seed';
      for (var difficulty = 0; difficulty <= 12; difficulty++) {
        final proof = nekoSolveProofSync(seed, difficulty);
        expect(proof, isNotNull, reason: 'difficulty=$difficulty');
        final counter = int.parse(proof!);
        expect(_meets(seed, counter, difficulty), isTrue,
            reason: 'difficulty=$difficulty proof=$proof');
        for (var smaller = 0; smaller < counter; smaller++) {
          expect(_meets(seed, smaller, difficulty), isFalse,
              reason: 'difficulty=$difficulty 的最小性：$smaller 也达标');
        }
      }
    });

    test('难度非法 → null', () {
      expect(nekoSolveProofSync('s', -1), isNull);
      expect(nekoSolveProofSync('s', kNekoMaxDifficultyBits + 1), isNull);
    });
  });

  group('同余类切分（并行 worker 的候选空间）', () {
    test('solve(offset, stride) 只返回本类计数器且达标', () {
      const seed = 'partition-seed';
      const difficulty = 10;
      // stride 覆盖 > 9 的情形（进位跨位，曾因只处理 delta<10 而算错计数器）。
      for (final stride in [1, 2, 3, 8, 9, 10, 16, 23, 100]) {
        for (var offset = 0; offset < stride; offset += stride > 8 ? 7 : 1) {
          final counter = NekoPowHasher(seed).solve(offset, stride, difficulty);
          expect(counter % stride, offset, reason: 'stride=$stride offset=$offset');
          expect(_meets(seed, counter, difficulty), isTrue);
        }
      }
    });

    test('hashRun 与逐个 probe 的命中数一致（步进正确性）', () {
      const seed = 'run-seed';
      const difficulty = 6;
      final hasher = NekoPowHasher(seed);
      final runHits = hasher.hashRun(3, 16, 400, difficulty);
      var expected = 0;
      for (var c = 3; c < 3 + 400 * 16; c += 16) {
        if (_meets(seed, c, difficulty)) expected++;
      }
      expect(runHits, expected);
    });
  });

  group('并行解题', () {
    test('高难度走多 isolate，proof 有效', () async {
      const seed = 'parallel-seed';
      const difficulty = 18; // 期望 2^18 次哈希：并行下为毫秒级
      final proof = await nekoSolveProof(seed, difficulty);
      expect(proof, isNotNull);
      expect(_meets(seed, int.parse(proof!), difficulty), isTrue);
    });

    test('低难度不 spawn，仍返回有效 proof', () async {
      final proof = await nekoSolveProof('low', 4);
      expect(proof, isNotNull);
      expect(_meets('low', int.parse(proof!), 4), isTrue);
    });

    test('workerCount 覆盖策略（1 = 单 isolate）且 proof 有效', () async {
      const seed = 'override-seed';
      final proof = await nekoSolveProof(seed, 18, workerCount: 1);
      expect(proof, isNotNull);
      expect(_meets(seed, int.parse(proof!), 18), isTrue);
      final multi = await nekoSolveProof(seed, 18, workerCount: 4);
      expect(multi, isNotNull);
      expect(_meets(seed, int.parse(multi!), 18), isTrue);
    });

    test('worker 数策略：低难度=1，其余在 [1, 32] 内且不超过核数', () {
      expect(nekoPowWorkerCount(0), 1);
      expect(nekoPowWorkerCount(kNekoPowParallelMinBits - 1), 1);
      final workers = nekoPowWorkerCount(24);
      expect(workers, inInclusiveRange(1, 32));
      expect(workers, lessThanOrEqualTo(Platform.numberOfProcessors));
    });
  });
}

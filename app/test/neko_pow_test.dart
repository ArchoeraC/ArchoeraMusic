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
import 'package:archoera_music/apis/neko/neko_replay.dart';

List<int> _referenceDigest(String seed, int counter) =>
    sha256.convert(utf8.encode('$seed:$counter')).bytes;

bool _meets(String seed, int counter, int difficulty) =>
    nekoMeetsDifficulty(_referenceDigest(seed, counter), difficulty);

void main() {
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
          expect(counter, isNotNull);
          expect(counter! % stride, offset, reason: 'stride=$stride offset=$offset');
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

    test('worker 数策略：低难度=1，高难度按核数封顶', () {
      expect(nekoPowWorkerCount(0), 1);
      expect(nekoPowWorkerCount(kNekoPowParallelMinBits - 1), 1);
      final workers = nekoPowWorkerCount(kNekoPowParallelMinBits);
      expect(workers, inInclusiveRange(1, kNekoPowMaxWorkers));
      if (Platform.numberOfProcessors > 2) {
        expect(workers, greaterThan(1), reason: '多核机器应启用并行');
      }
    });
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 挑战解题的性能 / 自适应轨迹观察（开发用，不进 CI）。
///
/// 覆盖：
///  1. `package:crypto`（旧实现）vs 前缀 midstate 快路径的单核哈希吞吐；
///  2. **设备自适应轨迹**：初始启发式 → 用真实解题样本向下试低档 → 收敛/降档；
///  3. 单核 vs 自适应并行的解题耗时；
///  4. worker 数扫描（显式覆盖，不喂自适应样本）。
///
/// 用法（在 `app/` 下，建议 AOT 后跑，JIT 数字偏低）：
///   dart compile exe tool/neko_pow_bench.dart -o /tmp/neko_bench && /tmp/neko_bench
///   dart run tool/neko_pow_bench.dart
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:archoera_music/apis/neko/neko_pow_sha256.dart';
import 'package:archoera_music/apis/neko/neko_pow_tuning.dart';
import 'package:archoera_music/apis/neko/neko_replay.dart';

const String _seed = 'bench-seed-0123456789abcdef';
const int _hashes = 200000;

/// 旧实现：每候选一次 `sha256.convert`（含消息 / 摘要对象分配）。
int _baselinePass(int hashes) {
  final seedBytes = utf8.encode(_seed);
  final prefixLength = seedBytes.length + 1;
  const maxDigits = 20;
  final message = Uint8List(prefixLength + maxDigits);
  message.setRange(0, seedBytes.length, seedBytes);
  message[seedBytes.length] = 0x3A; // ':'
  var hits = 0;
  for (var counter = 0; counter < hashes; counter++) {
    final digits = counter.toString();
    final length = prefixLength + digits.length;
    for (var i = 0; i < digits.length; i++) {
      message[prefixLength + i] = digits.codeUnitAt(i);
    }
    final digest = sha256.convert(Uint8List.view(message.buffer, 0, length));
    if (nekoMeetsDifficulty(digest.bytes, 48)) hits++;
  }
  return hits;
}

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(1)} ms';

Future<void> main() async {
  final tuning = NekoPowTuning.instance;
  print('seed=${_seed.length}B  核数=${Platform.numberOfProcessors}  '
      '初始并发（启发式）=${tuning.workers}');

  // ── 1) 设备自适应轨迹：真实解题样本驱动 ──────────────────────────────
  print('\n== 自适应轨迹（difficulty=20，真实解题，每行一次）==');
  for (var i = 1; i <= 12; i++) {
    final planned = tuning.plannedWorkers;
    final stopwatch = Stopwatch()..start();
    final proof = await nekoSolveProof(_seed, 20);
    stopwatch.stop();
    print('  #$i 计划并发=$planned  ${_ms(stopwatch.elapsedMicroseconds).padLeft(9)}  '
        'proof=$proof  当前档=${tuning.workers}  试探中=${tuning.probing}');
    if (tuning.learnedRates.length >= 3 && !tuning.probing) break;
  }
  final rates = tuning.learnedRates;
  final rateText = rates.entries
      .map((e) => '${e.key}w=${(e.value / 1e6).toStringAsFixed(2)}M/s')
      .join('  ');
  print('  学到聚合吞吐：$rateText');
  print('  当前并发=${tuning.workers}  冷却中=${tuning.cooldownRemaining}');
  print('  '
      '（d16→${tuning.workersFor(16)} / d20→${tuning.workersFor(20)} / '
      'd22→${tuning.workersFor(22)}）');

  // ── 2) 单核哈希吞吐（难度 48：几乎不命中，纯吞吐）───────────────────
  _baselinePass(_hashes ~/ 5); // warmup
  NekoPowHasher(_seed).hashRun(0, 1, _hashes ~/ 5, 48);

  final swBase = Stopwatch()..start();
  _baselinePass(_hashes);
  swBase.stop();
  final swFast = Stopwatch()..start();
  NekoPowHasher(_seed).hashRun(0, 1, _hashes, 48);
  swFast.stop();

  final baseMs = swBase.elapsedMicroseconds / 1000;
  final fastMs = swFast.elapsedMicroseconds / 1000;
  print('\n== 单核哈希吞吐（$_hashes 次）==');
  print('  package:crypto : ${baseMs.toStringAsFixed(1)} ms  '
      '(${(baseMs / _hashes * 1e6).toStringAsFixed(0)} ns/次)');
  print('  midstate 快路径: ${fastMs.toStringAsFixed(1)} ms  '
      '(${(fastMs / _hashes * 1e6).toStringAsFixed(0)} ns/次)');
  print('  加速           : ${(baseMs / fastMs).toStringAsFixed(2)}×');

  // ── 3) 单核 vs 自适应并行 ────────────────────────────────────────────
  print('\n== 解题耗时（单核 vs 自适应并发）==');
  for (final difficulty in [16, 18, 20, 22]) {
    final swSync = Stopwatch()..start();
    final syncProof = nekoSolveProofSync(_seed, difficulty);
    swSync.stop();
    final workers = tuning.workersFor(difficulty);
    final swPar = Stopwatch()..start();
    final parProof = await nekoSolveProof(_seed, difficulty);
    swPar.stop();
    final syncMs = swSync.elapsedMicroseconds / 1000;
    final parMs = swPar.elapsedMicroseconds / 1000;
    print('  difficulty=$difficulty  单核 ${_ms(swSync.elapsedMicroseconds).padLeft(9)} '
        '(proof=${syncProof ?? '-'})   自适应(${workers}w) '
        '${_ms(swPar.elapsedMicroseconds).padLeft(9)} (proof=${parProof ?? '-'})   '
        '${(syncMs / parMs).toStringAsFixed(2)}×');
  }

  // ── 4) worker 数扫描（显式覆盖；不喂自适应样本）─────────────────────
  print('\n== worker 数扫描（difficulty=20，每档 3 次取中位；不喂样本）==');
  for (final workers in [1, 4, 8, 16, 20, 24]) {
    final times = <int>[];
    for (var i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      final proof = await nekoSolveProof(_seed, 20, workerCount: workers);
      sw.stop();
      if (proof == null) {
        print('  workers=$workers 解算失败');
        return;
      }
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    print('  workers=${workers.toString().padLeft(2)}  中位 '
        '${_ms(times[1]).padLeft(10)}');
  }
  print('\n（并发决策见 NekoPowTuning：仅用真实解题样本，不做合成基准）');
}

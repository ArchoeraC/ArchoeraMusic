// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 挑战解题的性能对比（开发用，不进 CI）。
///
/// 对比三条路径：
///  1. `package:crypto` 逐次 `convert`（旧实现）；
///  2. 前缀 midstate 快路径（[NekoPowHasher]，单核）；
///  3. 多 isolate 并行求解（[nekoSolveProof]，按核数封顶）。
///
/// 用法（在 `app/` 下）：
///   dart run tool/neko_pow_bench.dart
///
/// 注意：耗时数字仅作量级参考（受机器负载、CPU 频率影响），不作断言。
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:archoera_music/apis/neko/neko_pow_sha256.dart';
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

/// 新实现：前缀 midstate + 零分配候选。
int _fastPass(int hashes) =>
    NekoPowHasher(_seed).hashRun(0, 1, hashes, 48);

String _fmt(double ms) => '${ms.toStringAsFixed(1)} ms';

Future<void> main() async {
  print('seed=${_seed.length}B  核数=${Platform.numberOfProcessors}  '
      'difficulty=16 时 workers=${nekoPowWorkerCount(16)}');

  // ── 单核吞吐（难度 48：几乎不会命中，纯哈希吞吐）────────────────────
  _baselinePass(_hashes ~/ 5); // warmup
  _fastPass(_hashes ~/ 5);

  final swBase = Stopwatch()..start();
  _baselinePass(_hashes);
  swBase.stop();

  final swFast = Stopwatch()..start();
  _fastPass(_hashes);
  swFast.stop();

  final baseMs = swBase.elapsedMicroseconds / 1000;
  final fastMs = swFast.elapsedMicroseconds / 1000;
  print('\n== 单核哈希吞吐（$_hashes 次）==');
  print('  package:crypto : ${_fmt(baseMs)}  '
      '(${(baseMs / _hashes * 1e6).toStringAsFixed(0)} ns/次)');
  print('  midstate 快路径: ${_fmt(fastMs)}  '
      '(${(fastMs / _hashes * 1e6).toStringAsFixed(0)} ns/次)');
  print('  加速           : ${(baseMs / fastMs).toStringAsFixed(2)}×');

  // ── 解题耗时（单核 vs 并行）─────────────────────────────────────────
  print('\n== 解题耗时（取实际解出时间）==');
  for (final difficulty in [16, 18, 20, 22]) {
    final swSync = Stopwatch()..start();
    final syncProof = nekoSolveProofSync(_seed, difficulty);
    swSync.stop();

    final swPar = Stopwatch()..start();
    final parProof = await nekoSolveProof(_seed, difficulty);
    swPar.stop();

    final syncMs = swSync.elapsedMicroseconds / 1000;
    final parMs = swPar.elapsedMicroseconds / 1000;
    print('  difficulty=$difficulty  单核 ${_fmt(syncMs).padLeft(10)} '
        '(proof=${syncProof ?? '-'})   并行 ${_fmt(parMs).padLeft(9)} '
        '(proof=${parProof ?? '-'})   ${(syncMs / parMs).toStringAsFixed(2)}×');
  }
  print('\n（并行 worker 见 nekoPowWorkerCount：低难度不 spawn）');
}

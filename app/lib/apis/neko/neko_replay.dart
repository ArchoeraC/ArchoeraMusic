// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 请求防重放的**挑战题解题**（领取 nonce 的前置计算）。
///
/// 服务端自「领取 nonce 必须携带挑战」起，`GET /api/replay/nonce` 不再接受裸领取：
/// 客户端必须先 `GET /api/replay/challenge` 换题、按 `sha256-leading-zero-bits`
/// 解出 `proof`，再带 `challenge` / `proof` 兑换 nonce。
///
/// 本文件只做与传输无关的纯计算（[nekoMeetsDifficulty] / [nekoSolveProofSync]）及
/// 后台 isolate 包装 [nekoSolveProof]，对齐官方 PC 端 `ReplayNonceStore::solveProof`：
/// 找一个十进制计数器，使 `SHA-256(seed + ":" + counter)` 的前导零比特数达到
/// `difficulty`，把该计数器的十进制字符串作为 `proof`。服务端只验一次哈希，客户端要试
/// `2^difficulty` 量级次——这种成本不对称正是该方案的基础。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 已支持的解题算法标识；换题响应里的 `algorithm` 必须与之一致，否则不盲解。
const String kNekoPowAlgorithm = 'sha256-leading-zero-bits';

/// 难度上限：服务端远低于此值，仅防止异常输入把后台 isolate 空转卡死。
const int kNekoMaxDifficultyBits = 64;

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
/// （见 [nekoSolveProof]），不要在 UI isolate 直接调用。
/// 复用同一块消息缓冲区，避免每次迭代重新分配：`seed + ":"` 前缀只写一次，
/// 每次迭代只覆盖十进制计数器部分。
String? nekoSolveProofSync(String seed, int difficulty) {
  if (difficulty < 0 || difficulty > kNekoMaxDifficultyBits) return null;

  final seedBytes = utf8.encode(seed);
  final prefixLength = seedBytes.length + 1;
  // 最长 20 位十进制计数器（unsigned 64-bit 上限）随用随覆盖。
  const maxDigits = 20;
  final message = Uint8List(prefixLength + maxDigits);
  message.setRange(0, seedBytes.length, seedBytes);
  message[seedBytes.length] = 0x3A; // ':'

  for (var counter = 0; ; counter++) {
    final digits = counter.toString();
    final length = prefixLength + digits.length;
    for (var i = 0; i < digits.length; i++) {
      message[prefixLength + i] = digits.codeUnitAt(i);
    }
    final digest = sha256.convert(Uint8List.view(message.buffer, 0, length));
    if (nekoMeetsDifficulty(digest.bytes, difficulty)) return digits;
  }
}

/// 在后台 isolate 解出 [seed]/[difficulty] 对应的 `proof`；难度非法返回 null。
///
/// 解题要试 `2^difficulty` 量级的哈希，放到临时 isolate 算，避免阻塞 UI
/// （对齐官方 PC 端在 Worker 线程解题、主线程不卡顿的做法）。
Future<String?> nekoSolveProof(String seed, int difficulty) async {
  if (difficulty < 0 || difficulty > kNekoMaxDifficultyBits) return null;
  return Isolate.run(() => nekoSolveProofSync(seed, difficulty));
}

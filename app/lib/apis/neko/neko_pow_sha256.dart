// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 防重放挑战的**快速 SHA-256 前缀哈希**（解题内核）。
///
/// 协议固定为「找十进制计数器 `c`，使 `SHA-256(seed + ":" + c)` 的前导零比特数
/// ≥ difficulty」（见 [neko_replay.dart]）。难点在于要试 `2^difficulty` 量级次，
/// 而 `package:crypto` 每次 `convert` 都会重建摘要器 + 分配消息/摘要对象——
/// 在几十万到上千万次试探下，分配开销比压缩函数本身还贵。
///
/// 本文件的做法（**不改协议、不改 proof 的语义**）：
///  - `seed + ":"` 是**固定前缀**：其完整 64 字节块只压缩一次，结果作为 midstate；
///  - 每个候选只需从 midstate 起压「前缀尾部 + 计数器 + pad + 长度」（≤ 2 块）；
///  - 计数器按十进制**算术拆位**写入预分配缓冲，不产生 String / List 分配；
///  - pad / 长度字段按「计数器位数」缓存模板（位数只在 9→10、99→100… 时变化）。
///
/// 正确性由 `test/neko_pow_test.dart` 对 `package:crypto` 做**逐字节差分**校验
/// （多组 seed 长度 × 计数器位数，覆盖 1 / 2 块边界）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// SHA-256 初始状态（FIPS 180-4 §5.3.3）。
const List<int> _sha256Iv = [
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
];

/// SHA-256 轮常量（FIPS 180-4 §4.2.2）。
const List<int> _sha256K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// `SHA-256(seed + ":" + 十进制计数器)` 的快速判定器。
///
/// 构造时把固定前缀压缩成 midstate；之后 [probe] / [solve] 每次只做 1–2 块压缩，
/// 不产生任何分配（`counter.toString()` 的 String 也被拆位写入缓冲取代）。
class NekoPowHasher {
  /// 以 [seed] 为固定前缀（自动补上协议约定分隔符 `:`）。
  NekoPowHasher(String seed) {
    final seedBytes = utf8.encode(seed);
    final prefix = Uint8List(seedBytes.length + 1)
      ..setAll(0, seedBytes)
      ..[seedBytes.length] = 0x3A; // ':'
    _prefixLength = prefix.length;

    // 前缀的完整块压成 midstate：这些字节对所有候选都相同。
    final fullBlocks = prefix.length ~/ 64;
    final midstate = Uint32List(8)..setAll(0, _sha256Iv);
    final block = Uint8List(64);
    for (var b = 0; b < fullBlocks; b++) {
      block.setRange(0, 64, prefix, b * 64);
      _compressInto(midstate, block);
    }
    _midstate = midstate;

    // 前缀尾部（< 64 字节）——每次候选都要重新写入消息块。
    final tailLength = prefix.length - fullBlocks * 64;
    _tail = Uint8List(tailLength)
      ..setAll(0, prefix.sublist(fullBlocks * 64));

    _block = Uint8List(128); // 尾部 + 20 位计数器 + pad + 长度 ≤ 92 字节 → 2 块
  }

  /// 十进制计数器最多 20 位（unsigned 64-bit 上限）。
  static const int _maxCounterDigits = 20;

  late final Uint32List _midstate;
  late final Uint8List _tail;
  late final int _prefixLength;

  late final Uint8List _block;

  // 压缩用的临时状态（字段初始化器先于构造体执行：构造期的「前缀 midstate」压缩
  // 也要用到它们，故不能留到构造体末尾再赋值）。
  final Uint32List _work = Uint32List(64);
  final Uint32List _state = Uint32List(8);

  /// 十进制计数器（低位在前的 0..9），避免逐候选做除法 / `toString`。
  final Uint8List _dec = Uint8List(_maxCounterDigits);
  int _digitCount = 1;

  /// 当前消息块按哪个「计数器位数」铺好了 pad / 长度字段（0 = 尚未铺）。
  int _templatedDigits = 0;
  int _blockBytes = 0;
  int _digitsOffset = 0;

  /// [counter] 的哈希是否达到 [difficulty] 个前导零比特。
  bool probe(int counter, int difficulty) {
    _setCounter(counter);
    return _hashCurrent(difficulty);
  }

  /// 从 [start] 起按 [stride] 步进找第一个达标计数器（必然存在：期望 2^difficulty）。
  ///
  /// 并行解题时每个 worker 用不同的 `(start, stride)`：`counter ≡ start (mod stride)`，
  /// 各 worker 的候选**互不重叠**，合起来覆盖全部自然数。
  ///
  /// 计数器是 64 位有符号整数：要走到溢出需 `2^63` 次试探（远超实际难度对应的
  /// `2^difficulty`），故不做回绕处理。
  int solve(int start, int stride, int difficulty) {
    _setCounter(start);
    var counter = start;
    while (true) {
      if (_hashCurrent(difficulty)) return counter;
      counter += stride;
      _advanceCounter(stride);
    }
  }

  /// 同 [solve]，但额外回报**本次搜索自身耗时**（供 [NekoPowTuning] 采样）。
  ({int counter, int elapsedMicros}) solveTimed(
    int start,
    int stride,
    int difficulty,
  ) {
    final stopwatch = Stopwatch()..start();
    final counter = solve(start, stride, difficulty);
    stopwatch.stop();
    return (counter: counter, elapsedMicros: stopwatch.elapsedMicroseconds);
  }

  /// 从 [start] 起连续试 [count] 个候选（步进 [stride]），返回**命中数**。
  ///
  /// 仅供基准测试 / 性能诊断（与 [solve] 走同一条候选路径，语义不变）。
  int hashRun(int start, int stride, int count, int difficulty) {
    _setCounter(start);
    var hits = 0;
    for (var i = 0; i < count; i++) {
      if (_hashCurrent(difficulty)) hits++;
      if (i + 1 < count) _advanceCounter(stride);
    }
    return hits;
  }

  /// 测试接缝：返回 `SHA-256(seed + ":" + counter)` 的 32 字节摘要。
  ///
  /// 仅供单测与 `package:crypto` 做逐字节差分（生产路径只用 [probe] / [solve]，
  /// 那里不做字节展开）。
  Uint8List digestOf(int counter) {
    _setCounter(counter);
    _hashCurrent(0);
    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      final word = _state[i];
      out[i * 4] = (word >>> 24) & 0xFF;
      out[i * 4 + 1] = (word >>> 16) & 0xFF;
      out[i * 4 + 2] = (word >>> 8) & 0xFF;
      out[i * 4 + 3] = word & 0xFF;
    }
    return out;
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 把 [_dec]（低位在前）转成十进制数字的绝对值写入计数器缓冲。
  void _setCounter(int value) {
    var v = value;
    var n = 0;
    do {
      _dec[n++] = v % 10;
      v ~/= 10;
    } while (v > 0);
    _digitCount = n;
  }

  /// 十进制加法（[delta] 为任意正步进，如并行 worker 的 `stride`）：
  /// 逐位进位；位数增长时补零位再写进位。
  ///
  /// 只对**被触及的位**做除法（最低位起，遇 carry=0 立即停）：正常步进下每候选
  /// 只碰 1–2 位。
  void _advanceCounter(int delta) {
    var carry = delta;
    var i = 0;
    while (carry != 0) {
      if (i >= _digitCount) _dec[_digitCount++] = 0;
      final v = _dec[i] + carry;
      _dec[i] = v % 10;
      carry = v ~/ 10;
      i++;
    }
  }

  /// 哈希当前 [_dec] 计数器并判定难度（1–2 块压缩，零分配）。
  bool _hashCurrent(int difficulty) {
    if (_digitCount != _templatedDigits) _template(_digitCount);

    final offset = _digitsOffset;
    for (var i = 0; i < _digitCount; i++) {
      _block[offset + i] = 0x30 + _dec[_digitCount - 1 - i];
    }

    _state.setAll(0, _midstate);
    for (var b = 0; b < _blockBytes; b += 64) {
      _compressInto(_state, _block, b);
    }
    return _stateMeets(difficulty);
  }

  /// 按「计数器占 [digits] 位」铺好尾块：前缀尾部 + 空位数位 + pad + 64 位长度。
  void _template(int digits) {
    // 块数只取决于「前缀尾部 + 计数器」（完整前缀块已压进 midstate）；
    // 长度字段则记录**整条消息**的字节数。
    final remaining = _tail.length + digits;
    final blocks = (remaining + 9 + 63) ~/ 64;
    final bytes = blocks * 64;
    _block.fillRange(0, bytes, 0);
    _block.setAll(0, _tail);
    _digitsOffset = _tail.length;
    _block[_tail.length + digits] = 0x80; // pad 起始位
    final bitLength = (_prefixLength + digits) * 8;
    // 64 位大端长度（仅写低 56 位足够：消息远小于 2^56 字节）。
    for (var i = 0; i < 8; i++) {
      _block[bytes - 1 - i] = (bitLength >>> (8 * i)) & 0xFF;
    }
    _templatedDigits = digits;
    _blockBytes = bytes;
  }

  /// 摘要（8 个 32 位字）是否达到 [difficulty] 个前导零比特（0…64）。
  bool _stateMeets(int difficulty) {
    final fullWords = difficulty ~/ 32;
    final remaining = difficulty % 32;
    for (var i = 0; i < fullWords; i++) {
      if (_state[i] != 0) return false;
    }
    if (remaining == 0) return true;
    return (_state[fullWords] >>> (32 - remaining)) == 0;
  }

  static int _rotr(int x, int n) =>
      ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  /// 单块压缩：`state ← state + compress(block[offset .. offset+64))`。
  ///
  /// `state` / `_work` 用 [Uint32List] 承载，写入自动截断到 32 位；局部变量在
  /// 赋值回 typed list 前显式 `& 0xFFFFFFFF`，避免 Dart 64 位 int 溢出到高位。
  void _compressInto(Uint32List state, Uint8List block, [int offset = 0]) {
    final w = _work;
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (block[j] << 24) |
          (block[j + 1] << 16) |
          (block[j + 2] << 8) |
          block[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    var a = state[0], b = state[1], c = state[2], d = state[3];
    var e = state[4], f = state[5], g = state[6], h = state[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
  }
}

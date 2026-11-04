// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 引擎 `fft` 事件解析回归（docs/spectrum-analyzer.md §6.1）。
///
/// App 播放路径已改为「引擎事件推送 → UI 纯接收」：本测试锁定事件字段
/// 解析、缺失字段的安全默认值，以及 [FftFrame] 元数据透传。
library;

import 'dart:convert';

import 'package:archoera_music/services/playback/audio_engine_process.dart';
import 'package:archoera_music/services/playback/fft_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fft 事件：完整字段解析为 EngineFft', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      final l = List<double>.generate(128, (i) => i / 128);
      final r = List<double>.generate(128, (i) => 1 - i / 128);
      final next = engine.events
          .where((e) => e is EngineFft)
          .cast<EngineFft>()
          .first;
      engine.feedControlLine(
        jsonEncode({
          'type': 'fft',
          'seq': 42,
          'interval_ms': 300,
          'sample_rate': 48000,
          'bins': 128,
          'min_hz': 40,
          'max_hz': 16000,
          'ldata': l,
          'rdata': r,
          'beat': 0.32,
        }),
      );
      final event = await next.timeout(const Duration(seconds: 2));
      expect(event.ldata, l);
      expect(event.rdata, r);
      expect(event.beat, closeTo(0.32, 1e-9));
      expect(event.seq, 42);
      expect(event.intervalMs, 300);
      expect(event.minHz, 40);
      expect(event.maxHz, 16000);
    } finally {
      await engine.stop();
    }
  });

  test('fft 事件：缺失字段使用安全默认值（128 个 0 / 50ms / 40–16kHz / seq 0）', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      final next = engine.events
          .where((e) => e is EngineFft)
          .cast<EngineFft>()
          .first;
      engine.feedControlLine('{"type":"fft"}');
      final event = await next.timeout(const Duration(seconds: 2));
      expect(event.ldata, hasLength(128));
      expect(event.rdata, hasLength(128));
      expect(event.ldata.every((v) => v == 0), isTrue);
      expect(event.rdata.every((v) => v == 0), isTrue);
      expect(event.beat, 0);
      expect(event.seq, 0);
      expect(event.intervalMs, 50);
      expect(event.minHz, 40);
      expect(event.maxHz, 16000);
    } finally {
      await engine.stop();
    }
  });

  test('fft 事件：0..255 整数编码（引擎侧 8-bit 量化）还原为 [0,1]', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      final next = engine.events
          .where((e) => e is EngineFft)
          .cast<EngineFft>()
          .first;
      engine.feedControlLine(
        jsonEncode({
          'type': 'fft',
          'ldata': [0, 128, 255],
          'rdata': [255, 0, 64],
          'beat': 82,
        }),
      );
      final event = await next.timeout(const Duration(seconds: 2));
      expect(event.ldata[0], 0);
      expect(event.ldata[1], closeTo(128 / 255, 1e-9));
      expect(event.ldata[2], 1);
      expect(event.rdata[0], 1);
      expect(event.rdata[1], 0);
      expect(event.rdata[2], closeTo(64 / 255, 1e-9));
      expect(event.beat, closeTo(82 / 255, 1e-9));
    } finally {
      await engine.stop();
    }
  });

  test('fft 事件：短数组补零到 128，非数值项按 0 兜底', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      final next = engine.events
          .where((e) => e is EngineFft)
          .cast<EngineFft>()
          .first;
      engine.feedControlLine(
        jsonEncode({
          'type': 'fft',
          'ldata': [0.5, null, 'bad', 0.25],
          'rdata': [1.0],
        }),
      );
      final event = await next.timeout(const Duration(seconds: 2));
      expect(event.ldata, hasLength(128));
      expect(event.ldata[0], 0.5);
      expect(event.ldata[1], 0);
      expect(event.ldata[2], 0);
      expect(event.ldata[3], 0.25);
      expect(event.ldata.skip(4).every((v) => v == 0), isTrue);
      expect(event.rdata, hasLength(128));
      expect(event.rdata[0], 1);
      expect(event.rdata.skip(1).every((v) => v == 0), isTrue);
    } finally {
      await engine.stop();
    }
  });

  test('FftFrame.withIntervalMs 保留 seq / minHz / maxHz', () {
    const frame = FftFrame(
      ldata: [0.1],
      rdata: [0.2],
      beatStrength: 0.5,
      intervalMs: 50,
      seq: 7,
      minHz: 40,
      maxHz: 16000,
    );
    final next = frame.withIntervalMs(300);
    expect(next.intervalMs, 300);
    expect(next.seq, 7);
    expect(next.minHz, 40);
    expect(next.maxHz, 16000);
    expect(next.beatStrength, 0.5);
    expect(identical(next.ldata, frame.ldata), isTrue);
    expect(identical(next.rdata, frame.rdata), isTrue);
  });
}

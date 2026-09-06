// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 引擎会话启动门槛（started=ready）回归测试。
///
/// 背景：引擎改为流式起播后，`done` 事件只在曲尾/内容 EOF 到达（不再于
/// 开头）。若启动/切歌流程以 `await engine.done` 作为「会话已启动」门槛，
/// load/playAll/playNow 等会挂到整曲播完——表现为「播放全部」按钮永久
/// loading、期间无法切换曲目。本测试锁定门槛语义：
///   - `started` 在 ready 收敛（流式下首块 PCM 即出声前）；
///   - `done` 延后到曲尾，不得作为启动信号；
///   - ready 前的 error/exited 使 `started` 抛错收敛（启动失败可走失败分支）；
///   - stop() 主动放弃会话时放行 pending started/done（切歌不挂等）。
library;

import 'dart:async';

import 'package:archoera_music/services/playback/audio_engine_process.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 C 侧 mediaengine_lib.c ready 事件同构的仿真行（曲长 180s）。
const _readyLine =
    '{"type":"ready","version":"test","duration_ms":180000,'
    '"sample_rate":48000,"channels":2,"out_sample_rate":48000}';

/// 微任务冲排（Completer/Stream 交付均为异步微任务）。
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('流式起播：started 在 ready 收敛、done 延后到曲尾（启动不得等 done）', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      final order = <String>[];
      unawaited(engine.started.then((_) => order.add('started')));
      unawaited(engine.done.then((_) => order.add('done')));
      unawaited(
        engine.events
            .firstWhere((e) => e is EngineReady)
            .then((_) => order.add('ready-event')),
      );

      // 引擎 ready（流式开始，其后紧跟 playing/出声），整曲远未 EOF。
      engine.feedControlLine(_readyLine);
      await engine.started.timeout(const Duration(seconds: 2));
      await _flush();

      expect(order, contains('started'), reason: 'started 应在 ready 后立即收敛');
      expect(
        order,
        isNot(contains('done')),
        reason: 'done 只在曲尾 EOF 到达——它绝不能成为启动/播放已开始的信号',
      );

      // 曲目播到结尾：done 此刻才到。
      engine.feedControlLine('{"type":"done"}');
      await engine.done.timeout(const Duration(seconds: 2));
      expect(order, contains('done'));
    } finally {
      await engine.stop();
    }
  });

  test('started 之后到达的 error/exited 不破坏门槛（运行期错误由事件通知）', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      engine.feedControlLine(_readyLine);
      await engine.started.timeout(const Duration(seconds: 2));
      // 播放中（ready 已过）引擎报错/退出：started 已完成，不应被重放为失败，
      // 仅产生事件（load 已收敛；由 _onEngineEvent 记日志/清 buffering）。
      engine.feedControlLine('{"type":"error","message":"mid decode"}');
      engine.feedControlLine('{"type":"exited","code":-1}');
      await engine.started.timeout(const Duration(seconds: 2));
      expect(engine.started, completes); // 已完成的正常 future
    } finally {
      await engine.stop();
    }
  });

  test('ready 前 error/exited（启动失败）：started 抛错收敛而非挂死', () async {
    final engine = AudioEngineProcess.testHarness();
    try {
      // 仿真 pipeline create 失败：引擎先 error 后 exited，无 ready。
      engine.feedControlLine(
        '{"type":"error","message":"pipeline create failed: bad"}',
      );
      engine.feedControlLine('{"type":"exited","code":-1}');
      await expectLater(
        engine.started.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
      // done 兼容语义同样收敛（旧调用方 await done 的路径不挂死）
      await expectLater(
        engine.done.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
    } finally {
      await engine.stop();
    }
  });

  test('stop() 主动放弃会话：pending started/done 正常放行（切歌不挂等）', () async {
    final engine = AudioEngineProcess.testHarness();
    // 引擎已创建但 ready 尚未到达时被 stop（抢占式切歌时序）。
    await engine.stop();
    // 均应在 stop 后立即正常完成（而非永远 pending / 抛错）。
    await engine.started.timeout(const Duration(seconds: 2));
    await engine.done.timeout(const Duration(seconds: 2));
  });
}

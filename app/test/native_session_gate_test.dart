// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 原生会话生命周期闸门（`NativeSessionGate`）回归测试。
///
/// 背景：2026-11-18 崩溃报告（`thread=data-loop.0`、`signal=11`）指向切歌时
/// 「旧会话 destroy」与「新会话 create」并发进入原生输出后端（PipeWire ALSA
/// 插件的进程级全局 context）。闸门把原生 create/destroy 排成 FIFO，本测试
/// 锁定其语义：
///   - 后入队任务必须等前一个**真正完成**后才开始（不是「已调度」）；
///   - 前面任务抛错不阻塞后续任务，且错误仍抛给调用方；
///   - 执行顺序 = 调用顺序；
///   - `isBusy` 在排队/在途期间为 true，全部完成后为 false。
library;

import 'dart:async';

import 'package:archoera_music/services/playback/native_session_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 微任务冲排（Completer 交付均为异步微任务）。
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('后入队任务必须等前一个原生调用真正完成', () async {
    final gate = NativeSessionGate();
    final events = <String>[];
    final firstMayFinish = Completer<void>();

    final first = gate.run(() async {
      events.add('destroy:start');
      await firstMayFinish.future;
      events.add('destroy:end');
      return 1;
    });
    final second = gate.run(() async {
      events.add('create:start');
      return 2;
    });

    await _flush();
    // destroy 未返回：create 绝不能进入原生层。
    expect(events, ['destroy:start']);
    expect(gate.isBusy, isTrue);

    firstMayFinish.complete();
    expect(await first.timeout(const Duration(seconds: 1)), 1);
    expect(await second.timeout(const Duration(seconds: 1)), 2);
    expect(events, ['destroy:start', 'destroy:end', 'create:start']);
    await _flush();
    expect(gate.isBusy, isFalse);
  });

  test('前一个任务抛错不阻塞后续任务，错误仍抛给调用方', () async {
    final gate = NativeSessionGate();
    final events = <String>[];

    final failing = gate.run<void>(() async {
      events.add('boom');
      throw StateError('destroy failed');
    });
    final after = gate.run(() async {
      events.add('next');
      return 42;
    });

    await expectLater(failing, throwsStateError);
    expect(await after.timeout(const Duration(seconds: 1)), 42);
    expect(events, ['boom', 'next']);
    await _flush();
    expect(gate.isBusy, isFalse);
  });

  test('执行顺序 = 调用顺序（FIFO）', () async {
    final gate = NativeSessionGate();
    final order = <int>[];
    final futures = <Future<void>>[];
    for (var i = 0; i < 4; i++) {
      futures.add(
        gate.run<void>(() async {
          // 故意让前面的任务多等几个微任务：FIFO 不能被「快的先跑」打乱。
          for (var k = 0; k <= 3 - i; k++) {
            await _flush();
          }
          order.add(i);
        }),
      );
    }
    await Future.wait(futures).timeout(const Duration(seconds: 2));
    expect(order, [0, 1, 2, 3]);
  });
}

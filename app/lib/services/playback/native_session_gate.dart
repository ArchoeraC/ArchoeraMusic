// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

/// 原生音频会话生命周期串行化：**create 与 destroy 绝不并发**。
///
/// 背景（2026-11-18 崩溃报告：`signal=11`、`thread=data-loop.0`、
/// `si_code=2`）：切歌时旧会话的原生收尾（`archoera_mediaengine_destroy` →
/// join 引擎线程 → 关闭输出设备）与新会话的原生创建（重新打开输出设备 +
/// 起一条新的 PipeWire 流）曾在不同线程上**同时**进入原生层。PipeWire 的
/// ALSA 插件把 client/context/data-loop 挂在**进程级全局**变量上（
/// `libasound_module_pcm_pipewire.so`），"最后一关" 的 `snd_pcm_close` 与
/// "第一个开" 的 `snd_pcm_open` 并发时会在 data-loop 线程上踩到正在销毁的
/// context —— 表现为随机闪退，且栈顶永远是数据环线程而不是调用方。
///
/// 这里把原生 create / destroy 排成 FIFO：后进入的一侧必须等前一侧的原生
/// 调用**真正返回**（join 完成）后再进原生层。
///
/// 只串行化原生调用本身（`Isolate.run(create|destroy)`）：下载、解码准备、
/// UI 状态更新等长任务不排队，切歌响应不受影响。
class NativeSessionGate {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// 当前是否有排队/在途任务（诊断/测试用）。
  bool get isBusy => _pending > 0;

  /// 排队执行 [op]，返回其结果（或错误）。执行顺序 = 调用顺序。
  Future<T> run<T>(Future<T> Function() op) {
    final prev = _tail;
    final release = Completer<void>();
    _tail = release.future;
    _pending++;
    return prev.then((_) => op()).whenComplete(() {
      _pending--;
      release.complete();
    });
  }
}

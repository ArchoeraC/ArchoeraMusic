// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// M3 内存不足提示（docs/audio-memory-source.md §13）：模态 + 红色全局变暗
// （区别于普通黑色 dim）；后台态用系统通知属后续增强。
import 'package:flutter/material.dart';

import '../../app/router.dart';

/// 内存资源告警专用 scrim（红色系透明，区别于全局黑色 dim）。
const Color kMemoryAlertBarrier = Color(0x5926A69A); // 红系：0x59 alpha ≈ .35

/// 纯内存不可用（极低内存等）时的保守决策确认。
///
/// 返回：
///  - true  → 用户选择「在线直连回退」（引擎 FFmpeg URL，仍可播）；
///  - false → 用户选择停止（不再以该源继续，按停播处理）。
/// 无 UI context（headless/后台测试）时自动按 true 回退并记录。
Future<bool> confirmMemoryFallback(String reason) async {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) {
    debugPrint('[M3] 无 UI context，自动在线直连回退（$reason）');
    return true;
  }
  final proceed = await showDialog<bool>(
    context: ctx,
    barrierColor: kMemoryAlertBarrier,
    builder: (context) => AlertDialog(
      title: const Text('内存不足 · 纯内存播放不可用'),
      content: Text(
        '$reason\n\n继续将使用在线直连（引擎联网）播放；或停止本次播放。',
        style: const TextStyle(height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('停止'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('在线直连播放'),
        ),
      ],
    ),
  );
  return proceed ?? false;
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// M3 内存不足提示（docs/audio-memory-source.md §13）：模态 + 红色全局变暗
// （区别于普通黑色 dim）；后台态用系统通知属后续增强。
import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../eta/icon/eta_icons.dart';
import '../../l10n/l10n.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/playback/store_source.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';

/// 内存资源告警专用 scrim（红色系透明，区别于全局黑色 dim）。
/// ARGB = 0x59 alpha（≈.35）· R=0xF4 G=0x43 B=0x36（Material Colors.red）。
const Color kMemoryAlertBarrier = Color(0x59F44336);

/// 把结构化失败详情本地化为弹窗正文首行（无详情时回落未知文案）。
String _failText(AppLocalizations l10n, MemorySourceFailDetail f) {
  switch (f.kind) {
    case MemorySourceFailKind.notHttpSource:
      return l10n.memorySourceFailNotHttp;
    case MemorySourceFailKind.isolateSpawn:
      return l10n.memorySourceFailIsolateSpawn(f.error ?? '');
    case MemorySourceFailKind.httpStatus:
      return l10n.memorySourceFailHttpStatus(f.httpCode ?? 0, f.httpStatus ?? '');
    case MemorySourceFailKind.overWholeCeiling:
      return l10n.memorySourceFailOverWholeCeiling(
        formatBytes(f.content ?? 0),
        formatBytes(f.limit ?? 0),
      );
    case MemorySourceFailKind.grewOverCeiling:
      return l10n.memorySourceFailGrewCeiling(
        formatBytes(f.got ?? 0),
        formatBytes(f.limit ?? 0),
      );
    case MemorySourceFailKind.emptyContent:
      return l10n.memorySourceFailEmpty;
    case MemorySourceFailKind.segstoreNewOom:
      return l10n.memorySourceFailSegOom;
    case MemorySourceFailKind.segstoreFillError:
      return l10n.memorySourceFailSegFill;
    case MemorySourceFailKind.segstoreFillException:
      return l10n.memorySourceFailSegFillEx(f.error ?? '');
    case MemorySourceFailKind.downloadFailed:
      return l10n.memorySourceFailDownload(f.error ?? '');
  }
}

/// 纯内存不可用（极低内存等）时的保守决策确认。
///
/// [fail]：结构化失败详情（store_source 产生；按类别本地化渲染）。
/// [rawReason]：原始失败文本（仅日志/兜底，不直接上屏）。
///
/// 返回：
///  - true  → 用户选择「在线直连回退」（引擎 FFmpeg URL，仍可播）；
///  - false → 用户选择停止（不再以该源继续，按停播处理）。
/// 无 UI context（headless/后台测试）时自动按 true 回退并记录。
Future<bool> confirmMemoryFallback(
  MemorySourceFailDetail? fail, {
  String? rawReason,
}) async {
  final ctx = rootNavigatorKey.currentContext;
  final raw = rawReason ?? '${fail?.kind}';
  if (ctx == null) {
    debugPrint('[M3] 无 UI context，自动在线直连回退（$raw）');
    return true;
  }
  final l10n = ctx.l10n;
  final reason = fail == null ? l10n.memorySourceFailUnknown : _failText(l10n, fail);
  final proceed = await showDialog<bool>(
    context: ctx,
    barrierColor: kMemoryAlertBarrier,
    builder: (context) => MemoryAlertDialog(l10n: l10n, reason: reason),
  );
  return proceed ?? false;
}

/// §13 内存资源告警弹窗本体。
///
/// 视觉区分走 docs §13：红 scrim（[kMemoryAlertBarrier]）+ 面板内红色告警图标/
/// 描边/主按钮——面板本身保持普通底色，避免与全局对话框样式割裂。
class MemoryAlertDialog extends StatelessWidget {
  const MemoryAlertDialog({super.key, required this.l10n, required this.reason});

  final AppLocalizations l10n;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
        side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(EtaIcons.alert, size: 22, color: scheme.error),
          const SizedBox(width: 8),
          Flexible(child: Text(l10n.memoryAlertTitle)),
        ],
      ),
      content: Text(
        '$reason\n\n${l10n.memoryAlertOnlineDesc}',
        style: const TextStyle(height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: Text(l10n.memoryAlertActionStop),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.memoryAlertActionOnlineDirect),
        ),
      ],
    );
  }
}

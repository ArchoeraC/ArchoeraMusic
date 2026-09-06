// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/downloader/download_controller.dart';
import '../common/toast.dart';
import '../common/anim.dart';

part 'download_task_tile/download_task_tile_view.dart';

/// 单任务行。
class DownloadTaskTile extends ConsumerWidget {
  const DownloadTaskTile({
    super.key,
    required this.task,
    required this.scheme,
    required this.selectMode,
    required this.selected,
    this.onToggle,
  });

  final DownloadTask task;
  final ColorScheme scheme;

  /// 批量选择模式：显示勾选框，点击整行切换选中。
  final bool selectMode;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildDownloadTaskTile(context, ref);

  Widget _statusIcon() {
    final (icon, color) = switch (task.status) {
      'queued' => (Icons.hourglass_top, scheme.onSurfaceVariant),
      'resolving' => (Icons.travel_explore, scheme.onSurfaceVariant),
      'running' => (Icons.downloading, scheme.primary),
      'paused' => (Icons.pause_circle_outline, scheme.onSurfaceVariant),
      'failed' => (Icons.error_outline, scheme.error),
      'canceled' => (Icons.cancel_outlined, scheme.onSurfaceVariant),
      'done' => (Icons.check_circle_outline, const Color(0xFF4DDB9B)),
      'already' => (Icons.check_circle_outline, scheme.tertiary),
      _ => (Icons.circle_outlined, scheme.onSurfaceVariant),
    };
    return Icon(icon, size: 22, color: color);
  }

  Widget _qualityChip(AppLocalizations l10n) {
    // 优先展示实际命中档（如 320k），无则展示请求档文案
    final actual = task.actualQuality;
    final label = actual ?? l10nQualityLabel(l10n, task.quality);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, color: scheme.primary),
      ),
    );
  }

  String _statusText(AppLocalizations l10n) {
    switch (task.status) {
      case 'queued':
        return l10n.downloadStatusQueued;
      case 'resolving':
        return l10n.downloadStatusResolving;
      case 'running':
        final p = task.progress;
        final speed = task.speed > 0 ? ' · ${_fmtSpeed(task.speed)}' : '';
        return p != null
            ? l10n.downloadStatusRunning(
                (p * 100).round(),
                _fmtSize(task.received),
                speed,
              )
            : l10n.downloadStatusRunningNoPercent(speed);
      case 'paused':
        return task.received > 0
            ? l10n.downloadStatusPausedWith(_fmtSize(task.received))
            : l10n.downloadStatusPaused;
      case 'failed':
        return l10n.downloadStatusFailed(task.error ?? l10n.commonUnknownError);
      case 'canceled':
        return l10n.downloadStatusCanceled;
      case 'done':
        return l10n.downloadStatusDone(
          _fmtSize(task.fileSize ?? task.received),
        );
      case 'already':
        return l10n.downloadStatusAlready;
      default:
        return task.status;
    }
  }

  Widget _iconAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 17,
      onPressed: onTap,
      icon: Icon(icon, color: scheme.onSurfaceVariant),
    );
  }

  void _launchDir(String dir) {
    try {
      if (Platform.isLinux) {
        Process.run('xdg-open', [dir]);
      } else if (Platform.isMacOS) {
        Process.run('open', [dir]);
      } else if (Platform.isWindows) {
        Process.run('explorer', [dir]);
      }
    } catch (_) {}
  }
}

/// 字节数人类可读（B / KB / MB / GB）。
String _fmtSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 速度人类可读（KB/s / MB/s）。
String _fmtSpeed(int bytesPerSec) {
  if (bytesPerSec < 1024) return '$bytesPerSec B/s';
  final kb = bytesPerSec / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
  return '${(kb / 1024).toStringAsFixed(2)} MB/s';
}

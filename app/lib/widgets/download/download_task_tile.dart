import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/downloader/download_controller.dart';
import '../common/toast.dart';
import '../common/anim.dart';

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
  Widget build(BuildContext context, WidgetRef ref) {
    final active = task.isActive;
    final paused = task.isPaused;
    final failed = task.isFailed;
    final done = task.isDone;
    final progress = task.progress;
    final l10n = context.l10n;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.5)
                : scheme.outline.withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          children: [
            if (selectMode) ...[
              Checkbox(
                value: selected,
                onChanged: (_) => onToggle?.call(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 2),
            ],
            _statusIcon(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          task.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _qualityChip(l10n),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _statusText(l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: failed
                          ? scheme.error
                          : scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                  if (active && progress != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: scheme.outline.withValues(alpha: 0.15),
                      ),
                    ),
                  ] else if (active && task.received > 0) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: const LinearProgressIndicator(minHeight: 4),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (selectMode)
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            else ...[
              if (active) ...[
                _iconAction(
                  tooltip: l10n.commonPause,
                  icon: Icons.pause_rounded,
                  onTap: () {
                    ref
                        .read(downloadControllerProvider.notifier)
                        .pause(task.taskId);
                    toast(l10n.toastPaused);
                  },
                ),
                // 取消 = 直接删除任务项并清空 .tmp 缓存
                _iconAction(
                  tooltip: l10n.downloadCancelTooltip,
                  icon: Icons.close,
                  onTap: () {
                    ref
                        .read(downloadControllerProvider.notifier)
                        .removeTask(task.taskId);
                    toast(l10n.toastCanceledTask);
                  },
                ),
              ],
              if (paused)
                _iconAction(
                  tooltip: l10n.downloadResume,
                  icon: Icons.play_arrow_rounded,
                  onTap: () {
                    ref
                        .read(downloadControllerProvider.notifier)
                        .retry(task.taskId);
                    toast(l10n.toastResumed);
                  },
                ),
              if (failed)
                _iconAction(
                  tooltip: l10n.commonRetry,
                  icon: Icons.refresh,
                  onTap: () {
                    ref
                        .read(downloadControllerProvider.notifier)
                        .retry(task.taskId);
                    toast(l10n.toastRequeued);
                  },
                ),
              if (done && task.filePath != null)
                _iconAction(
                  tooltip: l10n.downloadOpenDirTask,
                  icon: Icons.folder_open_outlined,
                  onTap: () => _launchDir(File(task.filePath!).parent.path),
                ),
              _moreMenu(context, ref, l10n),
            ],
          ],
        ),
      ),
    );
  }

  /// 更多菜单：上下文操作 + 删除（可选精确删除媒体文件）。
  Widget _moreMenu(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final active = task.isActive;
    final paused = task.isPaused;
    final failed = task.isFailed;
    final done = task.isDone;
    return PopupMenuButton<String>(
      tooltip: l10n.commonMore,
      icon: Icon(Icons.more_vert, size: 17, color: scheme.onSurfaceVariant),
      padding: EdgeInsets.zero,
      // 性能模式：菜单直出，无淡入/弹出动效
      popUpAnimationStyle: noAnim(context) ? AnimationStyle.noAnimation : null,
      onSelected: (v) => _onMenu(ref, v, l10n),
      itemBuilder: (context) => [
        if (active)
          PopupMenuItem(
            value: 'pause',
            child: Text(l10n.commonPause),
          ),
        if (paused)
          PopupMenuItem(
            value: 'resume',
            child: Text(l10n.downloadResume),
          ),
        if (failed)
          PopupMenuItem(
            value: 'retry',
            child: Text(l10n.commonRetry),
          ),
        if (done && task.filePath != null)
          PopupMenuItem(
            value: 'open',
            child: Text(l10n.downloadOpenDirTask),
          ),
        PopupMenuItem(
          value: 'delTask',
          child: Text(l10n.downloadDeleteTask),
        ),
        PopupMenuItem(
          value: 'delWithMedia',
          child: Text(l10n.downloadDeleteWithMediaExact),
        ),
      ],
    );
  }

  void _onMenu(WidgetRef ref, String value, AppLocalizations l10n) {
    final ctrl = ref.read(downloadControllerProvider.notifier);
    switch (value) {
      case 'pause':
        ctrl.pause(task.taskId);
        toast(l10n.toastPaused);
      case 'resume':
      case 'retry':
        ctrl.retry(task.taskId);
        toast(value == 'resume' ? l10n.toastResumed : l10n.toastRequeued);
      case 'open':
        _launchDir(File(task.filePath!).parent.path);
      case 'delTask':
        ctrl.removeTask(task.taskId);
        toast(l10n.toastDeletedTask);
      case 'delWithMedia':
        ctrl.removeTask(task.taskId, deleteFile: true);
        toast(l10n.toastDeletedTaskWithMedia);
    }
  }

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
            ? l10n.downloadStatusRunning((p * 100).round(), _fmtSize(task.received), speed)
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
        return l10n.downloadStatusDone(_fmtSize(task.fileSize ?? task.received));
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

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_task_tile.dart';

extension _DownloadTaskTileView on DownloadTaskTile {
  Widget _buildDownloadTaskTile(BuildContext context, WidgetRef ref) {
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
                selected ? EtaIcons.checkCircle : EtaIcons.roundOutline,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            else ...[
              if (active) ...[
                _iconAction(
                  tooltip: l10n.commonPause,
                  icon: EtaIcons.pause,
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
                  icon: EtaIcons.close,
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
                  icon: EtaIcons.play,
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
                  icon: EtaIcons.refresh,
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
                  icon: EtaIcons.folderOpenOutline,
                  onTap: () => _launchDir(File(task.filePath!).parent.path),
                ),
              _buildMoreMenu(context, ref, l10n),
            ],
          ],
        ),
      ),
    );
  }

  /// 更多菜单：上下文操作 + 删除（可选精确删除媒体文件）。
  Widget _buildMoreMenu(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final active = task.isActive;
    final paused = task.isPaused;
    final failed = task.isFailed;
    final done = task.isDone;
    return PopupMenuButton<String>(
      tooltip: l10n.commonMore,
      icon: Icon(EtaIcons.dotsVertical, size: 17, color: scheme.onSurfaceVariant),
      padding: EdgeInsets.zero,
      // 性能模式：菜单直出，无淡入/弹出动效
      popUpAnimationStyle: noAnim(context) ? AnimationStyle.noAnimation : null,
      onSelected: (v) => _onMenu(ref, v, l10n),
      itemBuilder: (context) => [
        if (active)
          PopupMenuItem(value: 'pause', child: Text(l10n.commonPause)),
        if (paused)
          PopupMenuItem(value: 'resume', child: Text(l10n.downloadResume)),
        if (failed)
          PopupMenuItem(value: 'retry', child: Text(l10n.commonRetry)),
        if (done && task.filePath != null)
          PopupMenuItem(value: 'open', child: Text(l10n.downloadOpenDirTask)),
        PopupMenuItem(value: 'delTask', child: Text(l10n.downloadDeleteTask)),
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
}

/// 下载页（任务列表：进度 / 暂停 / 取消 / 删除 / 清空 / 全部暂停·开始 / 批量操作）。
///
/// 纯展示层：状态全部来自 [downloadControllerProvider]（Rust 事件驱动），
/// 操作只调控制器接口，不触碰任何下载逻辑。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloader/download_controller.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../widgets/glass_surface.dart';
import '../widgets/toast.dart';

/// 删除 / 清空确认弹窗的选择结果（null = 取消）。
enum _DeleteChoice { taskOnly, withMedia }

/// 删除确认弹窗：取消 / 仅删除任务 / 删除任务及媒体文件（精确匹配）。
Future<_DeleteChoice?> _confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
}) {
  final l10n = context.l10n;
  return showDialog<_DeleteChoice>(
    context: context,
    builder: (context) => GlassDialogSurface(
      radius: BorderRadius.circular(16),
      color: Theme.of(context).dialogTheme.backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerLow,
      child: AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(message, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _DeleteChoice.taskOnly),
            child: Text(l10n.downloadDeleteTaskOnly),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _DeleteChoice.withMedia),
            child: Text(l10n.downloadDeleteWithMedia),
          ),
        ],
      ),
    ),
  );
}

/// 下载页。
class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});

  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends ConsumerState<DownloadPage> {
  /// 批量选择模式：开启后任务行显示勾选框，头部切换为批量操作。
  bool _selectMode = false;

  /// 批量模式下选中的任务 id。
  final Set<String> _selected = {};

  bool get _allSelected {
    final tasks = ref.read(downloadControllerProvider).tasks;
    return tasks.isNotEmpty && _selected.length == tasks.length;
  }

  void _enterSelectMode() => setState(() => _selectMode = true);

  void _exitSelectMode() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  void _toggleSelectAll(DownloadState state) {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(state.tasks.map((t) => t.taskId));
      }
    });
  }

  void _toggleTask(String taskId) {
    setState(() {
      if (!_selected.remove(taskId)) {
        _selected.add(taskId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(downloadControllerProvider);
    // 列表被清空/淘汰后自动退出批量模式（帧后安全 setState）
    if (_selectMode && state.tasks.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && state.tasks.isEmpty) _exitSelectMode();
      });
    }
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, state),
            const SizedBox(height: 16),
            Expanded(child: _body(context, state)),
          ],
        ),
      ),
    );
  }

  // ── 头部：标题 + 统计 + 操作（普通 / 批量选择两种形态）────────

  Widget _header(BuildContext context, DownloadState state) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    if (_selectMode) {
      return Row(
        children: [
          Text(
            l10n.downloadSelectedCount(_selected.length),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _toggleSelectAll(state),
            icon: Icon(
              _allSelected ? Icons.deselect : Icons.select_all,
              size: 16,
            ),
            label: Text(_allSelected ? l10n.downloadDeselectAll : l10n.downloadSelectAll),
          ),
          _headerIcon(
            scheme,
            icon: Icons.pause_circle_outline,
            tooltip: l10n.downloadPauseAll,
            onPressed: state.activeCount > 0
                ? () {
                    ref
                        .read(downloadControllerProvider.notifier)
                        .pauseAll();
                    toast(l10n.toastPausedAll);
                  }
                : null,
          ),
          _headerIcon(
            scheme,
            icon: Icons.play_circle_outline,
            tooltip: l10n.downloadResumeAll,
            onPressed: state.tasks.any((t) => t.isPaused || t.isFailed)
                ? () {
                    ref
                        .read(downloadControllerProvider.notifier)
                        .resumeAll();
                    toast(l10n.toastResumedAll);
                  }
                : null,
          ),
          _headerIcon(
            scheme,
            icon: Icons.delete_outline,
            tooltip: l10n.downloadDeleteSelected,
            color: scheme.error,
            onPressed: _selected.isEmpty ? null : _confirmBatchDelete,
          ),
          IconButton(
            tooltip: l10n.downloadExitSelect,
            visualDensity: VisualDensity.compact,
            onPressed: _exitSelectMode,
            icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return Row(
      children: [
        Text(
          l10n.sidebarDownload,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(width: 16),
        _statChip(scheme, Icons.downloading, l10n.downloadActiveCount(state.activeCount)),
        const SizedBox(width: 8),
        _statChip(scheme, Icons.check_circle_outline, l10n.downloadDoneCount(state.doneCount)),
        const Spacer(),
        if (state.tasks.isNotEmpty)
          TextButton.icon(
            onPressed: () => _openRoot(context),
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: Text(l10n.downloadOpenDir),
          ),
        TextButton.icon(
          onPressed: state.tasks.isEmpty ? null : _enterSelectMode,
          icon: const Icon(Icons.checklist, size: 16),
          label: Text(l10n.downloadSelectMode),
        ),
        if (state.tasks.any((t) => t.isActive))
          TextButton.icon(
            onPressed: () {
              ref.read(downloadControllerProvider.notifier).pauseAll();
              toast(l10n.toastPausedAll);
            },
            icon: const Icon(Icons.pause_rounded, size: 16),
            label: Text(l10n.downloadPauseAll),
          ),
        if (state.tasks.any((t) => t.isPaused || t.isFailed))
          TextButton.icon(
            onPressed: () {
              ref.read(downloadControllerProvider.notifier).resumeAll();
              toast(l10n.toastResumedAll);
            },
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: Text(l10n.downloadResumeAll),
          ),
        if (state.tasks.isNotEmpty)
          TextButton.icon(
            onPressed: () => _confirmClearAll(context),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: Icon(Icons.delete_sweep_outlined, size: 16, color: scheme.error),
            label: Text(l10n.commonClear, style: TextStyle(color: scheme.error)),
          ),
      ],
    );
  }

  /// 批量选择模式下的紧凑图标操作。
  Widget _headerIcon(
    ColorScheme scheme, {
    required IconData icon,
    required String tooltip,
    Color? color,
    VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      onPressed: onPressed,
      icon: Icon(icon, color: color ?? scheme.onSurfaceVariant),
    );
  }

  Widget _statChip(ColorScheme scheme, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.primary),
          ),
        ],
      ),
    );
  }

  // ── 主体 ────────────────────────────────────────────────────

  Widget _body(BuildContext context, DownloadState state) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    if (state.initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.initError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: scheme.error.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              state.initError!,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (state.tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.download_outlined,
              size: 56,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.downloadEmpty,
              style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.downloadEmptyHint,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: state.tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final task = state.tasks[i];
        return _TaskTile(
          task: task,
          scheme: scheme,
          selectMode: _selectMode,
          selected: _selected.contains(task.taskId),
          onToggle: _selectMode ? () => _toggleTask(task.taskId) : null,
        );
      },
    );
  }

  // ── 删除 / 清空 ─────────────────────────────────────────────

  Future<void> _confirmBatchDelete() async {
    final l10n = context.l10n;
    final choice = await _confirmDelete(
      context,
      title: l10n.downloadDeleteSelectedTitle(_selected.length),
      message: l10n.downloadDeleteSelectedMessage,
    );
    if (choice == null || !mounted) return;
    final deleteFile = choice == _DeleteChoice.withMedia;
    ref.read(downloadControllerProvider.notifier).removeTasks(
          _selected.toList(),
          deleteFile: deleteFile,
        );
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    toast(deleteFile ? l10n.toastDeletedSelectedWithMedia : l10n.toastDeletedSelected);
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final l10n = context.l10n;
    final choice = await _confirmDelete(
      context,
      title: l10n.downloadClearTitle,
      message: l10n.downloadClearMessage,
    );
    if (choice == null || !mounted) return;
    final deleteFiles = choice == _DeleteChoice.withMedia;
    ref
        .read(downloadControllerProvider.notifier)
        .clearTasks(deleteFiles: deleteFiles);
    toast(deleteFiles ? l10n.toastClearedWithMedia : l10n.toastCleared);
  }

  void _openRoot(BuildContext context) {
    final root = ref.read(downloadPrefsProvider).rootDir;
    _launchDir(root);
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
    } catch (_) {
      // 打开目录失败静默（仅影响便利性）
    }
  }
}

/// 单任务行。
class _TaskTile extends ConsumerWidget {
  const _TaskTile({
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
              _moreMenu(ref, l10n),
            ],
          ],
        ),
      ),
    );
  }

  /// 更多菜单：上下文操作 + 删除（可选精确删除媒体文件）。
  Widget _moreMenu(WidgetRef ref, AppLocalizations l10n) {
    final active = task.isActive;
    final paused = task.isPaused;
    final failed = task.isFailed;
    final done = task.isDone;
    return PopupMenuButton<String>(
      tooltip: l10n.commonMore,
      icon: Icon(Icons.more_vert, size: 17, color: scheme.onSurfaceVariant),
      padding: EdgeInsets.zero,
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
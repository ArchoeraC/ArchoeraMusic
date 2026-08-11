/// 下载页（任务列表：进度 / 暂停 / 取消 / 删除 / 清空 / 全部暂停·开始 / 批量操作）。
///
/// 纯展示层：状态全部来自 [downloadControllerProvider]（Rust 事件驱动），
/// 操作只调控制器接口，不触碰任何下载逻辑。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/downloader/download_controller.dart';
import '../../l10n/l10n.dart';
import '../widgets/common/toast.dart';
import '../widgets/download/delete_dialog.dart';
import '../widgets/download/download_task_tile.dart';

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
        return DownloadTaskTile(
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
    final choice = await showDownloadDeleteDialog(
      context,
      title: l10n.downloadDeleteSelectedTitle(_selected.length),
      message: l10n.downloadDeleteSelectedMessage,
    );
    if (choice == null || !mounted) return;
    final deleteFile = choice == DownloadDeleteChoice.withMedia;
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
    final choice = await showDownloadDeleteDialog(
      context,
      title: l10n.downloadClearTitle,
      message: l10n.downloadClearMessage,
    );
    if (choice == null || !mounted) return;
    final deleteFiles = choice == DownloadDeleteChoice.withMedia;
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

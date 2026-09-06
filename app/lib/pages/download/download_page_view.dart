// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_page.dart';

extension _DownloadPageView on _DownloadPageState {
  Widget _buildDownloadPage(BuildContext context) {
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
            _buildHeader(context, state),
            const SizedBox(height: 16),
            Expanded(child: _buildBody(context, state)),
          ],
        ),
      ),
    );
  }

  // ── 头部：标题 + 统计 + 操作（普通 / 批量选择两种形态）────────
  Widget _buildHeader(BuildContext context, DownloadState state) {
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
            label: Text(
              _allSelected ? l10n.downloadDeselectAll : l10n.downloadSelectAll,
            ),
          ),
          _headerIcon(
            scheme,
            icon: Icons.pause_circle_outline,
            tooltip: l10n.downloadPauseAll,
            onPressed: state.activeCount > 0 ? _pauseAll : null,
          ),
          _headerIcon(
            scheme,
            icon: Icons.play_circle_outline,
            tooltip: l10n.downloadResumeAll,
            onPressed: state.tasks.any((t) => t.isPaused || t.isFailed)
                ? _resumeAll
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
        _statChip(
          scheme,
          Icons.downloading,
          l10n.downloadActiveCount(state.activeCount),
        ),
        const SizedBox(width: 8),
        _statChip(
          scheme,
          Icons.check_circle_outline,
          l10n.downloadDoneCount(state.doneCount),
        ),
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
            onPressed: _pauseAll,
            icon: const Icon(Icons.pause_rounded, size: 16),
            label: Text(l10n.downloadPauseAll),
          ),
        if (state.tasks.any((t) => t.isPaused || t.isFailed))
          TextButton.icon(
            onPressed: _resumeAll,
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: Text(l10n.downloadResumeAll),
          ),
        if (state.tasks.isNotEmpty)
          TextButton.icon(
            onPressed: () => _confirmClearAll(context),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            icon: Icon(
              Icons.delete_sweep_outlined,
              size: 16,
              color: scheme.error,
            ),
            label: Text(
              l10n.commonClear,
              style: TextStyle(color: scheme.error),
            ),
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
          Text(label, style: TextStyle(fontSize: 12, color: scheme.primary)),
        ],
      ),
    );
  }

  // ── 主体 ────────────────────────────────────────────────────
  Widget _buildBody(BuildContext context, DownloadState state) {
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
            Icon(
              Icons.error_outline,
              size: 48,
              color: scheme.error.withValues(alpha: 0.6),
            ),
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
}

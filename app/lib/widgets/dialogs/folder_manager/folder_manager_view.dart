// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../folder_manager.dart';

extension _FolderManagerView on _FolderManagerState {
  Widget _buildFolderManager(BuildContext context) {
    final state = ref.watch(libraryStoreProvider);
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final dirs = state.scanDirs;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 目录列表
        for (final dir in dirs) _buildFolderRow(context, dir, scheme),
        if (dirs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                l10n.folderEmpty,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        // 手动路径输入 + 添加
        Row(
          children: [
            Expanded(
              child: SInput(
                controller: _pathCtrl,
                hintText: l10n.folderPathHint,
                width: double.infinity,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addManual(),
              ),
            ),
            const SizedBox(width: 8),
            SButton(
              label: l10n.folderBrowse,
              icon: EtaIcons.folderOpen,
              variant: SButtonVariant.secondary,
              onPressed: _pickDirectory,
            ),
            const SizedBox(width: 8),
            SButton(
              label: l10n.folderAdd,
              icon: EtaIcons.add,
              variant: SButtonVariant.primary,
              onPressed: _addManual,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFolderRow(BuildContext context, String dir, ColorScheme scheme) {
    final l10n = context.l10n;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(EtaIcons.folderOutline, size: 17, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _folderName(dir),
                  style: const TextStyle(fontSize: 13.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  dir,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.folderRemove,
            iconSize: 16,
            onPressed: () => _confirmRemove(dir),
            icon: Icon(EtaIcons.deleteOutline, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/scanner/library_store.dart';
import '../../l10n/l10n.dart';
import '../player/s_controls.dart';
import 's_dialog.dart';
import '../common/toast.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'folder_manager/folder_manager_view.dart';

/// 目录管理（对齐原项目 FolderManager.vue）：扫描目录列表 +
/// 添加（原生目录选择器 / 手动路径）+ 删除（确认）。
class FolderManager extends ConsumerStatefulWidget {
  const FolderManager({super.key});

  @override
  ConsumerState<FolderManager> createState() => _FolderManagerState();
}

class _FolderManagerState extends ConsumerState<FolderManager> {
  /// 手动路径输入控制器。
  final _pathCtrl = TextEditingController();

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  String _folderName(String dir) {
    final parts = dir
        .replaceAll('\\', '/')
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? dir : parts.last;
  }

  Future<void> _pickDirectory() async {
    String? path;
    try {
      path = await getDirectoryPath();
    } catch (_) {
      // XDG portal 不可用时回退手动输入
    }
    if (path == null || path.isEmpty) return;
    final ok = ref.read(libraryStoreProvider.notifier).addScanDir(path);
    if (!mounted) return;
    if (!ok) _toast(context.l10n.folderExists);
  }

  void _addManual() {
    final dir = _pathCtrl.text.trim();
    if (dir.isEmpty) return;
    final ok = ref.read(libraryStoreProvider.notifier).addScanDir(dir);
    if (ok) {
      _pathCtrl.clear();
    } else {
      _toast(context.l10n.folderInvalid);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    toast(msg);
  }

  Future<void> _confirmRemove(String dir) async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.folderRemoveTitle,
      description: l10n.folderRemoveDescription,
      child: Text(
        dir,
        style: TextStyle(
          fontSize: 12.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      actions: [
        SButton(
          label: l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.folderRemove,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok == true) {
      ref.read(libraryStoreProvider.notifier).removeScanDir(dir);
    }
  }

  @override
  Widget build(BuildContext context) => _buildFolderManager(context);
}

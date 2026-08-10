import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/scanner/library_store.dart';
import '../../l10n/l10n.dart';
import '../player/s_controls.dart';
import 's_dialog.dart';
import '../common/toast.dart';

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
    final parts = dir.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).toList();
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
            onPressed: () => Navigator.of(context).pop(false)),
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
  Widget build(BuildContext context) {
    final state = ref.watch(libraryStoreProvider);
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final dirs = state.scanDirs;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 目录列表
        for (final dir in dirs)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined,
                    size: 17, color: scheme.onSurfaceVariant),
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
                  icon: Icon(Icons.delete_outline, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
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
              icon: Icons.folder_open,
              variant: SButtonVariant.secondary,
              onPressed: _pickDirectory,
            ),
            const SizedBox(width: 8),
            SButton(
              label: l10n.folderAdd,
              icon: Icons.add,
              variant: SButtonVariant.primary,
              onPressed: _addManual,
            ),
          ],
        ),
      ],
    );
  }
}

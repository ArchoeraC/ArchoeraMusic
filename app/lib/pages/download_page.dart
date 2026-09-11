// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 下载页（任务列表：进度 / 暂停 / 取消 / 删除 / 清空 / 全部暂停·开始 / 批量操作）。
///
/// 纯展示层：状态全部来自 [downloadControllerProvider]（Rust 事件驱动），
/// 操作只调控制器接口，不触碰任何下载逻辑。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/downloader/download_controller.dart';
import '../../l10n/l10n.dart';
import '../widgets/common/toast.dart';
import '../widgets/download/delete_dialog.dart';
import '../widgets/download/download_task_tile.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'download/download_page_view.dart';

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
  Widget build(BuildContext context) => _buildDownloadPage(context);

  void _pauseAll() {
    ref.read(downloadControllerProvider.notifier).pauseAll();
    toast(context.l10n.toastPausedAll);
  }

  void _resumeAll() {
    ref.read(downloadControllerProvider.notifier).resumeAll();
    toast(context.l10n.toastResumedAll);
  }

  /// 批量选择模式下的紧凑图标操作。
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
    ref
        .read(downloadControllerProvider.notifier)
        .removeTasks(_selected.toList(), deleteFile: deleteFile);
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    toast(
      deleteFile
          ? l10n.toastDeletedSelectedWithMedia
          : l10n.toastDeletedSelected,
    );
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

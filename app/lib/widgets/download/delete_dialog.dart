import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../dialogs/s_dialog.dart';

/// 删除 / 清空确认弹窗的选择结果（null = 取消）。
enum DownloadDeleteChoice { taskOnly, withMedia }

/// 删除确认弹窗：取消 / 仅删除任务 / 删除任务及媒体文件（精确匹配）。
///
/// 用 [SDialog.show]（`Dialog` 透明根 + barrier 全局变暗）：若像早期实现
/// 那样把 [GlassDialogSurface]（不透明 ColoredBox）直接当 `showDialog`
/// 的 pageBuilder 根包住 [AlertDialog]，`AlertDialog` 内部 `Center` 会撑满
/// 窗口，面板跟着铺满全屏，变成「全遮罩」而非「全局变暗」。
Future<DownloadDeleteChoice?> showDownloadDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  final l10n = context.l10n;
  return SDialog.show<DownloadDeleteChoice>(
    context,
    title: title,
    description: message,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.commonCancel),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, DownloadDeleteChoice.taskOnly),
        child: Text(l10n.downloadDeleteTaskOnly),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, DownloadDeleteChoice.withMedia),
        child: Text(l10n.downloadDeleteWithMedia),
      ),
    ],
    child: const SizedBox.shrink(),
  );
}

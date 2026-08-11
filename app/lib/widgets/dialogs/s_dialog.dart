/// 圆角对话框（对齐 SPlayer-Next SDialog：标题 + 可选描述 + 内容 + 按钮行）。
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../common/glass_surface.dart';

class SDialog extends StatelessWidget {
  const SDialog({
    super.key,
    required this.title,
    this.description,
    this.actions = const [],
    this.width = 480,
    required this.child,
  });

  final String title;
  final String? description;
  final Widget child;

  /// 底部按钮行（通常为 SButton）。
  final List<Widget> actions;
  final double width;

  /// 弹出对话框（默认 barrier 点击不关闭）。
  ///
  /// 注意：`showDialog` 必须 `useRootNavigator: false` —— 应用用
  /// StatefulShellRoute.indexedStack（每个分支独立 Navigator），若挂到
  /// 根 Navigator，actions 里 `Navigator.of(context)`（页面 context 解析
  /// 到分支 Navigator）pop 会弹掉页面路由而非弹窗，导致界面卡死。
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    String? description,
    required Widget child,
    List<Widget> actions = const [],
    double width = 480,
  }) {
    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      useRootNavigator: false,
      builder: (_) => SDialog(
        title: title,
        description: description,
        actions: actions,
        width: width,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dialog = Theme.of(context).dialogTheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(48),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      // 裁剪整个弹窗画布到 shape 圆角（Dialog 默认 Clip.none，仅设 shape
      // 不会裁剪 child，会导致 ColoredBox/毛玻璃溢出成直角）
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
      ),
      clipBehavior: Clip.antiAlias,
      // 图片风格下为毛玻璃（blur(16)），背景图不再清晰透出
      child: GlassDialogSurface(
        radius: BorderRadius.circular(AppRadius.dialog),
        color: dialog.backgroundColor ?? scheme.surfaceContainerLow,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).dialogTheme.titleTextStyle),
                if (description != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    description!,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 480),
                  child: SingleChildScrollView(
                    child: child,
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        actions[i],
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

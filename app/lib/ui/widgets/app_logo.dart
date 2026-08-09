import 'package:flutter/material.dart';

/// 应用 Logo（白标）：圆角方块底 + 均衡器频谱图标。
///
/// 提取自侧边栏顶部品牌区（对齐 SideBarLogo.vue）：完全跟随全局主题
/// 对比色——底 primaryContainer、标 onPrimaryContainer；尺寸由 [size]
/// 驱动，圆角/图标按比例缩放，保证各处观感一致。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 30});

  /// Logo 边长（含底块）；默认 30（侧边栏尺寸）。
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        Icons.graphic_eq,
        size: size * 0.6,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}

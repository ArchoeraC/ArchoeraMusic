// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

/// 为「挂在 `MaterialApp.builder` 子树里、位于 Navigator **之上**」的门
/// （[VaultUnlockGate] / [VaultCrashGate] / [VaultVersionGate] 等）补一个
/// **Overlay 祖先**。
///
/// 背景（2026-10-14 实录）：`MaterialApp.builder` 的 `child` 是 Navigator，
/// Flutter 的 `Overlay` 在 Navigator **内部**；因此挂在它外面的门**没有
/// Overlay 祖先** → 门内 `EditableText`（口令 / 恢复码输入框）在聚焦、选择、
/// 粘贴时调用 `Overlay.of(context)` 拿到 null → release 构建下断言被剥掉，
/// `result!` 直接抛 `Null check operator used on a null value`
/// （现象：粘贴恢复码无效、平台报 "Failed to update editing state"、
/// 选择手柄/工具栏缺失）。
///
/// 本组件在门内部挂一个私有 [Overlay]，让文本选择手柄与工具栏有处可挂。
/// `OverlayEntry` **只创建一次**，父级重建时用 `markNeedsBuild` 同步内容
/// （避免每次重建都换 entry 导致焦点/滚动状态丢失）。
class OverlayHost extends StatefulWidget {
  const OverlayHost({super.key, required this.child});

  final Widget child;

  @override
  State<OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<OverlayHost> {
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => widget.child);

  @override
  void didUpdateWidget(OverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容随 widget.child 变化：entry 的 builder 在重建时才读 widget.child，
    // 这里显式标记重建（否则门内 setState 后内容不刷新）。
    if (oldWidget.child != widget.child) _entry.markNeedsBuild();
  }

  // 刻意**不**在 dispose 里手动 `_entry.dispose()`：entry 仍挂在子 Overlay 上时
  // Flutter 会断言「must first be removed from the Overlay」（本轮测试实录）。
  // 子 Overlay 自身 dispose 时会解绑该 entry，entry 对象随后即可回收。

  @override
  Widget build(BuildContext context) =>
      Overlay(initialEntries: <OverlayEntry>[_entry]);
}

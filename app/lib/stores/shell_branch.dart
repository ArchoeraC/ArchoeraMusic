// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 记录 `StatefulShellRoute` 最后停留的分支索引。
///
/// 全屏播放器完全展开时壳内容被真正卸载（释放列表/图片内存），
/// `StatefulNavigationShell` 随之销毁并在收起时重建。go_router 重建时会依
/// 据当前路由推导分支索引，但为稳妥起见，壳层把最近一次分支索引存于此处，
/// 并在重挂载后用 `StatefulNavigationShell.goBranch` 显式恢复。
final shellBranchIndexProvider =
    NotifierProvider<ShellBranchIndexNotifier, int>(
      ShellBranchIndexNotifier.new,
    );

class ShellBranchIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// 记录当前分支索引（相同则不动，避免无谓通知）。
  void set(int value) {
    if (state == value) return;
    state = value;
  }
}

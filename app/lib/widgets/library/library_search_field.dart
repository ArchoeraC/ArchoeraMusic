// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../player/s_controls.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 音乐库搜索框：文本由外部（[LibraryState.searchQuery]，见
/// `services/scanner/library_store.dart`）**单向驱动**，组件自身不持有真值。
///
/// 为什么必须这样：播放页完全展开时 [`ShellExpandTransition`](../../app/shell.dart)
/// 会把整个壳内容**卸载**（释放列表 / 图片内存），关闭播放页后本组件被重建。
/// 而搜索条件存在 Riverpod store 里（非 autoDispose，不随页面卸载消失）——
/// 若文本框自持状态（`SInput` 不传 `controller` 时正是如此），就会出现
/// 「**搜索框空了，但列表仍是筛选结果**」的不一致：用户看到的输入框等于没搜，
/// 列表却少了曲目，而且无从还原（除非重启或手动再搜一次）。
///
/// 语义：`query`（store）是唯一真值来源——
///  - 初次构建：按 [query] 回填（卸载重建后同样回填，搜索不丢）；
///  - 输入：经 [onChanged] 立即回写 store，再由 store 回灌（两者始终一致，
///    正常输入不会被打断光标 / 输入法组词）；
///  - 外部清空（含清除按钮）：文本随 [query] 一起清空。
class LibrarySearchField extends StatefulWidget {
  const LibrarySearchField({
    super.key,
    required this.query,
    required this.hintText,
    required this.onChanged,
    this.width = 190,
  });

  /// store 中的当前查询（真值来源）。
  final String query;

  final String hintText;

  /// 文本变化回调（调用方应写入 store，而不是只记住本地值）。
  final ValueChanged<String> onChanged;

  final double width;

  @override
  State<LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<LibrarySearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.query,
  );

  @override
  void didUpdateWidget(covariant LibrarySearchField old) {
    super.didUpdateWidget(old);
    // 仅在 store 与框内文本**不一致**时回灌：正常输入时两者相等（不打断光标 /
    // 输入法组词），被外部清空或卸载重建时能正确跟随。
    if (widget.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SInput(
    width: widget.width,
    hintText: widget.hintText,
    controller: _controller,
    prefixIcon: EtaIcons.search2,
    clearable: true,
    onChanged: widget.onChanged,
  );
}

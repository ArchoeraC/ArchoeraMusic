// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 音乐库搜索框的**状态一致性**回归。
//
// 背景（用户报告）：在音乐库搜索后打开全屏播放页再关闭——
//   · 搜索框被清空，但列表**仍是筛选结果**（不一致）。
// 成因：播放页完全展开时 `ShellExpandTransition` 会卸载整个壳内容（释放列表 /
// 图片内存，见 `lib/app/shell.dart`），关闭后音乐库页被**重建**；而搜索条件存在
// Riverpod `libraryStoreProvider`（非 autoDispose）里，不随页面卸载消失。
// 旧实现用不带 `controller` 的 `SInput`（文本自持于组件内部）→ 卸载即丢文本，
// 但 store 里的 query 仍在 → 「框空 + 列表已筛选」。
//
// 守卫：[LibrarySearchField] 的文本必须由 store 的 query **单向驱动**——
// 卸载重建后按 query 回填；输入回写 store；store 清空时文本跟随清空。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/widgets/library/library_search_field.dart';

/// 以「store」为外部真值搭建最小宿主柱：`show=false` 表示壳内容被卸载
/// （等价播放页完全展开后的 placeholder），`query` 表示 store 里存的搜索条件。
Future<void> _pump(
  WidgetTester tester, {
  required bool show,
  required String query,
  required ValueChanged<String> onChanged,
}) {
  return tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: show
              ? LibrarySearchField(
                  query: query,
                  hintText: '搜索',
                  onChanged: onChanged,
                )
              : const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('壳内容卸载重建后：文本按 store 回填（搜索不丢）', (tester) async {
    // 「store」：真值在组件之外，卸载不丢失（等价 libraryStoreProvider）。
    var store = '周杰伦';
    void onChanged(String q) => store = q;

    await _pump(tester, show: true, query: store, onChanged: onChanged);
    expect(_fieldText(tester), '周杰伦', reason: '初次构建按 store 回填');

    // 播放页完全展开 → 壳内容卸载（搜索框整棵子树被移除）
    await _pump(tester, show: false, query: store, onChanged: onChanged);
    expect(find.byType(TextField), findsNothing);

    // 关闭播放页 → 壳内容重建：文本必须仍是 store 里的查询（旧实现这里为空，
    // 而列表仍是筛选结果 → 用户可见的不一致）
    await _pump(tester, show: true, query: store, onChanged: onChanged);
    expect(_fieldText(tester), '周杰伦', reason: '重建后不得清空（列表仍按该查询筛选）');
  });

  testWidgets('输入回写 store；store 清空时文本跟随清空', (tester) async {
    var store = '';
    await _pump(
      tester,
      show: true,
      query: store,
      onChanged: (q) => store = q,
    );
    expect(_fieldText(tester), isEmpty);

    // 输入 → onChanged 回写 store（调用方写 store；这里模拟 store 同步生效）
    await tester.enterText(find.byType(TextField), '林俊杰');
    expect(store, '林俊杰', reason: '输入必须回写 store（真值来源）');

    // store 同步回灌：文本不变（不打断输入）
    await _pump(
      tester,
      show: true,
      query: store,
      onChanged: (q) => store = q,
    );
    expect(_fieldText(tester), '林俊杰');

    // 外部清空（如清除按钮 / 别处清空搜索）→ 文本跟随清空
    await _pump(tester, show: true, query: '', onChanged: (q) => store = q);
    expect(_fieldText(tester), isEmpty);
  });

  testWidgets('清除按钮：清空文本并回写空串', (tester) async {
    String? last;
    await _pump(
      tester,
      show: true,
      query: '周杰伦',
      onChanged: (q) => last = q,
    );
    expect(_fieldText(tester), '周杰伦');

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(_fieldText(tester), isEmpty);
    expect(last, '');
  });
}

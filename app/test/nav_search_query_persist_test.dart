// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 顶栏**全局搜索框**的状态一致性回归（与音乐库搜索框同一类问题）。
//
// 背景：顶栏位于壳内容之内，播放页完全展开时 `ShellExpandTransition` 会连同
// 列表/图片一起**卸载**它（见 `lib/app/shell.dart`），关闭播放页后重建——
// 文本若只存在组件内部的 `TextEditingController` 就会丢；而 `/search` 页的查询
// 来自路由 `?q=`（重建后按路由恢复并重新拉取），于是出现
// 「结果仍按旧关键词筛选，搜索框却空了」。
//
// 真值：[navSearchQueryProvider]（应用级 provider，跨壳内容卸载保留），
// 输入时写入、重建时回填（与 searchPlatformProvider 同法）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/shell_page_state.dart';
import 'package:archoera_music/widgets/layout/nav_header.dart';

/// 不读/写真实偏好文件（搜索历史等经它写入）。
class _NoSideEffectsPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('壳内容卸载重建后：顶栏搜索框按 provider 回填（查询不丢）', (tester) async {
    // 模拟壳内容卸载/重挂载：顶栏整棵子树被移出树（ProviderScope 常驻，
    // provider 状态因此保留——正是真实场景：壳内容卸载，应用级 provider 还在）。
    final mounted = ValueNotifier(true);
    addTearDown(mounted.dispose);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => ValueListenableBuilder<bool>(
            valueListenable: mounted,
            builder: (_, show, _) => Scaffold(
              body: show ? const NavHeader() : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );

    Future<void> pump() => tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );

    await pump();
    expect(_fieldText(tester), isEmpty, reason: '初始为空');

    // 输入查询（写入 provider）
    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump();
    expect(_fieldText(tester), '晴天');

    // 播放页完全展开 → 顶栏（壳内容）卸载
    mounted.value = false;
    await tester.pump();
    expect(find.byType(NavHeader), findsNothing);
    expect(find.byType(TextField), findsNothing);

    // 关闭播放页 → 顶栏重建：文本必须仍是 provider 里的查询（旧实现这里为空，
    // 而 `/search` 页仍按路由 q 展示结果 → 用户可见的不一致）
    mounted.value = true;
    await tester.pump();
    expect(_fieldText(tester), '晴天', reason: '重建后不得清空（搜索页仍按该查询展示）');
  });

  testWidgets('清空搜索框：provider 一并清空（不留旧查询）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Scaffold(body: NavHeader())),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.pump();
    expect(container.read(navSearchQueryProvider), '周杰伦');

    // 清除按钮（SInput.clearable）→ 文本清空并回写 provider
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(_fieldText(tester), isEmpty);
    expect(container.read(navSearchQueryProvider), isEmpty);
  });
}

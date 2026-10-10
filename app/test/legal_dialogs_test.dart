// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 回归测试：关于页的三份长文（软件声明 / 隐私政策 / 字体署名）以「点击按钮
// 才展开」的弹窗呈现，且内容完整（含新增的开源许可章节与隐私政策章节）、
// 长文本滚动不溢出。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/widgets/dialogs/legal_dialogs.dart';

void main() {
  Widget host(void Function(BuildContext) open) {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(
    WidgetTester tester,
    void Function(BuildContext) open,
  ) async {
    await tester.pumpWidget(host(open));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('软件声明弹窗：含开源许可章节与页脚', (tester) async {
    await openDialog(tester, showSoftwareDeclarationDialog);
    expect(find.text('软件声明'), findsOneWidget);
    // 新增章节：开源许可与源代码。
    expect(find.textContaining('开源许可与源代码'), findsOneWidget);
    // 补充章节：未成年人使用。
    expect(find.textContaining('未成年人使用'), findsOneWidget);
    // 页脚。
    expect(find.textContaining('仅用于技术探索与研究'), findsOneWidget);
  });

  testWidgets('隐私政策弹窗：含基本原则与联系我们', (tester) async {
    await openDialog(tester, showPrivacyPolicyDialog);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.textContaining('一、基本原则'), findsOneWidget);
    expect(find.textContaining('九、联系我们'), findsOneWidget);
    expect(find.textContaining('GitHub 仓库与 Issue'), findsOneWidget);
  });

  testWidgets('字体署名弹窗：含各内置字体与官方许可正文', (tester) async {
    await openDialog(tester, showFontCreditsDialog);
    expect(find.text('字体署名'), findsOneWidget);
    // 简介列出全部内置字体（MiSans / Manrope 等）。
    expect(find.textContaining('MiSans'), findsWidgets);
    expect(find.textContaining('Manrope'), findsWidgets);
    // 随弹窗内嵌展示官方许可正文原文。
    expect(find.textContaining('SIL OPEN FONT LICENSE'), findsWidgets);
    expect(find.textContaining('MiSans字体知识产权许可协议'), findsWidgets);
  });
}

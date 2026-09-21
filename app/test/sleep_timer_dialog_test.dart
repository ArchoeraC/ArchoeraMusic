// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 睡眠定时弹窗回归测试：自定义分钟数（校验/取消）与快捷预设编辑
/// （添加/去重/删除/落盘返回）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/dialogs/sleep_timer_dialogs.dart';

/// 不读写磁盘的偏好 Notifier。
class _TestPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

Widget _host({required void Function(BuildContext) open}) {
  return ProviderScope(
    overrides: [appPrefsProvider.overrideWith(() => _TestPrefsNotifier())],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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

void main() {
  testWidgets('自定义分钟数：非法输入报错，合法输入返回并回填', (tester) async {
    int? result;
    await tester.pumpWidget(
      _host(
        open: (context) async {
          result = await showSleepTimerMinutesDialog(context);
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Custom sleep timer'), findsOneWidget);
    // 默认初始值 30 已回填。
    expect(find.widgetWithText(TextField, '30'), findsOneWidget);

    // 非法（0）→ 弹错误、不关闭。
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Enter minutes between 1 and 600'), findsOneWidget);
    expect(find.text('Custom sleep timer'), findsOneWidget);

    // 合法（45）→ 返回。
    await tester.enterText(find.byType(TextField), '45');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(result, 45);
  });

  testWidgets('自定义分钟数：取消返回 null', (tester) async {
    var called = false;
    int? result;
    await tester.pumpWidget(
      _host(
        open: (context) async {
          called = true;
          result = await showSleepTimerMinutesDialog(context);
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(called, isTrue);
    expect(result, isNull);
  });

  testWidgets('预设编辑：添加/去重/删除后返回新列表', (tester) async {
    List<int>? result;
    await tester.pumpWidget(
      _host(
        open: (context) async {
          result = await showSleepTimerPresetsDialog(context, const [15, 30]);
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputChip, '15 minutes'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '30 minutes'), findsOneWidget);

    // 重复项 → 报错。
    await tester.enterText(find.byType(TextField), '15');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('That duration is already a preset'), findsOneWidget);

    // 新项 45 → 生成 chip。
    await tester.enterText(find.byType(TextField), '45');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '45 minutes'), findsOneWidget);

    // 删除 15。
    final chip15 = find.ancestor(
      of: find.text('15 minutes'),
      matching: find.byType(InputChip),
    );
    await tester.tap(
      find.descendant(
        of: chip15,
        matching: find.byIcon(EtaIcons.deleteOutline),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '15 minutes'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(result, [30, 45]);
  });

  testWidgets('预设编辑：删光后返回空列表', (tester) async {
    List<int>? result;
    await tester.pumpWidget(
      _host(
        open: (context) async {
          result = await showSleepTimerPresetsDialog(context, const [20]);
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final chip20 = find.ancestor(
      of: find.text('20 minutes'),
      matching: find.byType(InputChip),
    );
    await tester.tap(
      find.descendant(
        of: chip20,
        matching: find.byIcon(EtaIcons.deleteOutline),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No presets'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });
}

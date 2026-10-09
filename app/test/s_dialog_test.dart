// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [SDialog] 矮窗口布局回归测试。
///
/// 复现并锁定「小窗口下滚不到底部、点不到保存按钮」的问题：内容超高时，
/// 内容区必须可滚动、按钮行必须始终落在屏幕内且可点击。此前内容区固定高度 +
/// 整体不滚动，矮窗会把按钮推出可视区。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/dialogs/s_dialog.dart';

/// 测试用偏好：不落盘（避免测试写入真实 prefs.json）。
class _FakeAppPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

void main() {
  testWidgets('矮窗口 + 超高内容：按钮行仍在屏幕内且可点击', (tester) async {
    tester.view.physicalSize = const Size(900, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var tapped = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appPrefsProvider.overrideWith(_FakeAppPrefsNotifier.new)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => SDialog.show<void>(
                    context,
                    title: 'Title',
                    width: 560,
                    actions: [
                      TextButton(
                        onPressed: () => tapped = true,
                        child: const Text('ACTION'),
                      ),
                    ],
                    child: Column(
                      children: [
                        for (var i = 0; i < 40; i++)
                          const SizedBox(height: 40, child: Text('row')),
                      ],
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final action = find.text('ACTION');
    expect(action, findsOneWidget);

    // 按钮行必须落在屏幕内（未被超高内容挤出可视区）。
    final rect = tester.getRect(action);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(620));

    // 且可点击。
    await tester.tap(action);
    await tester.pump();
    expect(tapped, isTrue);
  });
}

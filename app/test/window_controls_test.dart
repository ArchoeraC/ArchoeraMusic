// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 无边框窗口控件回归：
/// - ghost 按钮无底色时必须保持透明（`Colors.transparent.withValues(alpha: 1)`
///   曾变成不透明黑，窗口按钮出现黑色圆底）；
/// - 自动隐藏：默认隐藏 + 不接收点击；指针进入右上角热区显示，移出后收回。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/prefs_appearance.dart';
import 'package:archoera_music/widgets/layout/nav_header.dart';
import 'package:archoera_music/widgets/layout/window_controls.dart';
import 'package:archoera_music/widgets/player/s_controls.dart';

class _PrefsNotifier extends AppPrefsNotifier {
  _PrefsNotifier(this.initialData);

  final Map<String, dynamic> initialData;

  @override
  AppPrefs build() => AppPrefs(initialData: {...initialData});
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('ghost 圆形按钮保持透明底色', (tester) async {
    await tester.pumpWidget(
      _app(
        Center(
          child: SButton(
            label: 'close',
            icon: Icons.close,
            variant: SButtonVariant.ghost,
            circle: true,
            onPressed: () {},
          ),
        ),
      ),
    );

    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(SButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color?.a, 0, reason: '幽灵按钮不应带任何不透明底色');
  });

  testWidgets('无边框自动隐藏：热区唤出、移出收回，隐藏态不接收点击', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _PrefsNotifier({
              windowDecorKey: 'borderless',
              autoHideWindowControlsKey: true,
            }),
          ),
        ],
        child: _app(const NavHeader()),
      ),
    );
    await tester.pumpAndSettle();

    AnimatedOpacity controlsOpacity() => tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byType(WindowControls),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    IgnorePointer controlsHitTest() => tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(WindowControls),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );

    // 初始：按钮透明且不接收指针。
    expect(controlsOpacity().opacity, 0);
    expect(controlsHitTest().ignoring, isTrue);

    // 指针移到右上角热区（顶栏顶部窄条）→ 显示。
    final header = tester.getRect(find.byType(NavHeader));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(Offset(header.right - 24, header.top + 4));
    await tester.pumpAndSettle();
    expect(controlsOpacity().opacity, 1);
    expect(controlsHitTest().ignoring, isFalse);

    // 指针离开 → 延迟后收回。
    await gesture.moveTo(Offset(header.left + 120, header.top + 40));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(controlsOpacity().opacity, 0);
    expect(controlsHitTest().ignoring, isTrue);
  });

  testWidgets('右上角下滑手势也能唤出按钮，并保留操作时间', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _PrefsNotifier({
              windowDecorKey: 'borderless',
              autoHideWindowControlsKey: true,
            }),
          ),
        ],
        child: _app(const NavHeader()),
      ),
    );
    await tester.pumpAndSettle();

    final header = tester.getRect(find.byType(NavHeader));
    final gesture = await tester.startGesture(
      Offset(header.right - 60, header.top + 4),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(0, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    AnimatedOpacity controlsOpacity() => tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byType(WindowControls),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );

    // 下滑唤出后立即显示。
    expect(controlsOpacity().opacity, 1);

    // 手势唤出有约 2.4s 的停留时间：1s 后仍在，足够移向按钮点击。
    await tester.pump(const Duration(seconds: 1));
    expect(controlsOpacity().opacity, 1);

    // 超时后自动收回。
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pumpAndSettle();
    expect(controlsOpacity().opacity, 0);
  });

  testWidgets('自动隐藏窗口按钮时天气组件随头像/菜单一起右移', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _PrefsNotifier({
              windowDecorKey: 'borderless',
              autoHideWindowControlsKey: true,
              // 未配置位置 → 只显示占位云图标，不发网络请求。
              weatherEnabledKey: true,
            }),
          ),
        ],
        child: _app(const NavHeader()),
      ),
    );
    await tester.pumpAndSettle();

    final weatherIcon = find.descendant(
      of: find.byType(NavHeader),
      matching: find.byIcon(EtaIcons.cloudOutline),
    );
    expect(weatherIcon, findsOneWidget, reason: '天气组件应已渲染');

    // 隐藏态：整组右移；显示态：归位。两者差值应正好是按钮占位宽度。
    final hiddenRight = tester.getTopRight(weatherIcon).dx;
    final header = tester.getRect(find.byType(NavHeader));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(Offset(header.right - 24, header.top + 4));
    await tester.pumpAndSettle();

    final shownRight = tester.getTopRight(weatherIcon).dx;
    expect(
      hiddenRight - shownRight,
      closeTo(125, 0.5),
      reason: '天气组件必须和头像/菜单一起移动，否则右侧会留下空洞',
    );
  });

  testWidgets('未开启自动隐藏时按钮始终可见、可点击', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _PrefsNotifier({windowDecorKey: 'borderless'}),
          ),
        ],
        child: _app(const NavHeader()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.byType(WindowControls),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity,
      1,
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byType(WindowControls),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isFalse,
    );
  });
}

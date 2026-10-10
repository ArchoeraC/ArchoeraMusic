// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 愚人节特供「整活模式」回归测试：触发/投降语义 + 滚轮反向。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/easter_egg/april_fools_state.dart';
import 'package:archoera_music/easter_egg/easter_egg.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 内存偏好桩：只改内存、不落盘（避免测试写真实 prefs.json）。
class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this._initial);

  final AppPrefs _initial;

  @override
  AppPrefs build() => _initial;

  @override
  void setAprilFools(bool value) => state = state.copyWithAprilFools(value);

  @override
  void setAprilFoolsSurrenderedYear(int year) =>
      state = state.copyWithAprilFoolsSurrenderedYear(year);

  @override
  void setAprilFoolsEnabled(bool value) =>
      state = state.copyWithAprilFoolsEnabled(value);
}

void main() {
  group('shouldAutoActivate（纯函数）', () {
    test('仅 4/1 且当年未投降时激活', () {
      final DateTime apr1 = DateTime(2030, 4, 1);
      final DateTime apr2 = DateTime(2030, 4, 2);

      expect(
        shouldAutoActivate(
          now: apr1,
          active: false,
          surrenderedYear: null,
          safeMode: false,
          force: null,
        ),
        isTrue,
        reason: '4/1 应激活',
      );
      expect(
        shouldAutoActivate(
          now: apr2,
          active: false,
          surrenderedYear: null,
          safeMode: false,
          force: null,
        ),
        isFalse,
        reason: '非 4/1 不激活',
      );
    });

    test('投降当年不再激活，次年恢复', () {
      bool at(DateTime now, int? surrendered) => shouldAutoActivate(
        now: now,
        active: false,
        surrenderedYear: surrendered,
        safeMode: false,
        force: null,
      );
      expect(at(DateTime(2030, 4, 1), 2030), isFalse, reason: '投降当年不激活');
      expect(at(DateTime(2031, 4, 1), 2030), isTrue, reason: '次年恢复');
    });

    test('已激活时重申保留（跨重启）', () {
      expect(
        shouldAutoActivate(
          now: DateTime(2030, 4, 2),
          active: true,
          surrenderedYear: null,
          safeMode: false,
          force: null,
        ),
        isTrue,
        reason: '持久化的激活态应保留',
      );
    });

    test('安全模式禁用；环境覆盖优先', () {
      expect(
        shouldAutoActivate(
          now: DateTime(2030, 4, 1),
          active: false,
          surrenderedYear: null,
          safeMode: true,
          force: null,
        ),
        isFalse,
        reason: '安全模式恒关闭',
      );
      expect(
        shouldAutoActivate(
          now: DateTime(2030, 4, 2),
          active: false,
          surrenderedYear: null,
          safeMode: false,
          force: true,
        ),
        isTrue,
        reason: 'ARCHOERA_EGG_FOOL=1 强制开启',
      );
      expect(
        shouldAutoActivate(
          now: DateTime(2030, 4, 1),
          active: true,
          surrenderedYear: null,
          safeMode: false,
          force: false,
        ),
        isFalse,
        reason: 'ARCHOERA_EGG_FOOL=0 强制关闭优先于已激活',
      );
    });

    test('开关关闭后 4/1 也不激活；强制环境仍可覆盖', () {
      expect(
        shouldAutoActivate(
          now: DateTime(2030, 4, 1),
          active: false,
          surrenderedYear: null,
          safeMode: false,
          force: null,
          enabled: false,
        ),
        isFalse,
        reason: '关闭开关后永不自动激活',
      );
      expect(
        shouldAutoActivate(
          now: DateTime(2030, 4, 1),
          active: false,
          surrenderedYear: null,
          safeMode: false,
          force: true,
          enabled: false,
        ),
        isTrue,
        reason: 'ARCHOERA_EGG_FOOL=1 调试覆盖优先于开关',
      );
    });
  });

  group('AprilFoolsNotifier', () {
    test('4/1 自动激活并持久化；投降记录年份并关闭；次年恢复', () {
      final container = ProviderContainer(
        overrides: [
          appPrefsProvider.overrideWith(() => _StubPrefs(AppPrefs())),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(aprilFoolsProvider.notifier);

      expect(notifier.active, isFalse);

      notifier.maybeAutoActivate(DateTime(2030, 4, 2));
      expect(notifier.active, isFalse, reason: '非 4/1 不激活');

      notifier.maybeAutoActivate(DateTime(2030, 4, 1));
      expect(notifier.active, isTrue);
      expect(
        container.read(appPrefsProvider).aprilFools,
        isTrue,
        reason: '激活需持久化',
      );

      notifier.surrender();
      expect(notifier.active, isFalse);
      final AppPrefs prefs = container.read(appPrefsProvider);
      expect(prefs.aprilFools, isFalse, reason: '投降后关闭');
      expect(
        prefs.aprilFoolsSurrenderedYear,
        DateTime.now().year,
        reason: '投降记录当前年份',
      );

      notifier.maybeAutoActivate(DateTime(DateTime.now().year, 4, 1));
      expect(notifier.active, isFalse, reason: '投降当年不再自动激活');

      notifier.maybeAutoActivate(DateTime(DateTime.now().year + 1, 4, 1));
      expect(notifier.active, isTrue, reason: '次年恢复');
    });

    test('持久化的激活态跨重启保留（非 4/1 也重申）', () {
      final container = ProviderContainer(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _StubPrefs(AppPrefs().copyWithAprilFools(true)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(aprilFoolsProvider.notifier);

      expect(notifier.active, isTrue, reason: '启动即读持久化激活态');
      notifier.maybeAutoActivate(DateTime(2030, 6, 1));
      expect(notifier.active, isTrue, reason: '非 4/1 也重申保留');
    });

    test('disable 硬关闭但不写投降年份', () {
      final container = ProviderContainer(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _StubPrefs(AppPrefs().copyWithAprilFools(true)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(aprilFoolsProvider.notifier);

      notifier.disable();
      expect(notifier.active, isFalse);
      final AppPrefs prefs = container.read(appPrefsProvider);
      expect(prefs.aprilFools, isFalse);
      expect(prefs.aprilFoolsSurrenderedYear, isNull, reason: '硬关闭不写投降年份');
    });

    test('setEnabled(false) 立即关闭；disableForever 永久禁用', () {
      final container = ProviderContainer(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _StubPrefs(AppPrefs().copyWithAprilFools(true)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(aprilFoolsProvider.notifier);

      notifier.setEnabled(false);
      expect(notifier.active, isFalse, reason: '关闭开关应立即恢复');
      expect(container.read(appPrefsProvider).aprilFoolsEnabled, isFalse);

      // 再开启并整活，然后「以后不再整活」应永久禁用。
      notifier.setEnabled(true);
      notifier.maybeAutoActivate(DateTime(2030, 4, 1));
      expect(notifier.active, isTrue);
      notifier.disableForever();
      final AppPrefs prefs = container.read(appPrefsProvider);
      expect(notifier.active, isFalse);
      expect(prefs.aprilFoolsEnabled, isFalse, reason: '永久禁用自动激活');
      expect(prefs.aprilFools, isFalse);
      // 永久禁用后，即便 4/1 也不再激活。
      notifier.maybeAutoActivate(DateTime(2030, 4, 1));
      expect(notifier.active, isFalse);
    });
  });

  testWidgets('PrankScrollPosition：整活模式滚轮方向取反', (WidgetTester tester) async {
    final controller = PrankScrollController(initialScrollOffset: 200);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PrimaryScrollController(
          controller: controller,
          automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
          scrollDirection: Axis.vertical,
          child: ListView(
            children: List<Widget>.generate(
              100,
              (int i) => SizedBox(height: 40, child: Text('row $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(controller.offset, 200);

    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(ListView)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();

    // 正常方向 200 + 100 = 300；取反后 200 - 100 = 100。
    expect(controller.offset, 100, reason: '整活模式下滚轮方向应反转');
  });

  group('AprilFoolsHost', () {
    Future<void> pumpHost(WidgetTester tester, bool active) async {
      final container = ProviderContainer(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _StubPrefs(AppPrefs().copyWithAprilFools(active)),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: AprilFoolsHost(
              child: const Scaffold(body: Center(child: Text('主体'))),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('激活时整屏镜像 + 显示「我投降」按钮', (WidgetTester tester) async {
      await pumpHost(tester, true);

      final Iterable<Transform> transforms = tester.widgetList<Transform>(
        find.ancestor(of: find.text('主体'), matching: find.byType(Transform)),
      );
      expect(
        transforms.any((Transform t) => t.transform.entry(0, 0) == -1.0),
        isTrue,
        reason: '整活模式应施加左右镜像',
      );
      expect(find.text('我投降 🙌'), findsOneWidget);
    });

    testWidgets('未激活时透传（无镜像、无按钮）', (WidgetTester tester) async {
      await pumpHost(tester, false);

      final Iterable<Transform> transforms = tester.widgetList<Transform>(
        find.ancestor(of: find.text('主体'), matching: find.byType(Transform)),
      );
      expect(
        transforms.any((Transform t) => t.transform.entry(0, 0) == -1.0),
        isFalse,
        reason: '未激活不应镜像',
      );
      expect(find.text('我投降 🙌'), findsNothing);
    });

    testWidgets('激活时路由内 ScrollView 滚轮方向取反', (WidgetTester tester) async {
      final controller = ScrollController(initialScrollOffset: 200);
      addTearDown(controller.dispose);
      final container = ProviderContainer(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _StubPrefs(AppPrefs().copyWithAprilFools(true)),
          ),
        ],
      );
      addTearDown(container.dispose);

      // 真实结构：AprilFoolsHost 在 MaterialApp.builder 中包住 Navigator。
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (BuildContext context, Widget? child) =>
                AprilFoolsHost(child: child ?? const SizedBox.shrink()),
            home: Scaffold(
              body: ListView(
                controller: controller,
                children: List<Widget>.generate(
                  100,
                  (int i) => SizedBox(height: 40, child: Text('row $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(controller.offset, 200);

      final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(find.byType(ListView)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();

      // 正常 200 + 100 = 300；整活反向 200 - 100 = 100。
      expect(controller.offset, 100, reason: '路由内滚轮应反向');
    });
  });
}

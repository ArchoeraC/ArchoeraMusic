// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 愚人节特供「奇怪的特效」回归测试：一次性开启语义 + 会话内激活 + 滚轮反向。
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
  void setAprilFoolsUsedYear(int year) =>
      state = state.copyWithAprilFoolsUsedYear(year);
}

/// 构造一个带内存偏好的容器（自动释放）。
ProviderContainer _container([AppPrefs? prefs]) {
  final container = ProviderContainer(
    overrides: [
      appPrefsProvider.overrideWith(() => _StubPrefs(prefs ?? AppPrefs())),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('shouldOfferAprilFools（纯函数）', () {
    test('仅 4/1 且今年未开启过时提供开关', () {
      expect(
        shouldOfferAprilFools(now: DateTime(2030, 4, 1), usedYear: null),
        isTrue,
        reason: '4/1 且未用过 → 提供',
      );
      expect(
        shouldOfferAprilFools(now: DateTime(2030, 4, 2), usedYear: null),
        isFalse,
        reason: '非 4/1 不提供',
      );
      expect(
        shouldOfferAprilFools(now: DateTime(2030, 4, 1), usedYear: 2030),
        isFalse,
        reason: '今年已开启过 → 不再提供',
      );
      expect(
        shouldOfferAprilFools(now: DateTime(2031, 4, 1), usedYear: 2030),
        isTrue,
        reason: '次年 4/1 重新提供',
      );
    });

    test('安全模式禁用；环境覆盖优先', () {
      expect(
        shouldOfferAprilFools(
          now: DateTime(2030, 4, 1),
          usedYear: null,
          safeMode: true,
        ),
        isFalse,
        reason: '安全模式恒关闭',
      );
      expect(
        shouldOfferAprilFools(
          now: DateTime(2030, 6, 1),
          usedYear: 2030,
          force: true,
        ),
        isTrue,
        reason: 'ARCHOERA_EGG_FOOL=1 强制提供（调试）',
      );
      expect(
        shouldOfferAprilFools(
          now: DateTime(2030, 4, 1),
          usedYear: null,
          force: false,
        ),
        isFalse,
        reason: 'ARCHOERA_EGG_FOOL=0 强制关闭优先',
      );
    });
  });

  group('AprilFoolsNotifier（一次性开启）', () {
    test('开启即激活并消耗今年机会；本年不再提供，次年恢复', () {
      final container = _container();
      final notifier = container.read(aprilFoolsProvider.notifier);

      expect(notifier.active, isFalse, reason: '默认关闭');

      notifier.activate(2030);
      expect(notifier.active, isTrue, reason: '开启后本次运行内激活');
      expect(
        container.read(appPrefsProvider).aprilFoolsUsedYear,
        2030,
        reason: '开启即记录消耗年份',
      );

      expect(
        notifier.shouldOffer(DateTime(2030, 4, 1)),
        isFalse,
        reason: '本年已消耗 → 不再提供',
      );
      expect(
        notifier.shouldOffer(DateTime(2031, 4, 1)),
        isTrue,
        reason: '次年 4/1 恢复',
      );
    });

    test('投降结束特效，但不退还开启机会', () {
      final container = _container();
      final notifier = container.read(aprilFoolsProvider.notifier);

      notifier.activate(2030);
      notifier.surrender();
      expect(notifier.active, isFalse, reason: '投降立即恢复');
      expect(
        container.read(appPrefsProvider).aprilFoolsUsedYear,
        2030,
        reason: '投降不退还开启机会',
      );
      expect(notifier.shouldOffer(DateTime(2030, 4, 1)), isFalse);
    });

    test('特效不落盘：重启（新容器）后不激活，开关也不再出现', () {
      final container = _container(AppPrefs().copyWithAprilFoolsUsedYear(2030));
      final notifier = container.read(aprilFoolsProvider.notifier);

      expect(notifier.active, isFalse, reason: '会话内状态不跨重启保留');
      expect(
        notifier.shouldOffer(DateTime(2030, 4, 1)),
        isFalse,
        reason: '重启后开关也不恢复',
      );
    });

    test('disable 硬关闭', () {
      final container = _container();
      final notifier = container.read(aprilFoolsProvider.notifier);

      notifier.activate(2030);
      notifier.disable();
      expect(notifier.active, isFalse);
      expect(
        container.read(appPrefsProvider).aprilFoolsUsedYear,
        2030,
        reason: '硬关闭不影响已消耗的机会',
      );
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
      final container = _container();
      if (active) {
        container.read(aprilFoolsProvider.notifier).activate(2030);
      }
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
      final container = _container();
      container.read(aprilFoolsProvider.notifier).activate(2030);

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

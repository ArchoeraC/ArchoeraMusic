// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 设置搜索：命中后不只是切分类，还要滚到对应设置行并高亮几次。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/settings/settings_dialog.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 测试字体（Ahem）比真实字体宽近一倍，设置行会报 RenderFlex 溢出；
/// 这些是与本用例无关的布局告警，过滤掉（真实字体下不溢出）。
void _ignoreTestFontOverflow() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('RenderFlex overflowed')) return;
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

/// 不落盘的偏好容器（避免测试写入真实 prefs.json）。
class _NoSavePrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

void main() {
  testWidgets('搜索命中：切分类 → 滚动到目标行 → 闪高亮', (tester) async {
    _ignoreTestFontOverflow();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    );
    addTearDown(container.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SettingsDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 「界面语言」在 Appearance 分类靠下，需要滚动才能看到。
    await tester.enterText(find.byType(TextField), 'language');
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.settingsLanguageTitle));
    await tester.pump();
    // 等一帧构建新分类 + 滚动动画（320ms）结束。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 400));

    // 小节标题与设置行同名（Interface language），设置行在后。
    final row = find.text(l10n.settingsLanguageTitle).last;
    expect(row, findsOneWidget);

    // 目标行已进入视口且被滚动过（不是停在顶部）。
    final scrollable = find
        .ancestor(of: row, matching: find.byType(Scrollable))
        .first;
    final offset = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset, greaterThan(0));

    // 高亮框出现，且与目标行重叠。
    final flash = find.byType(SettingsRowFlash);
    expect(flash, findsOneWidget);
    final rowRect = tester.getRect(row);
    final flashRect = tester.getRect(flash);
    expect(flashRect.overlaps(rowRect), isTrue);

    // 脉冲结束后自动移除，不残留。
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byType(SettingsRowFlash), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换分类回到顶部（不继承上一个分类的滚动位置）', (tester) async {
    _ignoreTestFontOverflow();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    );
    addTearDown(container.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SettingsDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先把 Appearance 滚到底部。
    final content = find
        .ancestor(
          of: find.text(l10n.settingsThemeMode),
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(content).position.jumpTo(400);
    await tester.pump();

    // 切到「播放」再切回：内容区应回到顶部。
    await tester.tap(find.text(l10n.settingsCatRender));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.settingsCatAppearance));
    await tester.pumpAndSettle();
    final restored = find
        .ancestor(
          of: find.text(l10n.settingsThemeMode),
          matching: find.byType(Scrollable),
        )
        .first;
    expect(tester.state<ScrollableState>(restored).position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('彩蛋入口默认不可见，搜索暗号后才浮现（仅本次弹窗）', (tester) async {
    _ignoreTestFontOverflow();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    );
    addTearDown(container.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SettingsDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 关于页滚到底也不该出现「千万别点」。
    await tester.scrollUntilVisible(
      find.text(l10n.settingsCatAbout),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(l10n.settingsCatAbout));
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsNeverTap), findsNothing);

    // 普通查询不会带出入口。
    final field = find.byType(TextField).first;
    await tester.enterText(field, 'egg');
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsNeverTap), findsNothing);

    // 精确输入暗号（大小写随意）→ 搜索结果出现入口。
    await tester.enterText(field, 'ArchoeraMusic.PowerFull.Settings');
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsNeverTap), findsOneWidget);

    // 清空搜索：入口在本次弹窗内保持，回关于页底部仍可见。
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsNeverTap), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索索引覆盖动态标题与自定义卡片', (tester) async {
    _ignoreTestFontOverflow();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [appPrefsProvider.overrideWith(_NoSavePrefs.new)],
    );
    addTearDown(container.dispose);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SettingsDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byType(TextField).first;
    // 曾漏索引的几类：辅助方法参数标题（缓存 / 扫描 / 安全销毁）、
    // SettingsAnchor 自定义卡片（默认音源 / 转码档位）、箭头函数标题（MCP 能力）。
    final titles = <String>[
      l10n.settingsCacheLiked,
      l10n.settingsScanMaxFileSizeMb,
      l10n.settingsSecurityStreaming,
      l10n.settingsDefaultSource,
      l10n.streamingQualityTitle,
      l10n.settingsMcpCapRead,
    ];
    for (final title in titles) {
      await tester.enterText(field, title);
      await tester.pumpAndSettle();
      // 一条是搜索框里的输入文本，另一条是命中的结果行。
      expect(find.text(title), findsNWidgets(2), reason: title);
    }

    // 命中后能跳到对应设置行并高亮（锚点与索引标题一致）。
    await tester.enterText(field, l10n.settingsSecurityStreaming);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.settingsSecurityStreaming).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SettingsRowFlash), findsOneWidget);
    // 安全区初始化会起一个 15s 的 vault 探测超时定时器，推进到超时再收尾。
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

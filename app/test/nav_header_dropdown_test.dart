// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 搜索下拉定位验证：聚焦搜索框后，下拉面板（_SearchDropdown 内的
// SingleChildScrollView）应紧贴搜索框底边且左对齐、宽度与搜索框一致。
//
// 说明：override appPrefsProvider 避免读取真实用户偏好文件（无副作用）；
// 其余 provider（theme/netease）无文件副作用，保持真实实现（聚焦触发的
// 热搜请求在 flutter_test 中被 HttpOverrides 拦截返回 400 → 静默失败）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:archoera_music/app/shell_expand_transition.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/player_route_animation.dart';
import 'package:archoera_music/widgets/layout/nav_header.dart';

/// 回归（2026-10）：搜索栏**展开后不能保持**——旧实现用 `Positioned.fill` 不透明拦截层收起下拉，
/// 该层盖在搜索框之上，于是「展开后再次点击搜索框 / 点清除按钮 / 重新定位光标」都被判成
/// 「点外部」→ 失焦收起。修复后：搜索框与下拉面板同属一个 `TapRegion` 组，只有点到组外才收起，
/// 且**外部那一次点击不再被吞掉**（旧拦截层会吃掉首次外部点击）。
///
/// 测试用 AppPrefsNotifier：build 返回空预置（不读/写磁盘）。
class _NoSideEffectsPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

void main() {
  testWidgets('聚焦后下拉面板贴紧搜索框底边、左对齐、宽度一致', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => const Scaffold(body: NavHeader()),
              ),
            ],
          ),
        ),
      ),
    );

    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);

    // 聚焦搜索框 → 展开下拉（宽度 280→420 + 面板展开动画）
    await tester.tap(textField);
    await tester.pump();

    // 面板 = 下拉内容滚动容器（_SearchDropdown 私有类，以其内容定位）
    final panel = find.byType(SingleChildScrollView);
    expect(panel, findsOneWidget);

    // 动画中途：宽度动画 260ms，推进到一半确保全程对齐（修复前
    // 面板被宽松约束撑满 + topCenter 居中 → 动画中错位动态变化）
    await tester.pump(const Duration(milliseconds: 130));
    _expectAligned(tester, textField, panel);

    // 动画结束：pumpAndSettle 等宽度/展开动画全部完成
    await tester.pumpAndSettle();
    _expectAligned(tester, textField, panel);
  });

  testWidgets('聚焦后搜索框宽度伸展至 420，失焦后收回 280', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => const Scaffold(body: NavHeader()),
              ),
            ],
          ),
        ),
      ),
    );

    final textField = find.byType(TextField);
    expect(tester.getSize(textField).width, closeTo(280, 0.5));

    // 聚焦 → 宽度动画 280→420（修复前父级不随动画重建，输入框宽度卡死 280）
    await tester.tap(textField);
    await tester.pumpAndSettle();
    expect(tester.getSize(textField).width, closeTo(420, 0.5));

    // 点击外部收起 → 宽度收回 280（修复前展开后无法收缩）
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.getSize(textField).width, closeTo(280, 0.5));
  });

  _searchBarKeepsOpenRegression();
  _shellUnmountRegression();
  _playerExpandRegression();
}

/// 回归（2026-10）：播放页开始展开时，搜索下拉浮层（挂在**根 Overlay**，不在
/// 壳子树内、不随壳内容缩放淡出）必须立刻收起，而不是悬在播放页上方。
void _playerExpandRegression() {
  testWidgets('播放页路由动画开始展开 → 搜索下拉收起并摘除', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: NavHeader()),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    // 模拟 PlayerPage 写入路由动画并开始展开（0 → 1）
    final routeCtrl = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 500),
    );
    addTearDown(routeCtrl.dispose);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NavHeader)),
    );
    container.read(playerRouteAnimationProvider.notifier).set(routeCtrl);
    routeCtrl.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 收起动画（360ms）走完 → 浮层从 Overlay 摘除
    await tester.pumpAndSettle();
    expect(
      find.byType(SingleChildScrollView),
      findsNothing,
      reason: '播放页展开时下拉浮层必须收起，不能悬在播放页上方',
    );

    // 先卸载 NavHeader（去掉动画监听）再由 teardown 销毁路由动画
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 回归（2026-10）：聚焦搜索框后立刻展开全屏播放页 —— 壳内容（含 NavHeader）
/// 随 [ShellExpandTransition] 卸载，下拉面板必须同步摘除。
///
/// 旧实现把「移除 OverlayEntry」挂在 `_panelCtrl.reverse().whenComplete(...)` 上，
/// 而 dispose 紧接着就销毁了 controller：ticker 被取消，`TickerFuture` **永不
/// 完成** → 入口永久留在根 Overlay。锚点（LayerLink target）随壳内容一起消失后
/// `CompositedTransformFollower` 退化为左上角，且旧 State 的 TapRegion 组已不存在
/// → 表现为「搜索下拉卡死左上角且无法解除」。
void _shellUnmountRegression() {
  /// [openAnimation]：聚焦后到壳内容卸载之间推进的时长——1s = 下拉已完全展开；
  /// 120ms = 下拉展开动画途中（对应「点搜索框后**立刻**点开播放页」）。
  Future<void> unmountWhileOpen(
    WidgetTester tester, {
    required Duration openAnimation,
  }) async {
    final expandCtrl = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 500),
    );
    addTearDown(expandCtrl.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ShellExpandTransition(
              animation: expandCtrl,
              placeholder: const SizedBox.shrink(),
              child: const NavHeader(),
            ),
          ),
        ),
      ),
    );

    // 聚焦展开下拉（推进到指定时刻）
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump(openAnimation);
    expect(
      find.byType(SingleChildScrollView),
      findsOneWidget,
      reason: '聚焦后应展开下拉',
    );

    // 播放页展开：壳内容随动画结束被卸载（NavHeader dispose）
    expandCtrl.forward();
    await tester.pumpAndSettle();
    expect(find.byType(NavHeader), findsNothing, reason: '壳内容应已卸载');

    // 浮层必须随之摘除：否则会永久卡在根 Overlay 左上角
    expect(
      find.byType(SingleChildScrollView),
      findsNothing,
      reason: '壳内容卸载后下拉浮层必须移除（旧实现 whenComplete 永不触发 → 卡死）',
    );
  }

  testWidgets('搜索下拉展开后壳内容卸载（播放页完全展开）→ 浮层不残留', (tester) async {
    await unmountWhileOpen(tester, openAnimation: const Duration(seconds: 1));
  });

  testWidgets('聚焦后立刻展开播放页（下拉动画途中壳内容卸载）→ 浮层不残留', (
    tester,
  ) async {
    await unmountWhileOpen(
      tester,
      openAnimation: const Duration(milliseconds: 120),
    );
  });
}

/// 回归：展开后单击输入框 / 清除按钮**不收起**；点外部才收起且外部能收到点击。
void _searchBarKeepsOpenRegression() {
  testWidgets('展开后再次点击搜索框保持展开；点外部才收起（且外部收到点击）', (tester) async {
    var outsideTaps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => Scaffold(
                  body: Column(
                    children: [
                      const NavHeader(),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => outsideTaps++,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final textField = find.byType(TextField);

    // 展开
    await tester.tap(textField);
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsOneWidget, reason: '聚焦后应展开下拉');
    expect(tester.getSize(textField).width, closeTo(420, 0.5));

    // ① 再次点击搜索框本身：必须**保持展开**（修复前被拦截层判为「点外部」→ 收起）
    await tester.tap(textField);
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsOneWidget,
        reason: '点击输入框不应收起搜索栏');
    expect(tester.getSize(textField).width, closeTo(420, 0.5), reason: '保持展开宽度');

    // ② 输入文字后点「清除」按钮：同属内部操作，仍保持展开
    await tester.enterText(textField, '周杰伦');
    await tester.pumpAndSettle();
    final clearBtn = find.descendant(of: textField, matching: find.byType(IconButton));
    expect(clearBtn, findsOneWidget, reason: '有内容时应出现清除按钮');
    await tester.tap(clearBtn);
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsOneWidget,
        reason: '点清除按钮不应收起搜索栏（修复前被拦截层挡住）');

    // ③ 点组外：收起，且**外部收到这次点击**（旧拦截层会吞掉首次外部点击）
    await tester.tapAt(const Offset(200, 500));
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsNothing, reason: '点外部应收起');
    expect(tester.getSize(textField).width, closeTo(280, 0.5));
    expect(outsideTaps, 1, reason: '外部点击不应被搜索栏吞掉');
  });
}

/// 断言面板顶边贴搜索框底边、左对齐、宽度一致且位于搜索框下方。
void _expectAligned(
  WidgetTester tester,
  Finder textField,
  Finder panel,
) {
  final searchBox = tester.getBottomLeft(textField);
  final panelTopLeft = tester.getTopLeft(panel);
  final panelSize = tester.getSize(panel);
  final searchSize = tester.getSize(textField);

  // 1) 垂直：面板顶边 = 搜索框底边（贴紧，无间隙）
  expect(panelTopLeft.dy, closeTo(searchBox.dy, 0.5));
  // 2) 水平：面板左边缘 = 搜索框左边缘
  expect(panelTopLeft.dx, closeTo(searchBox.dx, 0.5));
  // 3) 宽度：面板宽度与搜索框宽度一致（跟随宽度动画）
  expect(panelSize.width, closeTo(searchSize.width, 0.5));
  // 4) 面板在搜索框下方（不覆盖输入框）
  expect(panelTopLeft.dy, greaterThan(searchBox.dy - 0.5));
}

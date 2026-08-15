// 搜索下拉定位验证：聚焦搜索框后，下拉面板（_SearchDropdown 内的
// SingleChildScrollView）应紧贴搜索框底边且左对齐、宽度与搜索框一致。
//
// 说明：override appPrefsProvider 避免读取真实用户偏好文件（无副作用）；
// 其余 provider（theme/netease）无文件副作用，保持真实实现（聚焦触发的
// 热搜请求在 flutter_test 中被 HttpOverrides 拦截返回 400 → 静默失败）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/layout/nav_header.dart';

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

// 回归测试：扫码登录页为全屏毛玻璃形态，不使用 AlertDialog，且长错误
// 消息不引起布局溢出。
//
// 历史：早期是紧凑 AlertDialog 弹窗，曾出现两个回归——
//  1. 新版 Flutter DialogRoute 不再包 Dialog，弹窗根收到 tight 全屏约束，
//     M3 AlertDialog 用 IntrinsicWidth 定宽，长文本（错误消息等）固有宽度
//     极大会把弹窗撑到全屏宽；
//  2. 高度上限取视口 85% 时，长错误文本会把弹窗顶满屏。
//  现改为全屏毛玻璃登录页（QR 居中放大，中央 Expanded + 滚动兜底），
//  不存在弹窗撑爆/截断问题。
//
// 本测试以「超长错误消息」驱动网易/酷狗两条登录路径（initState 拉取
// 二维码立即失败 → 错误分支渲染长文本），断言：无 AlertDialog、全屏层
// 填满视口（800×600）、错误提示可见、无布局溢出。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/kugou/kugou_api.dart';
import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/widgets/dialogs/kugou_login_button.dart';
import 'package:archoera_music/widgets/dialogs/netease_login_dialog.dart';

/// 立即抛超长错误文本的网易 API（触发错误分支渲染长文本）。
class _FailingNeteaseApi extends NeteaseApi {
  _FailingNeteaseApi() : super(ApisNeteaseCaller());

  @override
  Future<String> loginQrKey() async {
    throw Exception('模拟网络错误（超长错误消息用于复现登录页溢出回归）：${'x' * 200}');
  }
}

/// 立即抛超长错误文本的酷狗 API。
class _FailingKugouApi extends KugouApi {
  @override
  Future<String> qrKey() async {
    throw Exception('模拟网络错误（超长错误消息用于复现登录页溢出回归）：${'x' * 200}');
  }
}

void main() {
  /// 打开登录页（error 路径），断言为全屏毛玻璃形态且无布局溢出。
  Future<void> expectFullscreenLogin(
    WidgetTester tester,
    void Function(BuildContext) open,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          neteaseApiProvider.overrideWithValue(_FailingNeteaseApi()),
          kugouApiProvider.overrideWith((_) => _FailingKugouApi()),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
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
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: '扫码登录页为全屏毛玻璃形态，不应再使用 AlertDialog',
    );
    // 全屏毛玻璃层（BackdropFilter）填满视口（默认 800×600 测试视口）
    final size = tester.getSize(find.byType(BackdropFilter));
    expect(size.width, 800, reason: '登录页应铺满视口宽（实际 ${size.width}）');
    expect(size.height, 600, reason: '登录页应铺满视口高（实际 ${size.height}）');
    // 长错误消息可见（限 4 行截断，但不缺渲染）
    expect(find.textContaining('模拟网络错误'), findsOneWidget);
    // 无布局溢出（RenderFlex overflow 等）
    expect(tester.takeException(), isNull, reason: '登录页不应有布局溢出');
  }

  testWidgets('网易扫码登录页：全屏毛玻璃形态，长错误消息无溢出', (tester) async {
    await expectFullscreenLogin(tester, showNeteaseLoginDialog);
  });

  testWidgets('酷狗扫码登录页：全屏毛玻璃形态，长错误消息无溢出', (tester) async {
    await expectFullscreenLogin(
      tester,
      (context) => showDialog<void>(
        context: context,
        builder: (_) => const KgQrLoginDialog(),
      ),
    );
  });
}

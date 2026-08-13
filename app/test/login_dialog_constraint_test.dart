// 回归测试：扫码登录弹窗不得被撑到全屏。
//
// 根因：新版 Flutter DialogRoute 不再包 Dialog（pageBuilder 直接
// Builder+SafeArea+Semantics），弹窗根收到 tight 全屏约束；M3
// AlertDialog 用 IntrinsicWidth 定宽，长文本（错误消息等）固有宽度
// 极大会把弹窗撑到全屏。修复：先 Align 转 loose 再套
// ConstrainedBox(maxWidth: 460)（ConstrainedBox 在 tight 父约束下
// enforce 会把 maxWidth clamp 回父值，单独加会失效）。
//
// 本测试以「超长错误消息」驱动网易/酷狗两条弹窗路径（initState 拉取
// 二维码立即失败 → 错误分支渲染长文本），断言 AlertDialog 渲染宽度
// 远小于视口宽（默认 800×600 测试视口；修复前为 800 全屏）。

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

/// 立即抛超长错误文本的网易 API（触发错误分支 + IntrinsicWidth 撑大路径）。
class _FailingNeteaseApi extends NeteaseApi {
  _FailingNeteaseApi() : super(ApisNeteaseCaller());

  @override
  Future<String> loginQrKey() async {
    throw Exception('模拟网络错误（超长错误消息用于复现弹窗被撑到全屏的回归）：${'x' * 200}');
  }
}

/// 立即抛超长错误文本的酷狗 API。
class _FailingKugouApi extends KugouApi {
  @override
  Future<String> qrKey() async {
    throw Exception('模拟网络错误（超长错误消息用于复现弹窗被撑到全屏的回归）：${'x' * 200}');
  }
}

void main() {
  /// 弹出一个登录对话框（error 路径），断言 AlertDialog 宽度被约束在
  /// 视口宽度以下（修复后为 460；修复前 = 全屏 800）。
  Future<void> expectDialogBounded(
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

    expect(find.byType(AlertDialog), findsOneWidget);
    final size = tester.getSize(find.byType(AlertDialog));
    expect(
      size.width,
      lessThan(600),
      reason: 'AlertDialog 不得被长文本撑到全屏（实际宽 ${size.width}）',
    );
  }

  testWidgets('网易扫码登录弹窗：长错误消息不撑爆宽度', (tester) async {
    await expectDialogBounded(tester, showNeteaseLoginDialog);
  });

  testWidgets('酷狗扫码登录弹窗：长错误消息不撑爆宽度', (tester) async {
    await expectDialogBounded(
      tester,
      (context) => showDialog<void>(
        context: context,
        builder: (_) => const KgQrLoginDialog(),
      ),
    );
  });
}

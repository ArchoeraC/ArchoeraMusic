// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Neko 登录框交互测试：
// - 默认进入「账号密码」页，**不**请求二维码（切到扫码页才请求）；
// - 账号为空时本地提示，不发登录请求；
// - 登录失败展示服务端文案并停留在登录框。
//
// 账号密码的网络链路（SSO 兑换）见 `neko_password_login_test.dart`。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/neko/neko_client.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/services/neko/neko_api.dart';
import 'package:archoera_music/services/neko/neko_types.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/widgets/dialogs/neko_login_dialog.dart';

class _FakeNekoApi extends NekoApi {
  int qrCreateCalls = 0;
  int loginCalls = 0;
  String? lastIdentifier;
  String? lastPassword;
  Object? loginError;

  @override
  Future<NekoQrSession> qrCreate() async {
    qrCreateCalls++;
    return NekoQrSession(sessionId: 'sid', deliveryKey: 'dk');
  }

  @override
  Stream<NekoQrStatus> qrWatch(NekoQrSession session) async* {
    // 测试里不推送状态：保持在等待扫码态即可。
  }

  @override
  Future<void> loginWithPassword({
    required String identifier,
    required String password,
  }) async {
    loginCalls++;
    lastIdentifier = identifier;
    lastPassword = password;
    final error = loginError;
    if (error != null) throw error;
  }
}

/// 内存偏好桩：不读写真实 prefs.json。
class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this._initial);

  final AppPrefs _initial;

  @override
  AppPrefs build() => _initial;
}

void main() {
  late _FakeNekoApi api;

  setUp(() => api = _FakeNekoApi());

  Widget host({bool passwordLogin = true}) => ProviderScope(
    overrides: [
      nekoApiProvider.overrideWith((_) => api),
      appPrefsProvider.overrideWith(
        () => _StubPrefs(
          AppPrefs(
            initialData: {
              if (passwordLogin) nekoPasswordLoginKey: true,
            },
          ),
        ),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showNekoLoginDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  /// 打开登录框（跳过登录风险提示）。
  Future<void> openDialog(
    WidgetTester tester, {
    bool passwordLogin = true,
  }) async {
    await tester.pumpWidget(host(passwordLogin: passwordLogin));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已知晓，继续登录'));
    await tester.pumpAndSettle();
  }

  testWidgets('未开启账号密码：只提供扫码，且打开即申请二维码', (tester) async {
    await openDialog(tester, passwordLogin: false);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('账号密码'), findsNothing);
    expect(find.text('扫码登录'), findsNothing, reason: '单一路径不需要 tab');
    expect(find.text('请使用 NekoMusic 手机 App 扫码登录'), findsOneWidget);
    expect(api.qrCreateCalls, 1);
  });

  testWidgets('默认密码页不发二维码请求，切到扫码才请求', (tester) async {
    await openDialog(tester);

    expect(find.text('账号密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(api.qrCreateCalls, 0, reason: '打开登录框不应立刻申请二维码');

    await tester.tap(find.text('扫码登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.qrCreateCalls, 1);
  });

  testWidgets('账号为空：本地提示，不发登录请求', (tester) async {
    await openDialog(tester);

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('请输入账号'), findsOneWidget);
    expect(api.loginCalls, 0);
  });

  testWidgets('密码为空：本地提示，不发登录请求', (tester) async {
    await openDialog(tester);

    await tester.enterText(find.byType(TextField).first, 'tester');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('请输入密码'), findsOneWidget);
    expect(api.loginCalls, 0);
  });

  testWidgets('登录失败：展示服务端文案并停留在登录框', (tester) async {
    api.loginError = NekoApiException('账号或密码错误');
    await openDialog(tester);

    await tester.enterText(find.byType(TextField).first, ' tester@example.com ');
    await tester.enterText(find.byType(TextField).last, 'wrong');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(api.loginCalls, 1);
    expect(api.lastIdentifier, 'tester@example.com', reason: '账号需要去首尾空白');
    expect(api.lastPassword, 'wrong');
    expect(find.text('账号或密码错误'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget, reason: '失败后仍停留在登录框');
  });
}

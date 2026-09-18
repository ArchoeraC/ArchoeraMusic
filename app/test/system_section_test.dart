// ArchoeraMusic UI
// SPDX-License-Identifier: AGPL-3.0-or-later

// 设置 → 系统（ArchoeraOS 会话）布局/交互回归：
//  - 可用时渲染电池/亮度/屏幕/电源；确认框后才触发系统请求；
//  - 不可用时渲染「未运行于 ArchoeraOS」说明，不出现电源按钮。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/platform/os_session.dart';
import 'package:archoera_music/services/platform/system_os.dart';
import 'package:archoera_music/settings/settings_sections.dart';

/// 记录请求的假会话控制面。
class _FakeOs implements SystemOsSession {
  int powerOffCalls = 0;
  int rebootCalls = 0;
  int suspendCalls = 0;
  int hibernateCalls = 0;
  int? lastBrightness;
  bool? lastScreen;

  @override
  bool get available => true;

  @override
  int setEvents(bool on) => 0;

  @override
  int setBrightness(int percent) {
    lastBrightness = percent;
    return 0;
  }

  @override
  int setVolume(int percent) => 0;

  @override
  int setScreenEnabled(bool on) {
    lastScreen = on;
    return 0;
  }

  @override
  int powerOff() {
    powerOffCalls++;
    return 0;
  }

  @override
  int reboot() {
    rebootCalls++;
    return 0;
  }

  @override
  int suspend() {
    suspendCalls++;
    return 0;
  }

  @override
  int hibernate() {
    hibernateCalls++;
    return 0;
  }

  @override
  int setOutputScale(int scaleMilli) => 0;

  @override
  int setOutputMode(int width, int height) => 0;

  @override
  int setOutputTransform(int transform) => 0;

  @override
  int key(int keycode, int state) => 0;

  @override
  List<OsDisplayOutput> displayOutputs() => const <OsDisplayOutput>[];

  @override
  int setDisplayOutputMode(int outputId, int index) => 0;

  @override
  int setDisplayOutputScale(int outputId, int scaleMilli) => 0;

  @override
  int setDisplayOutputTransform(int outputId, int transform) => 0;

  @override
  Stream<int> get capabilities => const Stream.empty();
  @override
  Stream<int> get brightness => const Stream.empty();
  @override
  Stream<int> get volume => const Stream.empty();
  @override
  Stream<OsBatteryState> get battery => const Stream.empty();
  @override
  Stream<OsSessionState> get session => const Stream.empty();
  @override
  Stream<bool> get screenEnabled => const Stream.empty();
  @override
  Stream<OsPowerKey> get powerKey => const Stream.empty();
  @override
  Stream<OsOutputState> get output => const Stream.empty();
}

Widget _section(Widget child) =>
    Scaffold(body: SingleChildScrollView(child: child));

void main() {
  testWidgets('系统分区（可用）：电池/亮度/电源渲染，确认后关机', (tester) async {
    final os = _FakeOs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          osSessionAvailableProvider.overrideWithValue(true),
          osSessionControllerProvider.overrideWithValue(os),
          osCapabilitiesProvider.overrideWithValue(
            OsCapability.power |
                OsCapability.suspend |
                OsCapability.brightness |
                OsCapability.battery |
                OsCapability.screen,
          ),
          osBrightnessProvider.overrideWithValue(42),
          osBatteryProvider.overrideWithValue(
            const OsBatteryState(present: true, percent: 81, charging: true),
          ),
          osScreenEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: _section(const SystemSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('81%'), findsOneWidget);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.text('关机'), findsOneWidget);
    expect(find.text('重启'), findsOneWidget);
    expect(find.text('挂起'), findsOneWidget);

    // 关机需确认：未确认不触发。
    await tester.tap(find.text('关机'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定要'), findsOneWidget);
    expect(os.powerOffCalls, 0);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(os.powerOffCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统分区（不可用）：显示未运行说明，无电源按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [osSessionAvailableProvider.overrideWithValue(false)],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: _section(const SystemSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未运行于 ArchoeraOS'), findsOneWidget);
    expect(find.text('关机'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ArchoeraOS 显示设置（per-output）回归：
//  - 每个输出一张卡片（连接器名 + 主输出标记）；
//  - 模式下拉栏列出**完整**模式表（同分辨率不同刷新率可区分）；
//  - 缩放/旋转下拉栏；设置精确作用于该输出 id（不是主输出）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/platform/os_session.dart';
import 'package:archoera_music/services/platform/system_os.dart';
import 'package:archoera_music/settings/settings_sections.dart';

/// 假会话控制面：记录 per-output 设置调用。
class _FakeOs implements SystemOsSession {
  final List<(int, int)> modeCalls = [];
  final List<(int, int)> scaleCalls = [];
  final List<(int, int)> transformCalls = [];

  final List<OsDisplayOutput> outputs;

  _FakeOs(this.outputs);

  @override
  bool get available => true;

  @override
  int setEvents(bool on) => 0;
  @override
  int setBrightness(int percent) => 0;
  @override
  int setVolume(int percent) => 0;
  @override
  int setScreenEnabled(bool on) => 0;
  @override
  int powerOff() => 0;
  @override
  int reboot() => 0;
  @override
  int suspend() => 0;
  @override
  int hibernate() => 0;
  @override
  int setOutputScale(int scaleMilli) => 0;
  @override
  int setOutputMode(int width, int height) => 0;
  @override
  int setOutputTransform(int transform) => 0;
  @override
  int key(int keycode, int state) => 0;

  @override
  List<OsDisplayOutput> displayOutputs() => outputs;

  @override
  int setDisplayOutputMode(int outputId, int index) {
    modeCalls.add((outputId, index));
    return 0;
  }

  @override
  int setDisplayOutputScale(int outputId, int scaleMilli) {
    scaleCalls.add((outputId, scaleMilli));
    return 0;
  }

  @override
  int setDisplayOutputTransform(int outputId, int transform) {
    transformCalls.add((outputId, transform));
    return 0;
  }

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

OsDisplayOutput _panel({
  required int id,
  required String name,
  required bool primary,
}) {
  return OsDisplayOutput(
    id: id,
    name: name,
    enabled: true,
    primary: primary,
    width: 2560,
    height: 1600,
    scaleMilli: 1000,
    transform: 0,
    refreshMillihz: 165000,
    modes: const [
      OsDisplayMode(
        index: 0,
        width: 2560,
        height: 1600,
        refreshMillihz: 165000,
        isCurrent: true,
        isPreferred: true,
      ),
      OsDisplayMode(
        index: 1,
        width: 2560,
        height: 1600,
        refreshMillihz: 60000,
        isCurrent: false,
        isPreferred: false,
      ),
      OsDisplayMode(
        index: 2,
        width: 1920,
        height: 1080,
        refreshMillihz: 60000,
        isCurrent: false,
        isPreferred: false,
      ),
    ],
  );
}

Widget _host(_FakeOs os) => ProviderScope(
  overrides: [
    osSessionAvailableProvider.overrideWithValue(true),
    osSessionControllerProvider.overrideWithValue(os),
    osCapabilitiesProvider.overrideWithValue(OsCapability.output),
  ],
  child: MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: const Scaffold(body: SingleChildScrollView(child: SystemSection())),
  ),
);

void main() {
  testWidgets('per-output 卡片：完整模式表 + 设置精确落到该输出', (tester) async {
    final os = _FakeOs([
      _panel(id: 3, name: 'eDP-1', primary: true),
      _panel(id: 7, name: 'HDMI-A-1', primary: false),
    ]);
    await tester.pumpWidget(_host(os));
    await tester.pumpAndSettle();

    // 两个输出各一张卡片，主输出带标记（大标题即连接器名）。
    expect(find.text('eDP-1 · 主输出'), findsOneWidget);
    expect(find.text('HDMI-A-1'), findsOneWidget);
    expect(find.textContaining('主输出'), findsOneWidget);

    // 模式下拉栏：完整模式表（含同分辨率不同刷新率）。
    expect(find.text('2560×1600 @165 Hz'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换模式：按输出 id + 模式索引下发（165Hz → 60Hz）', (tester) async {
    final os = _FakeOs([_panel(id: 3, name: 'eDP-1', primary: true)]);
    await tester.pumpWidget(_host(os));
    await tester.pumpAndSettle();

    // 打开第一个下拉栏（分辨率/刷新率）。
    await tester.tap(find.byType(DropdownButton<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('1920×1080 @60 Hz').last);
    await tester.pumpAndSettle();

    expect(os.modeCalls, [(3, 2)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旋转下拉：90° → transform 码 1（作用于该输出）', (tester) async {
    final os = _FakeOs([_panel(id: 7, name: 'HDMI-A-1', primary: true)]);
    await tester.pumpWidget(_host(os));
    await tester.pumpAndSettle();

    // 第三个下拉栏是旋转（分辨率 / 缩放 / 旋转）。
    await tester.tap(find.byType(DropdownButton<int>).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90°').last);
    await tester.pumpAndSettle();

    expect(os.transformCalls, [(7, 1)]);
    expect(tester.takeException(), isNull);
  });
}

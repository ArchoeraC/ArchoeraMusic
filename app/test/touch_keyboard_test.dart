// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ArchoeraOS 屏幕键盘（OSK）回归：
//  - 布局键码与 Shift / Ctrl+Space（切输入法）注入序列正确；
//  - 触摸聚焦文本输入框时自动弹出，失焦/收起后隐藏；
//  - 非 ArchoeraOS（无 keyboard 能力位）时不显示。

import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/platform/os_session.dart';
import 'package:archoera_music/services/platform/system_os.dart';
import 'package:archoera_music/widgets/common/touch_keyboard/touch_keyboard.dart';
import 'package:archoera_music/widgets/common/touch_keyboard/touch_keyboard_layout.dart';

/// 记录注入按键的假会话控制面。
class _RecordingOs implements SystemOsSession {
  final List<List<int>> keys = [];

  void reset() => keys.clear();

  @override
  bool get available => true;

  @override
  int key(int keycode, int state) {
    keys.add([keycode, state]);
    return 0;
  }

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

Widget _keyboard(_RecordingOs os, {int caps = OsCapability.keyboard}) {
  return ProviderScope(
    overrides: [
      osCapabilitiesProvider.overrideWithValue(caps),
      osSessionControllerProvider.overrideWithValue(os),
    ],
    child: const MaterialApp(
      home: Scaffold(body: Center(child: TouchKeyboard(height: 260))),
    ),
  );
}

void main() {
  test('字母/符号层键码使用 evdev KEY_*', () {
    expect(oskLetterRows[0].first.evdev, OskEvdev.q);
    expect(oskLetterRows[0].first.shifted, 'Q');
    expect(oskSymbolRows[0].first.evdev, OskEvdev.digit1);
    // @ 为 Shift+2 的符号档。
    final at = oskSymbolRows[1].firstWhere((k) => k.label == '@');
    expect(at.evdev, OskEvdev.digit2);
    expect(at.withShift, isTrue);
  });

  testWidgets('点按字符键注入按下/释放', (tester) async {
    final os = _RecordingOs();
    await tester.pumpWidget(_keyboard(os));
    await tester.tap(find.text('q'));
    await tester.pump();

    expect(os.keys, [
      [OskEvdev.q, 1],
      [OskEvdev.q, 0],
    ]);
  });

  testWidgets('Shift + 字母注入 Shift 包裹序列', (tester) async {
    final os = _RecordingOs();
    await tester.pumpWidget(_keyboard(os));
    await tester.tap(find.text('Shift'));
    await tester.pump();
    // Shift 生效后字母键显示大写。
    await tester.tap(find.text('A'));
    await tester.pump();

    expect(os.keys, [
      [OskEvdev.leftShift, 1],
      [OskEvdev.a, 1],
      [OskEvdev.a, 0],
      [OskEvdev.leftShift, 0],
    ]);
  });

  testWidgets('中/EN 键注入 Ctrl+Space（fcitx5 切换输入法）', (tester) async {
    final os = _RecordingOs();
    await tester.pumpWidget(_keyboard(os));
    await tester.tap(find.text('中/EN'));
    await tester.pump();

    expect(os.keys, [
      [OskEvdev.leftCtrl, 1],
      [OskEvdev.space, 1],
      [OskEvdev.space, 0],
      [OskEvdev.leftCtrl, 0],
    ]);
  });

  testWidgets('触摸聚焦输入框自动弹出，⌄ 收起', (tester) async {
    final os = _RecordingOs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          osCapabilitiesProvider.overrideWithValue(OsCapability.keyboard),
          osSessionControllerProvider.overrideWithValue(os),
        ],
        child: MaterialApp(
          home: TouchKeyboardHost(
            child: Scaffold(
              body: Center(
                child: TextField(controller: TextEditingController()),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(TouchKeyboard), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextField)),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(TouchKeyboard), findsOneWidget);

    await tester.tap(find.text('⌄'));
    await tester.pumpAndSettle();
    expect(find.byType(TouchKeyboard), findsNothing);
  });

  testWidgets('无 keyboard 能力位时不弹出', (tester) async {
    final os = _RecordingOs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          osCapabilitiesProvider.overrideWithValue(OsCapability.output),
          osSessionControllerProvider.overrideWithValue(os),
        ],
        child: MaterialApp(
          home: TouchKeyboardHost(
            child: Scaffold(
              body: Center(
                child: TextField(controller: TextEditingController()),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextField)),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(TouchKeyboard), findsNothing);
  });
}

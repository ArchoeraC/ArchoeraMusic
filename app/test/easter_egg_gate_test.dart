// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 彩蛋框架：「千万别点」警告门。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/easter_egg/easter_egg.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 最小偏好桩（避免测试触达 SharedPreferences）。
class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this._value);
  final AppPrefs _value;
  @override
  AppPrefs build() => _value;
}

/// 挂载一个可拿到 BuildContext 的最小宿主，返回该 context。
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _StubPrefs(AppPrefs(initialData: const <String, dynamic>{})),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (BuildContext c) {
            ctx = c;
            return const Scaffold();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ctx;
}

/// 可控随机源（确定性验证加权抽取的落点）。
class _FakeRandom implements math.Random {
  _FakeRandom({required this.doubles, required this.ints});
  final List<double> doubles;
  final List<int> ints;
  int _d = 0;
  int _i = 0;

  @override
  double nextDouble() => doubles[_d++ % doubles.length];

  @override
  int nextInt(int max) => ints[_i++ % ints.length];

  @override
  bool nextBool() => false;
}

void main() {
  test('pickEasterEgg：概率命中 + 按权重加权抽取', () {
    expect(kEasterEggEffects, hasLength(10));
    // 权重：致命 #1/#5=1、烦人 #2/#9=2、其余=3 → 合计 24。
    expect(kEasterEggEffects.fold<int>(0, (s, e) => s + e.weight), 24);

    // 未命中：chance=0 直接 null；chance=0.5 时 nextDouble=0.9 也 null。
    expect(pickEasterEgg(chance: 0, random: math.Random(1)), isNull);
    expect(
      pickEasterEgg(chance: 0.5, random: _FakeRandom(doubles: [0.9], ints: [0])),
      isNull,
    );

    // 命中后按权重落点（chance=1，nextDouble=0.1）：
    // roll 0→#1(权1)、1→#2(权2)、3→#3(权3)、20→#9(权2)、23→#10(权3，末尾)。
    EasterEggEffect? at(int roll) => pickEasterEgg(
      chance: 1,
      random: _FakeRandom(doubles: [0.1], ints: [roll]),
    );
    expect(at(0)!.id, 'not_responding');
    expect(at(1)!.id, 'minimize_trap');
    expect(at(3)!.id, 'zoom_800');
    expect(at(20)!.id, 'pause_lock');
    expect(at(23)!.id, 'invert_colors');

    // 覆盖性（固定种子；权重均 ≥1，500 次足以覆盖全部）。
    final rng = math.Random(42);
    final seen = <String>{};
    for (var i = 0; i < 500; i++) {
      seen.add(pickEasterEgg(chance: 1, random: rng)!.id);
    }
    expect(seen.length, kEasterEggEffects.length, reason: '应能覆盖全部彩蛋');
  });

  testWidgets('警告门：三个「确定」按钮，点击任一都执行同一彩蛋', (tester) async {
    var runs = 0;
    final effect = EasterEggEffect(
      id: 'test',
      run: (EasterEggContext _) async {
        runs++;
      },
    );

    // 第一次：点第 1 个「确定」。
    final ctx1 = await _pumpHost(tester);
    unawaited(showEasterEggGate(ctx1, effect: effect));
    await tester.pumpAndSettle();

    // 警告文案 + 三个「确定」。
    expect(find.textContaining('不可逆后果'), findsOneWidget);
    expect(find.text('确定'), findsNWidgets(3));

    await tester.tap(find.text('确定').first);
    await tester.pumpAndSettle();
    expect(runs, 1);
    expect(find.text('确定'), findsNothing);

    // 第二次：点最后一个「确定」——仍是同一个彩蛋。
    final ctx2 = await _pumpHost(tester);
    unawaited(showEasterEggGate(ctx2, effect: effect));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    expect(runs, 2);
  });
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 发布通道（0–3 → Release/Beta/Dev/Nightly）回归：
/// - 未传 `--dart-define=ARCHOERA_CHANNEL` 时默认 Dev；
/// - 数值映射与越界回退；
/// - 徽标只显示通道名、颜色互不相同（图片外观下保持固定深色实心）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/utils/app_version.dart';
import 'package:archoera_music/widgets/common/release_channel_badge.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('通道映射：0/1/2/3 与越界回退', () {
    expect(ReleaseChannel.fromValue(0), ReleaseChannel.release);
    expect(ReleaseChannel.fromValue(1), ReleaseChannel.beta);
    expect(ReleaseChannel.fromValue(2), ReleaseChannel.dev);
    expect(ReleaseChannel.fromValue(3), ReleaseChannel.nightly);
    expect(ReleaseChannel.fromValue(null), ReleaseChannel.dev);
    expect(ReleaseChannel.fromValue(99), ReleaseChannel.dev);
  });

  test('未传 define 时默认 Dev', () {
    expect(ReleaseChannel.current, ReleaseChannel.dev);
  });

  testWidgets('徽标显示通道名而非数字，且颜色互不相同', (tester) async {
    final colors = <ReleaseChannel, Color>{};
    for (final channel in ReleaseChannel.values) {
      await tester.pumpWidget(_wrap(ReleaseChannelBadge(channel: channel)));
      expect(find.text(channel.label), findsOneWidget);
      expect(find.text('${channel.value}'), findsNothing);
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byType(ReleaseChannelBadge),
          matching: find.byType(Container),
        ),
      );
      colors[channel] = (box.decoration! as BoxDecoration).color!;
    }
    expect(colors.values.toSet().length, ReleaseChannel.values.length);
  });
}

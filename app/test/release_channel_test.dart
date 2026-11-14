// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 发布通道（0–3 → Release/Beta/Dev/Nightly）回归：
/// - 未传 `--dart-define=ARCHOERA_CHANNEL` 时默认 Dev；
/// - 数值映射与越界回退；
/// - 徽标只显示通道名、通道间颜色可区分；配色随明暗主题派生（底色为
///   低透明度叠层，不再是高饱和实心块）。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/utils/app_version.dart';
import 'package:archoera_music/widgets/common/release_channel_badge.dart';

Widget _wrap(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      // 关掉主题切换动画：测试要立刻拿到新主题下的徽标配色。
      themeAnimationDuration: Duration.zero,
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F51B5),
          brightness: brightness,
        ),
      ),
      home: Scaffold(body: child),
    );

/// 取徽标底色 / 文字色（徽标内部只有一个 Container + 一个 Text）。
({Color? bg, Color? fg}) _badgeColors(WidgetTester tester) {
  final box = tester.widget<Container>(
    find.descendant(
      of: find.byType(ReleaseChannelBadge),
      matching: find.byType(Container),
    ),
  );
  final text = tester.widget<Text>(
    find.descendant(
      of: find.byType(ReleaseChannelBadge),
      matching: find.byType(Text),
    ),
  );
  return (bg: (box.decoration! as BoxDecoration).color, fg: text.style?.color);
}

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

  testWidgets('徽标显示通道名而非数字，且通道间颜色可区分', (tester) async {
    final colors = <ReleaseChannel, Color?>{};
    for (final channel in ReleaseChannel.values) {
      await tester.pumpWidget(_wrap(ReleaseChannelBadge(channel: channel)));
      expect(find.text(channel.label), findsOneWidget);
      expect(find.text('${channel.value}'), findsNothing);
      colors[channel] = _badgeColors(tester).bg;
    }
    expect(colors.values.toSet().length, ReleaseChannel.values.length);
  });

  testWidgets('配色随明暗主题派生：底色是低透明度叠层，文字明暗取不同色阶', (tester) async {
    for (final channel in ReleaseChannel.values) {
      await tester.pumpWidget(
        _wrap(
          ReleaseChannelBadge(channel: channel),
          brightness: Brightness.dark,
        ),
      );
      final dark = _badgeColors(tester);
      expect(dark.bg!.a, lessThan(1.0), reason: '底色应是叠在卡片表面的半透明层，而非高饱和实心块');

      await tester.pumpWidget(
        _wrap(
          ReleaseChannelBadge(channel: channel),
          brightness: Brightness.light,
        ),
      );
      final light = _badgeColors(tester);
      expect(light.fg, isNot(dark.fg), reason: '深浅主题应取不同文字色阶（深色提亮 / 浅色压暗）');
    }
  });

  testWidgets('徽标文字在设置卡片底色上保持可读（对比度 ≥ 4.5:1）', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        _wrap(const SizedBox.shrink(), brightness: brightness),
      );
      final scheme = Theme.of(tester.element(find.byType(SizedBox)))
          .colorScheme;
      // 设置卡片（SettingCard）：surfaceContainerHighest @ 35% 叠在页面上。
      final cardBg = Color.alphaBlend(
        scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        scheme.surface,
      );
      for (final channel in ReleaseChannel.values) {
        await tester.pumpWidget(
          _wrap(ReleaseChannelBadge(channel: channel), brightness: brightness),
        );
        final c = _badgeColors(tester);
        final chipBg = Color.alphaBlend(c.bg!, cardBg);
        expect(
          _contrast(c.fg!, chipBg),
          greaterThanOrEqualTo(4.5),
          reason: '${brightness.name} 主题下 $channel 徽标文字对比度不足',
        );
      }
    }
  });
}

/// WCAG 对比度（前景 / 背景）。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

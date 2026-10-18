// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `coverTone` 背景回归：
/// - 主色 → 渐变两端色的纯函数稳定、明暗关系正确（暗端更暗、亮端更亮）；
/// - 无封面 / 取色失败时回退默认渐变，组件不抛异常；
/// - 取色 provider 不受 `themeSource` / `followCoverColor` 门控影响。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/theme/cover_color.dart';
import 'package:archoera_music/widgets/player/background/cover_tone_background.dart';

/// 测试基色（中等明度蓝，接近取色器输出的典型基色）。
const Color _base = Color(0xFF3E6F9E);

/// 固定颜色 stub：绕开播放状态/封面解码，只验证渲染分支。
class _StubTone extends PlayerCoverToneNotifier {
  _StubTone(this.color);

  Color? color;

  @override
  Color? build() => color;

  /// 模拟取色完成/切歌换色。
  void setTone(Color? next) => state = next;
}

/// 最小播放态（不启引擎）。
class _StubPlayback extends PlaybackNotifier {
  _StubPlayback(this.track);

  final Track track;

  @override
  PlaybackState build() => PlaybackState(track: track);
}

/// 可改写的偏好 stub（验证背景样式切换时的清理）。
class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this.value);

  AppPrefs value;

  @override
  AppPrefs build() => value;

  void setPrefs(AppPrefs next) => state = next;
}

Widget _wrap(Widget child, {Color tone = _base}) => ProviderScope(
  overrides: [playerCoverToneProvider.overrideWith(() => _StubTone(tone))],
  child: MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF336699)),
    ),
    home: Scaffold(body: SizedBox(width: 320, height: 180, child: child)),
  ),
);

LinearGradient _gradientOf(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byType(CoverToneBackground),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return ((container.decoration! as BoxDecoration).gradient!) as LinearGradient;
}

/// 生成 64×64 封面 PNG（中央饱和蓝主体 + 近白底）。
Future<String> _writeCover() async {
  const n = 64;
  final bytes = Uint8List(n * n * 4);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final argb = (x > 16 && x < 48 && y > 16 && y < 48)
          ? 0xFF1E63FF
          : 0xFFF5F5F5;
      final i = (y * n + x) * 4;
      bytes[i] = (argb >> 16) & 0xFF;
      bytes[i + 1] = (argb >> 8) & 0xFF;
      bytes[i + 2] = argb & 0xFF;
      bytes[i + 3] = (argb >> 24) & 0xFF;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    n,
    n,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final img = await completer.future;
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File(
    '${Directory.systemTemp.path}/cover_tone_${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await f.writeAsBytes(png!.buffer.asUint8List());
  return f.path;
}

void main() {
  group('coverToneColors', () {
    test('同一基色推导稳定，暗端更暗、亮端更亮', () {
      final first = coverToneColors(_base);
      final second = coverToneColors(_base);
      expect(first.dark, second.dark);
      expect(first.light, second.light);

      final baseLum = _base.computeLuminance();
      expect(
        first.dark.computeLuminance(),
        lessThan(baseLum),
        reason: '暗端应比基色暗',
      );
      expect(
        first.light.computeLuminance(),
        greaterThan(baseLum),
        reason: '亮端应比基色亮',
      );
      expect(first.dark.a, 1.0);
      expect(first.light.a, 1.0);
    });

    test('亮端色相向负方向偏移约 30°（矩阵法近似）', () {
      final tone = coverToneColors(_base);
      final baseHue = HSVColor.fromColor(_base).hue;
      final lightHue = HSVColor.fromColor(tone.light).hue;
      // 归一化到 (-180, 180]，比较偏移方向与幅度。
      var delta = (lightHue - baseHue) % 360;
      if (delta > 180) delta -= 360;
      expect(delta, lessThan(0), reason: '应朝负方向旋转色相');
      expect(delta, closeTo(kCoverToneHueShift, 12));
    });

    test('灰色基色旋转色相后仍是灰', () {
      const gray = Color(0xFF808080);
      final tone = coverToneColors(gray);
      final hsv = HSVColor.fromColor(tone.light);
      expect(hsv.saturation, closeTo(0, 0.002));
      expect(
        tone.light.computeLuminance(),
        greaterThan(gray.computeLuminance()),
      );
    });

    test('渐变方向为右下 → 左上（对应 CSS to top left）', () {
      final gradient = coverToneGradient(_base);
      expect(gradient.begin, Alignment.bottomRight);
      expect(gradient.end, Alignment.topLeft);
      final tone = coverToneColors(_base);
      expect(gradient.colors, [tone.dark, tone.light]);
    });
  });

  group('CoverToneBackground', () {
    testWidgets('无封面时回退默认渐变且不抛异常', (tester) async {
      // stub 故意返回颜色：无封面时也必须忽略它、走兜底渐变。
      await tester.pumpWidget(_wrap(const CoverToneBackground(cover: null)));
      expect(tester.takeException(), isNull);

      final gradient = _gradientOf(tester);
      final expected = playerDefaultBackgroundGradient(
        tester.element(find.byType(CoverToneBackground)),
      );
      expect(gradient.colors, expected.colors);
      expect(gradient.begin, expected.begin);
      expect(gradient.end, expected.end);
    });

    testWidgets('有封面且取到主色时使用主色低对比渐变', (tester) async {
      await tester.pumpWidget(
        _wrap(const CoverToneBackground(cover: 'file:///tmp/cover.png')),
      );
      expect(tester.takeException(), isNull);
      expect(_gradientOf(tester).colors, coverToneGradient(_base).colors);
    });

    testWidgets('切歌换色过渡期间不抛异常', (tester) async {
      await tester.pumpWidget(
        _wrap(const CoverToneBackground(cover: 'file:///a.png')),
      );
      // 模拟新曲目取色完成：同一 ProviderScope 内更新颜色（不重建容器）。
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CoverToneBackground)),
      );
      (container.read(playerCoverToneProvider.notifier) as _StubTone).setTone(
        const Color(0xFF9E5E3E),
      );
      await tester.pump(); // 启动隐式过渡
      await tester.pump(const Duration(milliseconds: 180));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      // 过渡结束后落到新基色的渐变。
      expect(
        _gradientOf(tester).colors,
        coverToneGradient(const Color(0xFF9E5E3E)).colors,
      );
    });
  });

  testWidgets('取色不受 themeSource / followCoverColor 门控，切走样式后清空', (tester) async {
    late final String path;
    await tester.runAsync(() async => path = await _writeCover());

    final container = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _StubPrefs(
            AppPrefs(
              initialData: {
                // 默认主题来源 + 关闭跟随封面：旧 provider 会因此拒绝取色。
                themeSourceKey: 'default',
                followCoverColorKey: false,
                playerBgTypeKey: 'coverTone',
              },
            ),
          ),
        ),
        playbackProvider.overrideWith(
          () => _StubPlayback(Track(id: '1', title: 't', cover: path)),
        ),
      ],
    );
    addTearDown(container.dispose);

    final color = await tester.runAsync(() async {
      final done = Completer<Color?>();
      final sub = container.listen(playerCoverToneProvider, (_, next) {
        if (!done.isCompleted && next != null) done.complete(next);
      });
      addTearDown(sub.close);
      return done.future.timeout(const Duration(seconds: 10));
    });
    expect(color, isNotNull, reason: '默认主题下 coverTone 也必须取到封面色');

    // 切到其它背景样式 → 颜色清空（避免常驻旧色），但缓存保留。
    final prefs = container.read(appPrefsProvider.notifier) as _StubPrefs;
    prefs.setPrefs(AppPrefs(initialData: {playerBgTypeKey: 'gradient'}));
    expect(container.read(playerCoverToneProvider), isNull);
  });
}

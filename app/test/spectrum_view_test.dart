// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 频谱渲染冒烟测试：三种样式在有 FFT 数据下均无异常。
///
/// 覆盖 P3：条形改单 Path 批量提交、横向渐隐由画笔 shader 承担（去掉
/// widget 侧 ShaderMask 离屏层）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/player/spectrum_view.dart';

/// 不读/写磁盘的偏好（测试用）。
class _NoSideEffectsPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

/// 固定播放态（不启动引擎）。
class _FakePlayback extends PlaybackNotifier {
  _FakePlayback(this._s);
  final PlaybackState _s;
  @override
  PlaybackState build() => _s;
}

FftFrame _frame() {
  final l = List<double>.generate(128, (i) => (i % 16) / 16);
  return FftFrame(ldata: l, rdata: l);
}

Widget _wrap(SpectrumStyle style) => ProviderScope(
  overrides: [
    appPrefsProvider.overrideWith(_NoSideEffectsPrefsNotifier.new),
    playbackProvider.overrideWith(
      () => _FakePlayback(PlaybackState(playing: true, fft: _frame())),
    ),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          height: 90,
          child: SpectrumView(height: 80, style: style, enabled: true),
        ),
      ),
    ),
  ),
);

void main() {
  for (final style in SpectrumStyle.values) {
    testWidgets('频谱样式 $style 渲染无异常', (tester) async {
      await tester.pumpWidget(_wrap(style));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(SpectrumView), findsOneWidget);
      // P3：横向渐隐已并入画笔，不再有 ShaderMask 离屏层。
      expect(find.byType(ShaderMask), findsNothing);
    });
  }
}

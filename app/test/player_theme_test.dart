// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页主题隔离回归：全屏播放器固定暗色前景，不随应用「浅色模式」反色。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/app/player_theme.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/providers.dart';
import 'package:archoera_music/theme/cover_color.dart';

class _PrefsNotifier extends AppPrefsNotifier {
  _PrefsNotifier(this.mode);

  final String mode;

  @override
  AppPrefs build() => AppPrefs()
      .copyWithThemeMode(mode)
      // custom 来源不需要系统强调色，避免单测触碰平台桥接。
      .copyWithThemeSource('custom');
}

class _NullCoverColorNotifier extends CoverColorNotifier {
  @override
  Color? build() => null;
}

ThemeData _playerTheme(String mode) {
  final container = ProviderContainer(
    overrides: [
      appPrefsProvider.overrideWith(() => _PrefsNotifier(mode)),
      coverColorProvider.overrideWith(_NullCoverColorNotifier.new),
      systemAccentProvider.overrideWithValue(const AsyncData<Color?>(null)),
    ],
  );
  addTearDown(container.dispose);
  return container.read(playerThemeProvider);
}

void main() {
  test('浅色模式下播放页仍使用暗色主题（前景保持亮色）', () {
    final theme = _playerTheme('light');
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(
      theme.colorScheme.onSurface.computeLuminance(),
      greaterThan(0.5),
      reason: '前景必须为亮色，避免压在暗背景上出现「反色」',
    );
  });

  test('深色模式与浅色模式的播放页主题一致', () {
    final light = _playerTheme('light');
    final dark = _playerTheme('dark');
    expect(light.brightness, dark.brightness);
    expect(light.colorScheme.onSurface, dark.colorScheme.onSurface);
    expect(light.colorScheme.surface, dark.colorScheme.surface);
  });
}

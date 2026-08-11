import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 主题模式（对照原项目 appearance.themeMode：light / dark / system）。
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;

  /// 循环切换 light → dark → system（对齐原项目 NavHeader 主题按钮）。
  void cycle() {
    state = switch (state) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.light,
    };
  }

  /// 显式设置主题模式（设置弹窗三态选择）。
  void setMode(ThemeMode mode) => state = mode;
}

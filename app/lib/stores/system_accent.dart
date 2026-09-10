// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/platform/platform_capabilities.dart';

/// 读取系统（GNOME/Wayland）主题色，作为应用主色种子来源。
///
/// 实现：`gsettings get org.gnome.desktop.interface accent-color`
/// （GNOME 42+ 内置主题色；48+ 支持 `rgb(r,g,b)` 自定义值）。
/// 非 Linux / 无 gsettings / 未设置时返回 null，调用方回退设计体系默认亮蓝。
class SystemAccent {
  const SystemAccent._();

  /// GNOME 内置主题色（libadwaita accent color 近似值）。
  static const Map<String, int> _named = {
    'blue': 0xFF3584E4,
    'teal': 0xFF2190A0,
    'green': 0xFF3A944A,
    'yellow': 0xFFC88800,
    'orange': 0xFFDB7A2E,
    'red': 0xFFED333B,
    'pink': 0xFFE93D6C,
    'purple': 0xFF9141AC,
    'slate': 0xFF6A7A8F,
  };

  /// 当前系统主题色；优先经 Zig 平台桥接（KDE/GNOME 跨 DE），失败回退 gsettings。
  static Future<Color?> read() async {
    // 1) 平台桥接（DE accent，跨平台/跨桌面）
    try {
      final c = PlatformCapabilities.instance().systemAccent();
      if (c != null) return c;
    } catch (_) {}
    // 2) 回退：GNOME gsettings
    if (!Platform.isLinux) return null;
    try {
      final res = await Process.run('gsettings', [
        'get',
        'org.gnome.desktop.interface',
        'accent-color',
      ]);
      if (res.exitCode != 0) return null;
      return _parse((res.stdout as String).trim());
    } catch (_) {
      return null;
    }
  }

  static Color? _parse(String raw) {
    // 命名色：`'blue'` 等（GNOME 42+）
    final named = raw.replaceAll("'", '').trim().toLowerCase();
    final mapped = _named[named];
    if (mapped != null) return Color(mapped);
    // 自定义值：`rgb(r, g, b)`（GNOME 48+）
    final m = RegExp(
      r'rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
    ).firstMatch(raw);
    if (m != null) {
      final r = int.tryParse(m.group(1)!);
      final g = int.tryParse(m.group(2)!);
      final b = int.tryParse(m.group(3)!);
      if (r != null &&
          g != null &&
          b != null &&
          r <= 255 &&
          g <= 255 &&
          b <= 255) {
        return Color.fromARGB(255, r, g, b);
      }
    }
    return null;
  }
}

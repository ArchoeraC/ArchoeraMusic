// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏封面右缘渐隐遮罩的 GLSL 加载器。
///
/// 着色器用低频噪声扰动椭圆距离场，让渐隐边界不是一条过于规则的弧线；
/// 加载失败 / 测试环境回退到 `RadialGradient`（见
/// `player_cover/fullscreen_cover_view.dart`）。
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../services/log/log.dart';

/// 着色器资产路径（pubspec `flutter: shaders:`）。
const String kCoverMaskShaderAsset = 'shaders/cover_mask.frag';

/// uniform 浮点索引（与 `shaders/cover_mask.frag` 声明顺序一致）。
class CoverMaskUniforms {
  const CoverMaskUniforms._();

  /// vec2 uSize → 0,1
  static const int size = 0;

  /// 每首封面的稳定随机相位。
  static const int seed = 2;
}

/// 渐隐遮罩着色器加载（成功缓存；失败返回 null）。
class CoverMaskShader {
  CoverMaskShader._();

  static ui.FragmentProgram? _program;
  static bool _tried = false;

  /// 已加载的程序（未加载/失败为 null）。
  static ui.FragmentProgram? get program => _program;

  /// 加载（幂等）。
  static Future<ui.FragmentProgram?> load() async {
    if (_tried) return _program;
    _tried = true;
    // flutter test 的软件渲染不保证 runtime effect 被光栅化；测试环境走
    // RadialGradient 回退，保证 widget 测试确定。
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _program = null;
      return null;
    }
    try {
      _program = await ui.FragmentProgram.fromAsset(kCoverMaskShaderAsset);
    } catch (e) {
      Log.w('cover-mask', '渐隐遮罩着色器不可用，回退椭圆渐变: $e');
      _program = null;
    }
    return _program;
  }

  /// 测试用：重置缓存。
  @visibleForTesting
  static void reset() {
    _tried = false;
    _program = null;
  }
}

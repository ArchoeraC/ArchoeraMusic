// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「流体」背景 GLSL 片元着色器加载与 uniform 布局（对齐上游 AMLL
/// `MeshGradientRenderer`）。
///
/// 程序从 `shaders/fluid.frag` 加载；失败返回 null，调用方回退「预烘焙封面
/// 直铺」（见 `fluid_background.dart`）。Hermite 网格形变在 Dart 侧一次性
/// 烘焙为位移贴图（见 `fluid_mesh.dart`），片元只做旋转/缩放/dither/晕影。
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 着色器资产路径（pubspec `flutter: shaders:`）。
const String kFluidShaderAsset = 'shaders/fluid.frag';

/// 是否启用 GPU 着色器流体路径。
///
/// **默认开启**；设环境变量 `ARCHOERA_FLUID_SHADER=0` 可在不改代码、不重编译的
/// 情况下回退「预烘焙封面直铺」做 A/B（着色器加载失败/测试环境同样回退）。
final bool kEnableFluidShader =
    Platform.environment['ARCHOERA_FLUID_SHADER'] != '0';

/// 浮点 uniform 的展平索引布局（顺序须与 `shaders/fluid.frag` 声明一致）。
///
/// `FragmentShader.setFloat` 的索引 = 全部非 sampler uniform 按声明顺序展平的
/// 位置；sampler 索引单独从 0 计。修改着色器 uniform 必须同步此处。
class FluidUniforms {
  const FluidUniforms._();

  static const int size = 0; // vec2 uSize → 0,1
  static const int aspect = 2; // uAspect
  static const int volume = 3; // uVolume
  static const int sinAngle = 4; // uSinAngle
  static const int cosAngle = 5; // uCosAngle
  static const int alpha = 6; // uAlpha

  static const int samplerWarp = 0; // uWarp
  static const int samplerCover = 1; // uCover
}

/// 着色器程序加载器：成功缓存，失败返回 null（调用方回退直铺）。
class FluidShaderLoader {
  FluidShaderLoader._();

  static ui.FragmentProgram? _program;
  static bool _tried = false;

  /// 是否已加载到可用程序。
  static bool get available => _program != null;

  /// 加载（幂等）。失败打印一次并返回 null。
  static Future<ui.FragmentProgram?> load() async {
    if (_tried) return _program;
    _tried = true;
    // flutter test 的软件渲染不保证 runtime effect 被光栅化（会得到空白帧），
    // 故测试环境直接走直铺回退，保证 widget 测试确定；真机/打包走 GPU 主路径。
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _program = null;
      return null;
    }
    try {
      _program = await ui.FragmentProgram.fromAsset(kFluidShaderAsset);
    } catch (e) {
      debugPrint('[fluid] GLSL 着色器不可用，回退封面直铺: $e');
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

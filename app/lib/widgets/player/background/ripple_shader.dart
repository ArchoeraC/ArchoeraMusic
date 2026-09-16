// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 水纹背景 GLSL 片元着色器加载与 uniform 布局（P2）。
///
/// 程序从 `shaders/ripple.frag` 加载；失败返回 null，调用方回退 CPU 自绘
/// （见 docs/player-render-optimization.md §3.3：渲染器优先，CPU 仅兜底）。
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 着色器资产路径（pubspec `flutter: shaders:`）。
const String kRippleShaderAsset = 'shaders/ripple.frag';

/// 是否启用 GPU 着色器水纹路径。
///
/// **默认开启**（2026-09-16 爆改后）；设环境变量 `ARCHOERA_RIPPLE_SHADER=0`
/// 可在**不改代码、不重编译**的情况下回退 CPU 网格路径做 A/B。
///
/// 背景与依据：2026-09-11 测得「朴素 48 次全量循环（乘 0 掩码、逐像素全量
/// sqrt/exp/sin）」在集显（Intel Raptor Lake UHD）上远超帧预算，故当时默认关闭。
/// 2026-09-16 依 Flutter 官方《Writing efficient shaders》
/// （flutter/docs/engine/impeller/docs/shader_optimization.md）彻底重写：
/// - **uniform `break` + varying `continue` 精确早退**：波带外不再计算
///   sqrt/exp/sin（官方：「不要压平简单 varying 分支」）；
/// - **波带边界 CPU 预计算**为 `outer²/inner²`（`uBand`），每像素每涟漪只需
///   2 次比较；
/// - **CPU 精确剔除完全移出屏幕的涟漪**（不改变输出），显著降低循环次数；
/// - `uMix >= 0.999` 时只采样一次封面纹理（官方：「不要压平 uniform 分支」）。
///
/// 输出与 CPU 网格路径逐像素等价（`|dw| > 0.5` 处 `exp(-24) ≈ 4e-11`）。
/// 若目标集显实测仍超预算，回退 CPU 网格或改走「低分辨率场纹理」两遍方案。
final bool kEnableRippleShader =
    Platform.environment['ARCHOERA_RIPPLE_SHADER'] != '0';

/// 着色器内涟漪上限（须与 ripple.frag 的 `uRipples[48]` 一致）。
const int kRippleShaderMaxRipples = 48;

/// 浮点 uniform 的展平索引布局（顺序须与 `shaders/ripple.frag` 声明一致）。
///
/// `FragmentShader.setFloat` 的索引 = 全部非 sampler uniform 按声明顺序展平的
/// 位置；sampler 索引单独从 0 计。修改着色器 uniform 必须同步此处。
class RippleUniforms {
  const RippleUniforms._();

  static const int size = 0; // vec2 uSize → 0,1
  static const int darken = 2; // uDarken
  static const int saturation = 3; // uSaturation
  static const int imgAspect = 4; // uImgAspect
  static const int mix = 5; // uMix
  static const int ripples = 6; // vec4[48] (x, y, radius, amp)
  static const int band = ripples + kRippleShaderMaxRipples * 4; // vec4[48]
  static const int count = band + kRippleShaderMaxRipples * 4; // uCount

  static const int samplerFrom = 0; // uCoverFrom
  static const int samplerTo = 1; // uCoverTo
}

/// 着色器程序加载器：成功缓存，失败返回 null（调用方回退 CPU 自绘）。
class RippleShaderLoader {
  RippleShaderLoader._();

  static ui.FragmentProgram? _program;
  static bool _tried = false;

  /// 是否已加载到可用程序。
  static bool get available => _program != null;

  /// 加载（幂等）。失败打印一次并返回 null。
  static Future<ui.FragmentProgram?> load() async {
    if (_tried) return _program;
    _tried = true;
    // flutter test 的软件渲染不保证 runtime effect 被光栅化（会得到空白帧），
    // 故测试环境直接走 CPU 兜底，保证像素级断言确定；真机/打包走 GPU 主路径。
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _program = null;
      return null;
    }
    try {
      _program = await ui.FragmentProgram.fromAsset(kRippleShaderAsset);
    } catch (e) {
      debugPrint('[ripple] GLSL 着色器不可用，回退 CPU 自绘: $e');
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

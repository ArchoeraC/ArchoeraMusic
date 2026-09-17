// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体着色器 uniform 布局与 Dart 常量一致性测试。
///
/// `FragmentShader.setFloat` 的索引依赖 GLSL uniform 的声明顺序；本测试解析
/// `shaders/fluid.frag`，按声明顺序展平浮点偏移，校验 [FluidUniforms] 未漂移。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/background/fluid_shader.dart';

const Map<String, int> _typeFloats = {
  'float': 1,
  'vec2': 2,
  'vec3': 3,
  'vec4': 4,
  'mat2': 4,
  'mat3': 9,
  'mat4': 16,
};

void main() {
  test('fluid.frag 的浮点 uniform 偏移与 FluidUniforms 一致', () {
    final src = File('shaders/fluid.frag').readAsStringSync();
    final re = RegExp(r'uniform\s+(\w+)\s+(\w+)\s*(?:\[(\d+)\])?\s*;');

    final floatOffsets = <String, int>{};
    final samplerOffsets = <String, int>{};
    var fOff = 0;
    var sOff = 0;
    for (final line in src.split('\n')) {
      final m = re.firstMatch(line);
      if (m == null) continue;
      final type = m.group(1)!;
      final name = m.group(2)!;
      if (type == 'sampler2D') {
        samplerOffsets[name] = sOff++;
        continue;
      }
      final count = int.tryParse(m.group(3) ?? '1') ?? 1;
      floatOffsets[name] = fOff;
      fOff += count * (_typeFloats[type] ?? 1);
    }

    expect(floatOffsets['uSize'], FluidUniforms.size);
    expect(floatOffsets['uAspect'], FluidUniforms.aspect);
    expect(floatOffsets['uVolume'], FluidUniforms.volume);
    expect(floatOffsets['uSinAngle'], FluidUniforms.sinAngle);
    expect(floatOffsets['uCosAngle'], FluidUniforms.cosAngle);
    expect(floatOffsets['uAlpha'], FluidUniforms.alpha);

    // 浮点总数与常量推导一致（alpha 为最后一槽）。
    expect(fOff, FluidUniforms.alpha + 1);

    // 采样器顺序。
    expect(samplerOffsets['uWarp'], FluidUniforms.samplerWarp);
    expect(samplerOffsets['uCover'], FluidUniforms.samplerCover);
  });
}

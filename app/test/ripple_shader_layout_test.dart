// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 水纹着色器 uniform 布局与 Dart 常量一致性测试。
///
/// `FragmentShader.setFloat` 的索引依赖 GLSL uniform 的声明顺序；本测试解析
/// `shaders/ripple.frag`，按声明顺序展平浮点偏移，校验 [RippleUniforms] 与
/// [kRippleShaderMaxRipples] 未漂移。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/ripple_shader.dart';

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
  test('ripple.frag 的浮点 uniform 偏移与 RippleUniforms 一致', () {
    final src = File('shaders/ripple.frag').readAsStringSync();
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

    expect(floatOffsets['uSize'], RippleUniforms.size);
    expect(floatOffsets['uDarken'], RippleUniforms.darken);
    expect(floatOffsets['uSaturation'], RippleUniforms.saturation);
    expect(floatOffsets['uImgAspect'], RippleUniforms.imgAspect);
    expect(floatOffsets['uMix'], RippleUniforms.mix);
    expect(floatOffsets['uRipples'], RippleUniforms.ripples);
    expect(floatOffsets['uSeeds'], RippleUniforms.seeds);
    expect(floatOffsets['uCount'], RippleUniforms.count);

    // 浮点总数与常量推导一致（count 为最后一槽）。
    expect(fOff, RippleUniforms.count + 1);

    // 采样器顺序。
    expect(samplerOffsets['uCoverFrom'], RippleUniforms.samplerFrom);
    expect(samplerOffsets['uCoverTo'], RippleUniforms.samplerTo);

    // 涟漪上限与着色器数组长度一致。
    final mRipples = RegExp(r'uniform\s+vec4\s+uRipples\s*\[(\d+)\]').firstMatch(src);
    expect(mRipples, isNotNull);
    expect(int.parse(mRipples!.group(1)!), kRippleShaderMaxRipples);
  });
}

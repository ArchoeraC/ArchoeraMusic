// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体位移贴图几何（Hermite 网格前向栅格化）测试。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/background/fluid_mesh.dart';

FluidControlPointPreset _default2x2() => FluidControlPointPreset(2, 2, [
  FluidControlPointConf(0, 0, -1, -1),
  FluidControlPointConf(1, 0, 1, -1),
  FluidControlPointConf(0, 1, -1, 1),
  FluidControlPointConf(1, 1, 1, 1),
]);

int _r(int argb) => (argb >> 16) & 0xFF;
int _g(int argb) => (argb >> 8) & 0xFF;
int _a(int argb) => (argb >> 24) & 0xFF;

void main() {
  group('buildFluidWarpMesh', () {
    test('默认 2×2 网格退化为线性映射（逐位校验位置/UV）', () {
      final mesh = buildFluidWarpMesh(
        _default2x2(),
        resolution: 8,
        subdiv: 2,
      );
      // 顶点数 = (w-1)*subdiv × (h-1)*subdiv。
      expect(mesh.positions.length, 4 * 2);
      expect(mesh.colors.length, 4);
      expect(mesh.indices.length, 6);
      expect(mesh.indices, [0, 1, 2, 1, 3, 2]);

      // idx = u + v*vertexWidth，位置 (v*res, (1-u)*res)，UV = (v, 1-u)。
      const res = 8.0;
      double px(int i) => mesh.positions[i * 2];
      double py(int i) => mesh.positions[i * 2 + 1];
      expect(px(0), 0);
      expect(py(0), res);
      expect(px(1), 0);
      expect(py(1), 0);
      expect(px(2), res);
      expect(py(2), res);
      expect(px(3), res);
      expect(py(3), 0);

      expect(_r(mesh.colors[0]), 0);
      expect(_g(mesh.colors[0]), 255);
      expect(_r(mesh.colors[1]), 0);
      expect(_g(mesh.colors[1]), 0);
      expect(_r(mesh.colors[2]), 255);
      expect(_g(mesh.colors[2]), 255);
      expect(_r(mesh.colors[3]), 255);
      expect(_g(mesh.colors[3]), 0);
      for (var i = 0; i < 4; i++) {
        expect(_a(mesh.colors[i]), 255);
      }
    });

    test('预设网格：尺寸/索引/颜色范围合法', () {
      final preset = kFluidControlPointPresets.first;
      final mesh = buildFluidWarpMesh(preset, resolution: 32, subdiv: 4);
      final vertexWidth = (preset.width - 1) * 4;
      final vertexHeight = (preset.height - 1) * 4;
      expect(mesh.positions.length, vertexWidth * vertexHeight * 2);
      expect(mesh.colors.length, vertexWidth * vertexHeight);
      expect(
        mesh.indices.length,
        (vertexWidth - 1) * (vertexHeight - 1) * 6,
      );
      for (var i = 0; i < mesh.colors.length; i++) {
        expect(_a(mesh.colors[i]), 255);
        expect(_r(mesh.colors[i]), inInclusiveRange(0, 255));
        expect(_g(mesh.colors[i]), inInclusiveRange(0, 255));
        final x = mesh.positions[i * 2];
        final y = mesh.positions[i * 2 + 1];
        expect(x.isFinite, isTrue);
        expect(y.isFinite, isTrue);
        // 边界由预设固定，内部形变不越界太多。
        expect(x, inInclusiveRange(-32, 64));
        expect(y, inInclusiveRange(-32, 64));
      }
    });
  });

  group('预设与随机生成', () {
    test('5 组内置预设均为方阵且控制点数匹配', () {
      expect(kFluidControlPointPresets.length, 5);
      for (final p in kFluidControlPointPresets) {
        expect(p.width, p.height);
        expect(p.width, greaterThanOrEqualTo(2));
        expect(p.conf.length, p.width * p.height);
      }
    });

    test('随机生成返回合法网格', () {
      final p = generateFluidControlPoints(6, 6, random: math.Random(7));
      expect(p.width, 6);
      expect(p.height, 6);
      expect(p.conf.length, 36);
      // 边界控制点不被扰动（对齐上游）。
      expect(p.conf.first.x, -1);
      expect(p.conf.first.y, -1);
      expect(p.conf.last.x, 1);
      expect(p.conf.last.y, 1);
    });

    test('pickFluidControlPoints 恒返回可用网格', () {
      for (var seed = 0; seed < 20; seed++) {
        final p = pickFluidControlPoints(random: math.Random(seed));
        expect(p.width, greaterThanOrEqualTo(2));
        expect(p.height, greaterThanOrEqualTo(2));
        expect(p.conf.length, p.width * p.height);
      }
    });
  });
}

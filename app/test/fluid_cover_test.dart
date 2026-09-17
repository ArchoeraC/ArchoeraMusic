// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体背景封面预烘焙（降采样 + 合并色调 + 盒式模糊）与低频脉冲测试。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/background/fluid_background.dart';
import 'package:archoera_music/widgets/player/background/fluid_cover.dart';

/// 生成 [w]×[h] 的灰度 RGBA 图（alpha 255）。
Uint8List _gray(int w, int h, int value) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    out[i * 4] = value;
    out[i * 4 + 1] = value;
    out[i * 4 + 2] = value;
    out[i * 4 + 3] = 255;
  }
  return out;
}

void main() {
  group('processFluidCover', () {
    test('尺寸为 32×32×4 且 alpha 恒为 255', () {
      final out = processFluidCover(_gray(64, 64, 128), 64, 64);
      expect(out.length, kFluidCoverSize * kFluidCoverSize * 4);
      for (var i = 3; i < out.length; i += 4) {
        expect(out[i], 255);
      }
    });

    test('合并色调矩阵：灰 128 → 96、黑 0 → 31（对齐上游四步）', () {
      final mid = processFluidCover(_gray(32, 32, 128), 32, 32);
      for (var i = 0; i < mid.length; i += 4) {
        expect(mid[i], 96);
        expect(mid[i + 1], 96);
        expect(mid[i + 2], 96);
      }
      final black = processFluidCover(_gray(32, 32, 0), 32, 32);
      for (var i = 0; i < black.length; i += 4) {
        expect(black[i], 31);
      }
    });

    test('盒式模糊会平滑阶跃（边界列取中间值）', () {
      // 左半黑、右半白。
      const w = 32, h = 32;
      final src = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = x < w ~/ 2 ? 0 : 255;
          final p = (y * w + x) * 4;
          src[p] = v;
          src[p + 1] = v;
          src[p + 2] = v;
          src[p + 3] = 255;
        }
      }
      final out = processFluidCover(src, w, h);
      // 中心行边界两侧的 R 应落在两端（31 / 161）之间，证明模糊生效。
      final y = h ~/ 2;
      final left = out[((y * w + (w ~/ 2 - 1)) * 4)];
      final right = out[((y * w + (w ~/ 2)) * 4)];
      expect(left, greaterThan(31));
      expect(left, lessThan(161));
      expect(right, greaterThan(31));
      expect(right, lessThan(161));
    });

    test('下采样不崩溃（源小于目标）', () {
      final out = processFluidCover(_gray(3, 3, 200), 3, 3);
      expect(out.length, kFluidCoverSize * kFluidCoverSize * 4);
    });
  });

  group('fluidBassPulse', () {
    test('空数据 / 全零 → 0', () {
      expect(fluidBassPulse(const [], const []), 0);
      expect(fluidBassPulse(List.filled(128, 0), List.filled(128, 0)), 0);
    });

    test('满能量 → 1（clamp 后）', () {
      final pulse = fluidBassPulse(List.filled(128, 1), List.filled(128, 1));
      expect(pulse, 1);
    });

    test('中等能量落在 (0,1)', () {
      final pulse = fluidBassPulse(
        List.filled(128, 0.35),
        List.filled(128, 0.35),
      );
      expect(pulse, greaterThan(0));
      expect(pulse, lessThan(1));
    });
  });
}

#version 460 core
#include <flutter/runtime_effect.glsl>

// ArchoeraMusic 全屏封面右缘渐隐遮罩。
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 目标：以横向直线为基础，不要一条笔直的竖线，也不要用椭圆。用低频噪声
// 扰动横向距离，让渐隐边界有轻微起伏，但不会出现明显颗粒。
//
// uniform（浮点索引，忽略 sampler）：
//   0,1 uSize（画布逻辑尺寸） | 2 uSeed（每首封面的稳定随机相位）
// 仅输出 alpha，配合 ShaderMask(BlendMode.dstIn) 使用。

precision highp float;

uniform vec2 uSize;
uniform float uSeed;

out vec4 fragColor;

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;

  // 以横向直线为基础；uSeed 只轻微移动直线的整体位置，让每首封面略不同。
  float d = uv.x + sin(uSeed * 1.7) * 0.015;

  // 两个低频噪声八度，扰动幅度约 ±0.07：边界仍有直线趋势，只是轻微起伏。
  float n1 = valueNoise(vec2(uv.x * 3.2 + uSeed, uv.y * 2.4 - uSeed * 0.7));
  float n2 = valueNoise(vec2(uv.x * 7.0 - uSeed * 0.5, uv.y * 5.0 + uSeed));
  d += (n1 - 0.5) * 0.10 + (n2 - 0.5) * 0.04;

  // 0.55 之前完全保留封面，0.92 之后完全透明；文字起点约 x=0.52 页宽。
  float alpha = 1.0 - smoothstep(0.55, 0.92, d);
  fragColor = vec4(1.0, 1.0, 1.0, alpha);
}

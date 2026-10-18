#version 460 core
#include <flutter/runtime_effect.glsl>

// ArchoeraMusic 全屏封面右缘渐隐遮罩。
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 目标：不要一条笔直的竖线，也不要一个过于规则的椭圆。用低频噪声扰动
// 距离场，让渐隐边界有轻微起伏，但不会出现明显颗粒。
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

  // 以左缘附近为圆心的椭圆距离：上下先淡出，中间保留最久。
  // uSeed 同时轻微改变椭圆中心与纵向比例，让每首封面的弧线形状不同。
  float yCenter = 0.5 + sin(uSeed * 1.7) * 0.035;
  float yScale = 1.22 + cos(uSeed * 2.3) * 0.10;
  vec2 p = vec2(uv.x, (uv.y - yCenter) * yScale);
  float d = length(p);

  // 两个低频噪声八度，扰动幅度约 ±0.08；避免机械的完美椭圆。
  float n1 = valueNoise(vec2(uv.x * 3.2 + uSeed, uv.y * 2.4 - uSeed * 0.7));
  float n2 = valueNoise(vec2(uv.x * 7.0 - uSeed * 0.5, uv.y * 5.0 + uSeed));
  d += (n1 - 0.5) * 0.12 + (n2 - 0.5) * 0.05;

  // 0.55 之前完全保留封面，0.92 之后完全透明；文字起点约 x=0.52 页宽。
  float alpha = 1.0 - smoothstep(0.55, 0.92, d);
  fragColor = vec4(1.0, 1.0, 1.0, alpha);
}

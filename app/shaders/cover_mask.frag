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
  float aspect = uSize.x / max(uSize.y, 1.0);

  // ── 每首封面的形状参数（稳定 seed）──────────────────────────────
  // 轻微倾斜 + 两个低频正弦，让边界先有「大趋势」，再由噪声打散细节。
  float tilt = sin(uSeed * 1.7) * 0.060;
  float phase = uSeed * 2.0;
  float start = 0.48 + fract(uSeed * 0.37) * 0.08; // 0.48 ~ 0.56
  float end = 0.88 + fract(uSeed * 0.61) * 0.05;   // 0.88 ~ 0.93

  float d = uv.x + (uv.y - 0.5) * tilt;
  d += sin(uv.y * 3.1 + phase) * 0.022;
  d += sin(uv.y * 6.3 - phase * 0.6) * 0.010;

  // ── 各向同性噪声：按宽高比校正采样域，窗口/封面比例变化时颗粒不被拉长 ──
  vec2 np = vec2(uv.x * aspect, uv.y) * 2.6 + uSeed * 1.7;
  float n1 = valueNoise(np);
  float n2 = valueNoise(np * 2.7 + 11.3);
  float n3 = valueNoise(np * 6.1 - 7.1);
  d += (n1 - 0.5) * 0.12 + (n2 - 0.5) * 0.05 + (n3 - 0.5) * 0.02;

  // 0.48~0.56 之前完全保留，0.88~0.93 之后完全透明；文字起点约 x=0.52 页宽。
  float alpha = 1.0 - smoothstep(start, end, d);
  fragColor = vec4(1.0, 1.0, 1.0, alpha);
}

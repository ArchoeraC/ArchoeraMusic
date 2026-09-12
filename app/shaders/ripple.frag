#version 460 core
#include <flutter/runtime_effect.glsl>

// ArchoeraMusic 播放页水纹背景（P2）。
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 与 WGSL/WebGL 场公式一致；单 pass 完成
// 「折射 + 饱和 + 波峰高光/波谷压暗 + 压暗」，封面模糊由 Dart 侧预烘焙（不在
// 每帧重复）。uniform 的浮点索引按下方声明顺序（忽略 sampler）：
//   0,1 uSize | 2 uDarken | 3 uSaturation | 4 uImgAspect | 5 uMix
//   6.. uRipples[48]（vec4: x, y, radius, amp） | 后接 uSeeds[48] | uCount
// sampler：0 uCoverFrom | 1 uCoverTo
// 见 Dart 侧 RippleUniforms（app/lib/widgets/player/ripple_shader.dart）。

precision highp float;

uniform vec2 uSize;
uniform float uDarken;
uniform float uSaturation;
uniform float uImgAspect;
uniform float uMix;
uniform vec4 uRipples[48];
uniform float uSeeds[48];
uniform float uCount;
uniform sampler2D uCoverFrom;
uniform sampler2D uCoverTo;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float aspect = uSize.x / uSize.y;
  int count = int(uCount + 0.5);

  vec2 offset = vec2(0.0);
  float light = 0.0;
  for (int i = 0; i < 48; i++) {
    // 用乘法掩码代替 break，保持循环可展开（Impeller/Skia 均稳）。
    float on = i < count ? 1.0 : 0.0;
    vec4 rp = uRipples[i];
    float dx = (uv.x - rp.x) * aspect;
    float dy = (uv.y - rp.y);
    float dc = sqrt(dx * dx + dy * dy);
    float dw = dc - rp.z; // rp.z = age * speed
    float band = exp(-abs(dw) * 48.0);
    float wave = sin(dw * 115.0 + uSeeds[i]) * band * rp.w * on; // rp.w = env*strength
    float ex = dx + 0.0001;
    float ey = dy + 0.0001;
    float inv = 1.0 / sqrt(ex * ex + ey * ey);
    offset += vec2(ex, ey) * inv * wave * 0.015;
    light += wave;
  }

  vec2 t = uv + offset;
  // 封面 cover 适配（与 CPU 版一致）。
  if (aspect > uImgAspect) {
    t.y = (t.y - 0.5) * (uImgAspect / aspect) + 0.5;
  } else {
    t.x = (t.x - 0.5) * (aspect / uImgAspect) + 0.5;
  }
  t = clamp(t, 0.001, 0.999);

  vec3 from = texture(uCoverFrom, t).rgb;
  vec3 to = texture(uCoverTo, t).rgb;
  vec3 col = mix(from, to, uMix);

  // 饱和（对齐上游 saturate）。
  float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = mix(vec3(l), col, uSaturation);

  // 波峰高光 / 波谷压暗（对齐上游）。
  float hi = light > 0.0 ? clamp(light * 0.14, 0.0, 1.0) : 0.0;
  float lo = light < 0.0 ? clamp(-light * 0.09, 0.0, 1.0) : 0.0;
  col = col * (1.0 - lo) + vec3(hi);

  // 整体压暗（保证叠加内容可读）。
  col *= (1.0 - uDarken);

  fragColor = vec4(col, 1.0);
}

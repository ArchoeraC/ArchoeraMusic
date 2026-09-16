#version 460 core
#include <flutter/runtime_effect.glsl>

// ArchoeraMusic 播放页水纹背景（P2）。
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 与 WGSL/WebGL 场公式一致；单 pass 完成
// 「折射 + 饱和 + 波峰高光/波谷压暗 + 压暗」，封面模糊由 Dart 侧预烘焙（不在
// 每帧重复）。
//
// 性能（对齐 Flutter 官方《Writing efficient shaders》：
// flutter/docs/engine/impeller/docs/shader_optimization.md）：
//  - 「不要压平简单 varying 分支」：波带外的涟漪用真实 `continue` 跳过
//    sqrt/exp/sin，而不是乘 0 掩码——SIMT 架构（Intel/AMD/Apple 集显）下
//    整波跳过，旧 VLIW 至多略慢。此优化**逐像素等价**：`|dw| > kBandCut`
//    处 `exp(-|dw|*48) <= exp(-24) ≈ 4e-11`，对 8bit 颜色为 0；与 CPU 网格
//    路径（`_bandCut`）一致。
//  - 「不要压平 uniform 分支」：`uCount` / `uMix` 为 uniform，整波同路，
//    只走一支（`break` / 单次纹理采样）。
//
// uniform 的浮点索引按下方声明顺序（忽略 sampler）：
//   0,1 uSize | 2 uDarken | 3 uSaturation | 4 uImgAspect | 5 uMix
//   6.. uRipples[48]（vec4: x, y, radius, amp）
//   后接 uBand[48]（vec4: outer², inner², seed, 0） | uCount
// sampler：0 uCoverFrom | 1 uCoverTo
// 见 Dart 侧 RippleUniforms（app/lib/widgets/player/background/ripple_shader.dart）。

precision highp float;

uniform vec2 uSize;
uniform float uDarken;
uniform float uSaturation;
uniform float uImgAspect;
uniform float uMix;
uniform vec4 uRipples[48];
uniform vec4 uBand[48];
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
    // uniform 分支：i >= count 时整波同路，直接跳出（替代乘 0 掩码）。
    if (i >= count) break;
    vec4 rp = uRipples[i];
    vec4 b = uBand[i];
    float dx = (uv.x - rp.x) * aspect;
    float dy = (uv.y - rp.y);
    float d2 = dx * dx + dy * dy;
    // varying 分支：波带边界已由 CPU 预计算为平方距离，这里只需 2 次比较即可
    // 精确跳过 sqrt/exp/sin（|dw| > 0.5 ⇒ 贡献 <= exp(-24) ≈ 4e-11）。
    // inner² == 0 时 `d2 < 0` 恒假，天然覆盖「波带含中心」情形。
    if (d2 > b.x) continue; // 外边界
    if (d2 < b.y) continue; // 内边界
    float dc = sqrt(d2);
    float dw = dc - rp.z;
    float band = exp(-abs(dw) * 48.0);
    float wave = sin(dw * 115.0 + b.z) * band * rp.w;
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

  // uniform 分支：非交叉淡入时只采样一次封面纹理。
  vec3 col;
  if (uMix >= 0.999) {
    col = texture(uCoverFrom, t).rgb;
  } else {
    col = mix(texture(uCoverFrom, t).rgb, texture(uCoverTo, t).rgb, uMix);
  }

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

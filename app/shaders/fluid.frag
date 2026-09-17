#version 460 core
#include <flutter/runtime_effect.glsl>

// ArchoeraMusic 播放页「流体」背景（对齐上游 AMLL MeshGradientRenderer）。
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 上游为 WebGL 两段式：顶点网格（双三次 Hermite 形变）把封面采样到 FBO，
// 再以 quad 合成；片元阶段绕 (0.2,0.2) 旋转（时间+音量）→ 按 `1-音量` 缩放 →
// dither → 晕影 → 预乘混合。
//
// 本实现把「每首歌随机的 Hermite 控制点网格」在 Dart 侧**一次性前向栅格化**
// 为位移贴图（`uWarp`，RG 存 v_uv），片元只做：
//   屏幕 uv → 逆 aspect（还原上游顶点着色器）→ 采位移图得 v_uv →
//   旋转/缩放 → 镜像重复采封面 → 音量 alpha/晕影/dither。
// 位移图在**未 aspect 校正**的 [-1,1]² 空间烘焙，故窗口缩放无需重烘焙。
//
// 采样返回原始 sRGB 值（不额外解码），与 `ripple.frag` 及 CPU 逐像素路径一致。
//
// uniform 的浮点索引按下方声明顺序（忽略 sampler）：
//   0,1 uSize | 2 uAspect | 3 uVolume | 4 uSinAngle | 5 uCosAngle | 6 uAlpha
// sampler：0 uWarp | 1 uCover
// 见 Dart 侧 FluidUniforms（app/lib/widgets/player/background/fluid_shader.dart）。

precision highp float;

uniform vec2 uSize; // 画布逻辑尺寸（离屏渲染时为降分辨率尺寸）
uniform float uAspect; // 画布宽高比（与分辨率无关）
uniform float uVolume; // AMLL 低频音量 volume（上游 setLowFreqVolume/10）
uniform float uSinAngle;
uniform float uCosAngle;
uniform float uAlpha; // 交叉淡入 quad alpha（easeInOutSine(clamp01(state.alpha))）

uniform sampler2D uWarp; // 位移贴图：texel(a_pos) = v_uv（RG）
uniform sampler2D uCover; // 预烘焙 32×32 封面（对比度/饱和/亮度 + 盒式模糊）

out vec4 fragColor;

// ── 对齐上游主片元着色器的常量与工具 ──────────────────────────────
const float INV_255 = 1.0 / 255.0;
const float HALF_INV_255 = 0.5 / 255.0;
const float GRADIENT_NOISE_A = 52.9829189;
const vec2 GRADIENT_NOISE_B = vec2(0.06711056, 0.00583715);

float gradientNoise(vec2 p) {
  return fract(GRADIENT_NOISE_A * fract(dot(p, GRADIENT_NOISE_B)));
}

// 镜像重复（对齐上游纹理 MIRRORED_REPEAT）：周期 2，[0,1] 恒等、[1,2] 折返。
float mirrorRepeat(float x) {
  return 1.0 - abs(mod(x, 2.0) - 1.0);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize; // [0,1]，y 向下

  // 转 GL 裁剪空间（y 向上），再逆上游顶点着色器的 aspect 校正：
  //   aspect > 1: clip = (pos.x, pos.y * aspect)
  //   否则       : clip = (pos.x / aspect, pos.y)
  vec2 clip = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
  vec2 pos = uAspect > 1.0 ? vec2(clip.x, clip.y / uAspect)
                           : vec2(clip.x * uAspect, clip.y);

  // 位移图：烘焙时 image row 0 对应 pos.y = +1。
  vec2 warpUV = vec2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
  vec2 vUV = texture(uWarp, warpUV).rg;

  // 旋转（绕 (0.2,0.2)）→ 音量缩放（1 - volume*2）→ 平移到中心。
  float volumeEffect = uVolume * 2.0;
  vec2 centered = vUV - vec2(0.2);
  vec2 rotated = vec2(
    uCosAngle * centered.x - uSinAngle * centered.y,
    uSinAngle * centered.x + uCosAngle * centered.y
  );
  vec2 finalUV = rotated * max(0.001, 1.0 - volumeEffect) + vec2(0.5);
  finalUV = vec2(mirrorRepeat(finalUV.x), mirrorRepeat(finalUV.y));

  vec3 col = texture(uCover, finalUV).rgb;

  // 音量 alpha 因子（对齐上游 alphaVolumeFactor，u_alpha 主 pass 恒为 1）。
  float volumeAlpha = max(0.5, 1.0 - uVolume * 0.5);
  float dither = INV_255 * gradientNoise(frag) - HALF_INV_255;
  vec3 rgb = col * volumeAlpha + vec3(dither);

  // 晕影：以 v_uv（形变后的纹理坐标，非屏幕坐标）到中心的距离为准。
  float dist = distance(vUV, vec2(0.5));
  float mask = 0.6 + (1.0 - smoothstep(0.3, 0.8, dist)) * 0.4;
  rgb *= mask;

  // 预乘输出：上游 FBO 经 SRC_ALPHA/ONE_MINUS_SRC_ALPHA 合成等价于
  //   out = (col * volumeAlpha + dither) * mask * (volumeAlpha * uAlpha)
  //   a   = volumeAlpha * uAlpha
  float a = volumeAlpha * uAlpha;
  fragColor = vec4(rgb * a, a);
}

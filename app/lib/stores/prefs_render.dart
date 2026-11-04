// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 渲染 / 显卡加速域键（render. 前缀）─────────────────────────────
//
// 「性能 / 渲染」分类的可选开关（见 docs/runtime-resource-optimization.md）：
// 水纹渲染器（GPU 着色器 / CPU 网格）、动态层降分辨率、损伤区裁剪。
const rippleShaderKey = 'render.rippleShader';
const rippleLowResKey = 'render.rippleLowRes';
const rippleDamageClipKey = 'render.rippleDamageClip';
const lyricsEdgeFadeKey = 'render.lyricsEdgeFade';

/// 水纹 GPU 着色器（默认开）。关闭则走 CPU 网格回退路径。
///
/// 环境变量 `ARCHOERA_RIPPLE_SHADER=0` 可全局强制回退（优先级高于本偏好，
/// 见 `ripple_shader.dart` 的 [kEnableRippleShader]），用于现场 A/B。
const bool defaultRippleShader = true;

/// 动态层降分辨率（默认关；**仅 CPU 网格回退路径生效**）。
///
/// 开启后 CPU 动态层以 [rippleLowResScale] 离屏绘制再放大（见
/// `RippleBackground.renderScale`）。
const bool defaultRippleLowRes = false;

/// 动态层降分辨率倍率（开启 [defaultRippleLowRes] 时使用）。
const double rippleLowResScale = 0.5;

/// 损伤区裁剪（默认关；**仅 CPU 网格回退路径生效**）。
///
/// 开启后只重绘活动涟漪波带（`RippleBackground.damageClippedDynamic`）。
const bool defaultRippleDamageClip = false;

/// 歌词区上下渐隐的实现（默认 `wall`；见 `docs/player-render-optimization.md`
/// §4.2d）。
///
/// - `wall`：逐行 alpha，零离屏层（最省 GPU；仅 amll 物理墙支持，simple 引擎
///   自动回退 `shader`）；
/// - `shader`：外层 `ShaderMask`，每帧一次歌词列面积的离屏层（最平滑）；
/// - `off`：不做渐隐。
const String defaultLyricsEdgeFade = 'wall';
const Set<String> lyricsEdgeFadeValues = {'wall', 'shader', 'off'};

/// 渲染 / 显卡加速域偏好。
extension RenderPrefs on AppPrefs {
  /// 水纹 GPU 着色器（默认开）。
  bool get rippleShaderEnabled =>
      data[rippleShaderKey] as bool? ?? defaultRippleShader;

  /// 动态层降分辨率（默认关；仅 CPU 回退生效）。
  bool get rippleLowRes =>
      data[rippleLowResKey] as bool? ?? defaultRippleLowRes;

  /// 损伤区裁剪（默认关；仅 CPU 回退生效）。
  bool get rippleDamageClip =>
      data[rippleDamageClipKey] as bool? ?? defaultRippleDamageClip;

  /// 歌词区上下渐隐实现（`wall` / `shader` / `off`；默认 `wall`）。
  String get lyricsEdgeFade {
    final v = data[lyricsEdgeFadeKey];
    if (v is String && lyricsEdgeFadeValues.contains(v)) return v;
    return defaultLyricsEdgeFade;
  }

  /// 设置歌词区上下渐隐实现（非法值回退默认）。
  AppPrefs copyWithLyricsEdgeFade(String value) => AppPrefs(
    initialData: {
      ...data,
      lyricsEdgeFadeKey: lyricsEdgeFadeValues.contains(value)
          ? value
          : defaultLyricsEdgeFade,
    },
  );

  /// 设置水纹渲染器 / 动态层降分辨率 / 损伤区裁剪开关。
  AppPrefs copyWithRippleRender({
    bool? shader,
    bool? lowRes,
    bool? damageClip,
  }) => AppPrefs(
    initialData: {
      ...data,
      rippleShaderKey: ?shader,
      rippleLowResKey: ?lowRes,
      rippleDamageClipKey: ?damageClip,
    },
  );
}

// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/animation.dart';

/// 全屏播放页展开曲线（路由动画 0 → 1）：**先快后慢**。
///
/// 旧实现用 `Cubic(0.7, 0, 0.3, 1)`（对称 S 形：起步与收尾都近乎静止），
/// 观感「先慢、中间急、最后顿」。这里换成单峰、偏线性的 ease-out：
/// 起步斜率约为匀速的 2 倍，前 1/4 时间走完约 47% 位移，后段平滑收尾，
/// 整条曲线的速度变化比原 S 形更均匀。
///
/// 播放页上滑（`/player` 路由）与壳层收缩（`ShellExpandTransition`）共用
/// 同一条曲线，保证两者逐帧同步。
const Curve kPlayerRouteOpenCurve = Cubic(0.25, 0.5, 0.45, 0.95);

/// 全屏播放页收起曲线（路由动画 1 → 0）：**先慢后快**。
///
/// 收起时路由动画的原始值从 1 递减到 0，`CurvedAnimation.reverseCurve` 是
/// 直接作用在递减值上的（**不做** flipped）。因此这里填一条 ease-out 形状的
/// 曲线即可：`t` 接近 1（收起初段）时斜率小 → 起步慢，`t` 接近 0（收官）
/// 时斜率大 → 收尾快。若改用 `Curves.easeIn*`，反而会得到「先快后慢」。
const Curve kPlayerRouteCloseCurve = Cubic(0.25, 0.5, 0.45, 0.95);

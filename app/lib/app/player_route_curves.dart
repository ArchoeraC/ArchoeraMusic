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
const Curve kPlayerRouteOpenCurve = Cubic(0.25, 0.5, 0.45, 0.95);

/// 播放页本体上滑/下滑时长（**不含**播放条让出相位）。
///
/// 原为 500ms（对齐 Web 版），实机观感偏拖沓；降到 350ms 后起步更利落，
/// 仍保留足够位移让上滑/下滑可读。
const Duration kPlayerRouteSlideDuration = Duration(milliseconds: 350);

/// 播放条让出 / 回位时长。
///
/// 展开时**先**让播放条滑出（这段里播放页还停在屏幕下方不动），之后才
/// 开始整页上滑；收起完全倒序：播放页先滑走，最后这段留给播放条回位。
/// 取值参考播放条自身隐藏动效（300ms），压到 120ms 让它只做「让路」，
/// 不抢播放页的主体动作。
const Duration kPlayerBarExitDuration = Duration(milliseconds: 120);

/// 播放页进/出转场总时长 = 播放条相位 + 页面滑动（展开与收起同值）。
const Duration kPlayerRouteTransitionDuration = Duration(
  milliseconds: _kPlayerBarExitMs + _kPlayerRouteSlideMs,
);

/// 播放条相位占整段转场的比例（0~1，用于 `Interval` 切分）。
///
/// 展开：路由动画 `[0, kPlayerBarPhase]` 只让播放条滑出，播放页保持
/// `Offset(0, 1)`；`[kPlayerBarPhase, 1]` 才是页面上滑。收起时反向读取，
/// 于是天然得到「页面先下去、播放条最后回来」的倒序。
const double kPlayerBarPhase = _kPlayerBarExitMs / _kPlayerRouteTotalMs;

const int _kPlayerBarExitMs = 120;
const int _kPlayerRouteSlideMs = 350;
const int _kPlayerRouteTotalMs = _kPlayerBarExitMs + _kPlayerRouteSlideMs;

/// 全屏播放页收起曲线（路由动画 1 → 0）：**先慢后快**。
///
/// 收起时路由动画的原始值从 1 递减到 0，`CurvedAnimation.reverseCurve` 是
/// 直接作用在递减值上的（**不做** flipped）。因此这里填一条 ease-out 形状的
/// 曲线即可：`t` 接近 1（收起初段）时斜率小 → 起步慢，`t` 接近 0（收官）
/// 时斜率大 → 收尾快。若改用 `Curves.easeIn*`，反而会得到「先快后慢」。
const Curve kPlayerRouteCloseCurve = Cubic(0.25, 0.5, 0.45, 0.95);

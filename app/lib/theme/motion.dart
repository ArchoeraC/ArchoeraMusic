// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 应用统一动效节奏。
///
/// 目标：**近线性**。旧动效大量使用 `easeOutCubic` / `easeOutExpo` /
/// `easeOutBack`，起步极快、收尾极慢（或过冲），大位移时人眼会感觉
/// 「先窜出去再爬回来」，与连续滚动/拖动的直觉不一致。
///
/// [appMotion] 的贝塞尔控制点为 `(0.2, 0.2) / (0.8, 0.8)`：
/// - 两端斜率均为 1（与线性首尾速度一致，不会突然启停）；
/// - 中段只做极轻的平滑，接近匀速；
/// - 全程不过冲。
///
/// 透明度 / 颜色 / 音量等「没有速度感知」的量用 [appMotionLinear]；
/// 连续滚动、进度、跑马灯也用线性，避免每个换行点重新加速。
library;

import 'package:flutter/animation.dart';

/// 位置 / 形变 / 转场统一曲线（近线性、无过冲）。
const Curve appMotion = Cubic(0.2, 0.2, 0.8, 0.8);

/// 连续量（透明度 / 颜色 / 音量 / 滚动 / 进度）统一曲线。
const Curve appMotionLinear = Curves.linear;

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * parametric_eq.h — 参数化均衡器（方向① D1）
 *
 * 任意段数（≤ PEQ_MAX_BANDS）的 Biquad 均衡器：每段 {kind, freq, Q, gain_db}，
 * kind ∈ {peak, low-shelf, high-shelf}，外加统一前级增益。与固定 10 段
 * `equalizer.h` 并存；内核（Zig）可用时优先路由，失败回退本层纯 C 实现。
 *
 * 段以「扁平 float 数组」批量传入：`[kind, freq, q, gain, ...]`（每段 4 个），
 * 由命令层保证长度 % 4 == 0。
 */
#ifndef PARAMETRIC_EQ_H
#define PARAMETRIC_EQ_H

#include <stdbool.h>

/** 单实例最大段数（与内核 `era_peq_max_bands` 一致）。 */
#define PEQ_MAX_BANDS 16

/** 段类型（与内核 `EraBandKind` 数值一致）。 */
enum {
    PEQ_KIND_PEAK = 0,
    PEQ_KIND_LOW_SHELF = 1,
    PEQ_KIND_HIGH_SHELF = 2,
};

typedef struct ParametricEq ParametricEq;

/**
 * 创建参数化 EQ（max_bands 夹取 [1, PEQ_MAX_BANDS]）。
 * @return 实例；失败（非法参数 / OOM）返回 NULL
 */
ParametricEq* parametric_eq_create(int sample_rate, int channels, int max_bands);

/**
 * 批量设置活动段（先复位段表与状态，再逐段设置）。
 * @param flat       扁平数组 [kind, freq, q, gain, ...]
 * @param band_count 段数（flat 长度 = band_count * 4）
 */
void parametric_eq_set_bands(ParametricEq *eq, const float *flat, int band_count);

/** 启用/禁用整链（禁用为逐位旁通）。 */
void parametric_eq_set_enabled(ParametricEq *eq, bool enabled);

/** 设置前级增益（dB）。 */
void parametric_eq_set_preamp(ParametricEq *eq, float preamp_db);

/** 就地处理交错 float PCM（samples = 每声道帧数）。 */
void parametric_eq_process(ParametricEq *eq, float *pcm, int samples);

/** 销毁参数化 EQ（NULL 空操作）。 */
void parametric_eq_destroy(ParametricEq *eq);

#endif /* PARAMETRIC_EQ_H */

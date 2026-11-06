// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * chorus_mix.h — 多重奏抽头混音（纯函数，无状态）
 *
 * 从交织历史环按固定帧间距抽取 voices 个延迟抽头求和，预缩放后硬限幅。
 * 只做整数帧延迟，不做插值/重采样；实时线程调用，无分配、无锁。
 * 抽出来单独放头文件，便于 tests/test_chorus_mix.c 直接对拍。
 *
 * 前置条件：
 *   - cap 为 2 的幂（历史环容量，帧）；
 *   - hist 里 base 位置之前**已写入本块输入**（voice 0 延迟为 0）；
 *   - (voices - 1) * step_frames + frames <= cap（最远抽头不越过容量）；
 *   - step_frames >= 1，voices >= 1，ch >= 1。
 */

#ifndef ARCH_OERA_CHORUS_MIX_H
#define ARCH_OERA_CHORUS_MIX_H

#include <stddef.h>

static inline void chorus_mix_taps(const float *hist, size_t cap, size_t base,
                                   unsigned frames, unsigned ch, int voices,
                                   size_t step_frames, float gain, float *dst)
{
    const size_t mask = cap - 1;
    unsigned f, c;
    int v;
    for (f = 0; f < frames; ++f) {
        const size_t b = base + (size_t)f;
        for (c = 0; c < ch; ++c) {
            float sum = 0.0f;
            for (v = 0; v < voices; ++v) {
                sum += hist[((b - (size_t)v * step_frames) & mask) * ch + c];
            }
            sum *= gain;
            if (sum > 1.0f) sum = 1.0f;
            else if (sum < -1.0f) sum = -1.0f;
            dst[(size_t)f * ch + c] = sum;
        }
    }
}

#endif /* ARCH_OERA_CHORUS_MIX_H */

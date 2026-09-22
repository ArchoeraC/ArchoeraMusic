// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * limiter.c — 输出限幅器
 *
 * 使用 soft-knee 压缩防止削波
 *
 * 内核路由（方向① 地基）：HAS_ARCHOERA_KERNEL 时优先 zk_dsp_limiter_*，
 * create 失败回退下方纯 C 实现；对外 API/行为不变。
 */
#include "limiter.h"
#include <stdlib.h>
#include <math.h>

#if defined(HAS_ARCHOERA_KERNEL)
#include "../include/kernel_bridge.h"
#endif

#define LOG_TAG "[audio-engine:limiter]"
#include <stdio.h>

struct Limiter {
    int sample_rate;
    int channels;
    bool enabled;
    float threshold_db;
    float threshold_linear;
#if defined(HAS_ARCHOERA_KERNEL)
    ZkDspLimiter *zk;  /* 非 NULL → 内核实现（优先） */
#endif
};

Limiter* limiter_create(int sample_rate, int channels)
{
    Limiter *lim = calloc(1, sizeof(*lim));
    if (!lim) return NULL;

    lim->sample_rate = sample_rate;
    lim->channels = channels;
    lim->enabled = true;
    lim->threshold_db = -1.0f;  /* 默认 -1dB，留一点余量 */
    lim->threshold_linear = powf(10.0f, lim->threshold_db / 20.0f);

#if defined(HAS_ARCHOERA_KERNEL)
    lim->zk = zk_dsp_limiter_create(sample_rate, channels);
    if (lim->zk) {
        zk_dsp_limiter_set_enabled(lim->zk, 1);
        zk_dsp_limiter_set_threshold(lim->zk, lim->threshold_db);
    }
#endif

    fprintf(stderr, "%s 创建: %dHz / %dch / 阈值 %.1f dB\n",
            LOG_TAG, sample_rate, channels, lim->threshold_db);
    return lim;
}

void limiter_set_enabled(Limiter *lim, bool enabled)
{
    if (!lim) return;
    lim->enabled = enabled;
#if defined(HAS_ARCHOERA_KERNEL)
    if (lim->zk) zk_dsp_limiter_set_enabled(lim->zk, enabled ? 1 : 0);
#endif
}

void limiter_set_threshold(Limiter *lim, float threshold_db)
{
    if (!lim) return;
    lim->threshold_db = threshold_db;
    lim->threshold_linear = powf(10.0f, threshold_db / 20.0f);
#if defined(HAS_ARCHOERA_KERNEL)
    if (lim->zk) zk_dsp_limiter_set_threshold(lim->zk, threshold_db);
#endif
}

void limiter_process(Limiter *lim, float *pcm, int samples)
{
    if (!lim || !pcm || samples <= 0) return;
    if (!lim->enabled) return;

#if defined(HAS_ARCHOERA_KERNEL)
    if (lim->zk) {
        zk_dsp_limiter_process(lim->zk, pcm, samples);
        return;
    }
#endif

    int total = samples * lim->channels;
    float threshold = lim->threshold_linear;

    for (int i = 0; i < total; i++) {
        float x = pcm[i];
        float abs_x = fabsf(x);

        if (abs_x > threshold) {
            /* Soft-knee 压缩：超过阈值的部分按比例压缩 */
            float sign = (x >= 0.0f) ? 1.0f : -1.0f;
            float excess = abs_x - threshold;
            /* 压缩比 4:1 */
            float compressed = threshold + excess * 0.25f;
            /* 限制最大输出为 1.0 */
            if (compressed > 1.0f) compressed = 1.0f;
            pcm[i] = sign * compressed;
        }
    }
}

void limiter_destroy(Limiter *lim)
{
    if (!lim) return;
#if defined(HAS_ARCHOERA_KERNEL)
    if (lim->zk) zk_dsp_limiter_destroy(lim->zk);
#endif
    free(lim);
}

float limiter_get_threshold(const Limiter *lim)
{
    return lim ? lim->threshold_db : -1.0f;
}

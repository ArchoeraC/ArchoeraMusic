// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * channel_merge.c — 多声道合并（单侧设备兜底）
 *
 * 每个采样帧把所有声道等功率（1/√N）求和为单声道，再写回每一个声道。
 * 与内核 `kernel/dsp/channel_merge.zig` 行为一致（含逐位旁通语义）。
 *
 * 内核路由（对齐 lowfreq.c）：HAS_ARCHOERA_KERNEL 时优先经
 * zk_dsp_channel_merge_*，create 失败回退下方纯 C 实现；内核库缺失则纯 C。
 */
#include "channel_merge.h"
#include "era_log.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>

#if defined(HAS_ARCHOERA_KERNEL)
#include "../include/kernel_bridge.h"
#endif

#define LOG_TAG "[audio-engine:channel_merge]"
#include <stdio.h>

struct ChannelMerge {
    int channels;
    bool enabled;
    float gain; /* 等功率合并增益 1/√channels */
#if defined(HAS_ARCHOERA_KERNEL)
    ZkDspChannelMerge *zk; /* 非 NULL → 内核实现（优先） */
#endif
};

static float merge_gain(int channels)
{
    if (channels <= 1) return 1.0f;
    return 1.0f / sqrtf((float)channels);
}

ChannelMerge* channel_merge_create(int channels)
{
    if (channels <= 0 || channels > 64) return NULL;

    ChannelMerge *cm = calloc(1, sizeof(*cm));
    if (!cm) return NULL;

    cm->channels = channels;
    cm->enabled = false;
    cm->gain = merge_gain(channels);

#if defined(HAS_ARCHOERA_KERNEL)
    cm->zk = zk_dsp_channel_merge_create(channels);
    if (cm->zk) {
        ERA_LOGI(NULL, "%s 创建（内核）: %dch gain=%.4f\n",
                 LOG_TAG, channels, cm->gain);
        return cm;
    }
#endif

    ERA_LOGI(NULL, "%s 创建（C）: %dch gain=%.4f\n",
             LOG_TAG, channels, cm->gain);
    return cm;
}

void channel_merge_set_enabled(ChannelMerge *cm, bool enabled)
{
    if (!cm) return;
    cm->enabled = enabled;
#if defined(HAS_ARCHOERA_KERNEL)
    if (cm->zk) zk_dsp_channel_merge_set_enabled(cm->zk, enabled ? 1 : 0);
#endif
}

void channel_merge_process(ChannelMerge *cm, float *pcm, int samples)
{
    if (!cm || !pcm || samples <= 0) return;
    if (!cm->enabled || cm->channels <= 1) return;

#if defined(HAS_ARCHOERA_KERNEL)
    if (cm->zk) {
        zk_dsp_channel_merge_process(cm->zk, pcm, samples);
        return;
    }
#endif

    const int channels = cm->channels;
    const float gain = cm->gain;
    for (int i = 0; i < samples; i++) {
        float *frame = pcm + (size_t)i * (size_t)channels;
        float sum = 0.0f;
        for (int ch = 0; ch < channels; ch++) sum += frame[ch];
        const float mono = sum * gain;
        for (int ch = 0; ch < channels; ch++) frame[ch] = mono;
    }
}

void channel_merge_destroy(ChannelMerge *cm)
{
    if (!cm) return;
#if defined(HAS_ARCHOERA_KERNEL)
    if (cm->zk) zk_dsp_channel_merge_destroy(cm->zk);
#endif
    free(cm);
}

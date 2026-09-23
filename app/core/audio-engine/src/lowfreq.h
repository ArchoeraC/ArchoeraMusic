// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * lowfreq.h — 次声 / 低频管理（方向① D2）
 *
 * 方向① 的低频「打底」链：
 *   - 高通（subsonic HPF，默认 20 Hz，order 1 或 2，Butterworth Q=0.7071）去隆隆声；
 *   - 低架（low-shelf）bass boost（gain_db / freq）。
 *
 * 与内核（Zig）可用时优先路由，失败回退本层纯 C 实现。整块默认禁用 = 逐位旁通。
 */
#ifndef LOWFREQ_H
#define LOWFREQ_H

#include <stdbool.h>

typedef struct LowFreq LowFreq;

/** 创建（失败返回 NULL）。 */
LowFreq* lowfreq_create(int sample_rate, int channels);

/** 整块启用/禁用（默认禁用 = 逐位旁通）。 */
void lowfreq_set_enabled(LowFreq *lf, bool enabled);

/** 设置 HPF：freq<=0 / 非有限 → 关闭；order 夹取到 1/2。 */
void lowfreq_set_hpf(LowFreq *lf, float freq, int order);

/** 设置 bass shelf（gain_db=0 自然旁通）。 */
void lowfreq_set_bass(LowFreq *lf, float gain_db, float freq);

/** 就地处理交错 float PCM（samples = 每声道帧数）。 */
void lowfreq_process(LowFreq *lf, float *pcm, int samples);

/** 销毁（NULL 空操作）。 */
void lowfreq_destroy(LowFreq *lf);

#endif /* LOWFREQ_H */

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * lowfreq.c — 次声 / 低频管理（方向① D2）
 *
 * 高通（一阶/二阶，Butterworth Q=0.7071）+ 低架 bass shelf；系数公式与内核
 * `kernel/dsp/biquad.zig` 同式（`w0` 以 double 计算后落回 float）。
 *
 * 内核路由（对齐 equalizer.c）：HAS_ARCHOERA_KERNEL 时优先经
 * zk_dsp_lowfreq_*，create 失败回退下方纯 C 实现；内核库缺失则纯 C。
 */
#include "lowfreq.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#if defined(HAS_ARCHOERA_KERNEL)
#include "../include/kernel_bridge.h"
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define LOG_TAG "[audio-engine:lowfreq]"
#include <stdio.h>

/* Butterworth 品质因数（阶数 2 高通 / 低架斜率 S=1） */
#define LOWFREQ_BUTTER_Q 0.7071f
#define LOWFREQ_DEFAULT_HPF_FREQ 20.0f
#define LOWFREQ_DEFAULT_BASS_FREQ 100.0f

typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} LowBiquad;

struct LowFreq {
    int sample_rate;
    int channels;
    bool enabled;
    bool hpf_enabled;
    float hpf_freq;
    int hpf_order;
    float bass_gain_db;
    float bass_freq;
    LowBiquad *hpf1; /* 一阶高通每声道；内核路径下为 NULL */
    LowBiquad *hpf2; /* 二阶高通每声道 */
    LowBiquad *bass; /* bass shelf 每声道 */
#if defined(HAS_ARCHOERA_KERNEL)
    ZkDspLowFreq *zk; /* 非 NULL → 内核实现（优先） */
#endif
};

static float low_clamp_freq(float freq, int sample_rate)
{
    float sr = (float)sample_rate;
    float hi = sr * 0.5f * 0.999f;
    if (!(freq > 0.0f)) return 1.0f; /* 含 NaN */
    if (freq < 1.0f) return 1.0f;
    if (freq > hi) return hi;
    return freq;
}

static float low_sanitize_gain(float gain_db)
{
    if (!isfinite(gain_db)) return 0.0f;
    return gain_db;
}

static void low_calc_hpf2(LowBiquad *f, float freq, float q, int sr)
{
    float w0 = (float)(2.0 * M_PI * freq / sr);
    float alpha = sinf(w0) / (2.0f * q);
    float cos_w0 = cosf(w0);

    float b0 = (1.0f + cos_w0) / 2.0f;
    float b1 = -(1.0f + cos_w0);
    float b2 = (1.0f + cos_w0) / 2.0f;
    float a0 = 1.0f + alpha;
    float a1 = -2.0f * cos_w0;
    float a2 = 1.0f - alpha;

    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = a1 / a0;
    f->a2 = a2 / a0;
}

static void low_calc_hpf1(LowBiquad *f, float freq, int sr)
{
    float w0 = (float)(2.0 * M_PI * freq / sr);
    float half = w0 / 2.0f;
    float k = sinf(half) / cosf(half);
    float norm = 1.0f / (1.0f + k);

    f->b0 = norm;
    f->b1 = -norm;
    f->b2 = 0.0f;
    f->a1 = (k - 1.0f) * norm;
    f->a2 = 0.0f;
}

static void low_calc_bass(LowBiquad *f, float freq, float q, float gain_db, int sr)
{
    float A = powf(10.0f, gain_db / 40.0f);
    float w0 = (float)(2.0 * M_PI * freq / sr);
    float alpha = sinf(w0) / (2.0f * q);
    float cos_w0 = cosf(w0);
    float sqrtA = sqrtf(A);
    float tsa = 2.0f * sqrtA * alpha;
    float ap1 = A + 1.0f;
    float am1 = A - 1.0f;

    float b0 = A * (ap1 - am1 * cos_w0 + tsa);
    float b1 = 2.0f * A * (am1 - ap1 * cos_w0);
    float b2 = A * (ap1 - am1 * cos_w0 - tsa);
    float a0 = ap1 + am1 * cos_w0 + tsa;
    float a1 = -2.0f * (am1 + ap1 * cos_w0);
    float a2 = ap1 + am1 * cos_w0 - tsa;

    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = a1 / a0;
    f->a2 = a2 / a0;
}

static void low_reset_biquad(LowBiquad *f)
{
    f->x1 = f->x2 = f->y1 = f->y2 = 0.0f;
}

LowFreq* lowfreq_create(int sample_rate, int channels)
{
    if (sample_rate <= 0 || channels <= 0) return NULL;

    LowFreq *lf = calloc(1, sizeof(*lf));
    if (!lf) return NULL;

    lf->sample_rate = sample_rate;
    lf->channels = channels;
    lf->enabled = false;
    lf->hpf_enabled = false;
    lf->hpf_freq = LOWFREQ_DEFAULT_HPF_FREQ;
    lf->hpf_order = 2;
    lf->bass_gain_db = 0.0f;
    lf->bass_freq = LOWFREQ_DEFAULT_BASS_FREQ;

#if defined(HAS_ARCHOERA_KERNEL)
    lf->zk = zk_dsp_lowfreq_create(sample_rate, channels);
    if (!lf->zk) {
        lf->hpf1 = calloc((size_t)channels, sizeof(LowBiquad));
        lf->hpf2 = calloc((size_t)channels, sizeof(LowBiquad));
        lf->bass = calloc((size_t)channels, sizeof(LowBiquad));
        if (!lf->hpf1 || !lf->hpf2 || !lf->bass) {
            free(lf->hpf1); free(lf->hpf2); free(lf->bass);
            free(lf);
            return NULL;
        }
    }
#else
    lf->hpf1 = calloc((size_t)channels, sizeof(LowBiquad));
    lf->hpf2 = calloc((size_t)channels, sizeof(LowBiquad));
    lf->bass = calloc((size_t)channels, sizeof(LowBiquad));
    if (!lf->hpf1 || !lf->hpf2 || !lf->bass) {
        free(lf->hpf1); free(lf->hpf2); free(lf->bass);
        free(lf);
        return NULL;
    }
#endif

    fprintf(stderr, "%s 创建: %dHz / %dch\n", LOG_TAG, sample_rate, channels);
    return lf;
}

void lowfreq_set_enabled(LowFreq *lf, bool enabled)
{
    if (!lf) return;
    lf->enabled = enabled;
#if defined(HAS_ARCHOERA_KERNEL)
    if (lf->zk) {
        zk_dsp_lowfreq_set_enabled(lf->zk, enabled ? 1 : 0);
        return;
    }
#endif
}

void lowfreq_set_hpf(LowFreq *lf, float freq, int order)
{
    if (!lf) return;
    if (!(freq > 0.0f) || !isfinite(freq)) {
        lf->hpf_enabled = false;
#if defined(HAS_ARCHOERA_KERNEL)
        if (lf->zk) zk_dsp_lowfreq_set_hpf(lf->zk, freq, order);
#endif
        return;
    }
    lf->hpf_enabled = true;
    lf->hpf_order = (order <= 1) ? 1 : 2;
    lf->hpf_freq = low_clamp_freq(freq, lf->sample_rate);

#if defined(HAS_ARCHOERA_KERNEL)
    if (lf->zk) {
        zk_dsp_lowfreq_set_hpf(lf->zk, freq, order);
        return;
    }
#endif

    for (int ch = 0; ch < lf->channels; ch++) {
        if (lf->hpf_order == 1) {
            low_calc_hpf1(&lf->hpf1[ch], lf->hpf_freq, lf->sample_rate);
            low_reset_biquad(&lf->hpf1[ch]);
        } else {
            low_calc_hpf2(&lf->hpf2[ch], lf->hpf_freq, LOWFREQ_BUTTER_Q, lf->sample_rate);
            low_reset_biquad(&lf->hpf2[ch]);
        }
    }
}

void lowfreq_set_bass(LowFreq *lf, float gain_db, float freq)
{
    if (!lf) return;
    lf->bass_gain_db = low_sanitize_gain(gain_db);
    lf->bass_freq = low_clamp_freq(freq, lf->sample_rate);

#if defined(HAS_ARCHOERA_KERNEL)
    if (lf->zk) {
        zk_dsp_lowfreq_set_bass(lf->zk, gain_db, freq);
        return;
    }
#endif

    for (int ch = 0; ch < lf->channels; ch++) {
        low_calc_bass(&lf->bass[ch], lf->bass_freq, LOWFREQ_BUTTER_Q,
                      lf->bass_gain_db, lf->sample_rate);
    }
}

void lowfreq_process(LowFreq *lf, float *pcm, int samples)
{
    if (!lf || !pcm || samples <= 0) return;

#if defined(HAS_ARCHOERA_KERNEL)
    if (lf->zk) {
        zk_dsp_lowfreq_process(lf->zk, pcm, samples);
        return;
    }
#endif

    if (!lf->enabled) return;
    bool hpf_active = lf->hpf_enabled;
    bool bass_active = lf->bass_gain_db != 0.0f;
    if (!hpf_active && !bass_active) return;

    for (int ch = 0; ch < lf->channels; ch++) {
        LowBiquad *hf = (lf->hpf_order == 1) ? &lf->hpf1[ch] : &lf->hpf2[ch];
        LowBiquad *bf = &lf->bass[ch];
        for (int i = 0; i < samples; i++) {
            float x = pcm[i * lf->channels + ch];
            if (hpf_active) {
                float y = hf->b0 * x + hf->b1 * hf->x1 + hf->b2 * hf->x2
                        - hf->a1 * hf->y1 - hf->a2 * hf->y2;
                hf->x2 = hf->x1; hf->x1 = x;
                hf->y2 = hf->y1; hf->y1 = y;
                x = y;
            }
            if (bass_active) {
                float y = bf->b0 * x + bf->b1 * bf->x1 + bf->b2 * bf->x2
                        - bf->a1 * bf->y1 - bf->a2 * bf->y2;
                bf->x2 = bf->x1; bf->x1 = x;
                bf->y2 = bf->y1; bf->y1 = y;
                x = y;
            }
            pcm[i * lf->channels + ch] = x;
        }
    }
}

void lowfreq_destroy(LowFreq *lf)
{
    if (!lf) return;
#if defined(HAS_ARCHOERA_KERNEL)
    if (lf->zk) zk_dsp_lowfreq_destroy(lf->zk);
#endif
    if (lf->hpf1) free(lf->hpf1);
    if (lf->hpf2) free(lf->hpf2);
    if (lf->bass) free(lf->bass);
    free(lf);
}

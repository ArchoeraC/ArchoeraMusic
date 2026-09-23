// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * parametric_eq.c — 参数化均衡器（方向① D1）
 *
 * 每段 {kind, freq, Q, gain_db}（peak / low-shelf / high-shelf），Direct Form I
 * Biquad 串联；系数公式与内核 `kernel/dsp/biquad.zig` 同式（Audio EQ Cookbook），
 * `w0` 同样以 double 计算后落回 float，保证与内核实现逐块可对照。
 *
 * 内核路由（对齐 equalizer.c）：HAS_ARCHOERA_KERNEL 时优先经 zk_dsp_peq_*，
 * create 失败回退下方纯 C 实现；内核库缺失则纯 C。
 */
#include "parametric_eq.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#if defined(HAS_ARCHOERA_KERNEL)
#include "../include/kernel_bridge.h"
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define LOG_TAG "[audio-engine:parametric_eq]"
#include <stdio.h>

/* 段参数安全范围（与 kernel/dsp/parametric.zig 一致） */
#define PEQ_MIN_FREQ 1.0f
#define PEQ_MIN_Q 0.1f
#define PEQ_MAX_Q 40.0f
#define PEQ_DEFAULT_Q 0.7071f

/* Direct Form I Biquad（系数 + 4 状态） */
typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} PeqBiquad;

typedef struct {
    int kind;
    float freq;
    float q;
    float gain_db;
    bool enabled;
} PeqBand;

struct ParametricEq {
    int sample_rate;
    int channels;
    int max_bands;
    int band_count;
    PeqBand bands[PEQ_MAX_BANDS];
    float preamp_db;
    bool enabled;
    bool passthrough;
    PeqBiquad *filters; /* [max_bands * channels]；内核路径下为 NULL */
#if defined(HAS_ARCHOERA_KERNEL)
    ZkDspPeq *zk;       /* 非 NULL → 内核实现（优先） */
#endif
};

/* ── 系数计算（与 kernel/dsp/biquad.zig 同式）──────────────────────── */

static void peq_calc_peaking(PeqBiquad *f, float freq, float q, float gain_db, int sr)
{
    float A = powf(10.0f, gain_db / 40.0f);
    float w0 = (float)(2.0 * M_PI * freq / sr);
    float alpha = sinf(w0) / (2.0f * q);
    float cos_w0 = cosf(w0);

    float b0 = 1.0f + alpha * A;
    float b1 = -2.0f * cos_w0;
    float b2 = 1.0f - alpha * A;
    float a0 = 1.0f + alpha / A;
    float a1 = -2.0f * cos_w0;
    float a2 = 1.0f - alpha / A;

    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = a1 / a0;
    f->a2 = a2 / a0;
}

static void peq_calc_low_shelf(PeqBiquad *f, float freq, float q, float gain_db, int sr)
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

static void peq_calc_high_shelf(PeqBiquad *f, float freq, float q, float gain_db, int sr)
{
    float A = powf(10.0f, gain_db / 40.0f);
    float w0 = (float)(2.0 * M_PI * freq / sr);
    float alpha = sinf(w0) / (2.0f * q);
    float cos_w0 = cosf(w0);
    float sqrtA = sqrtf(A);
    float tsa = 2.0f * sqrtA * alpha;
    float ap1 = A + 1.0f;
    float am1 = A - 1.0f;

    float b0 = A * (ap1 + am1 * cos_w0 + tsa);
    float b1 = -2.0f * A * (am1 + ap1 * cos_w0);
    float b2 = A * (ap1 + am1 * cos_w0 - tsa);
    float a0 = ap1 - am1 * cos_w0 + tsa;
    float a1 = 2.0f * (am1 - ap1 * cos_w0);
    float a2 = ap1 - am1 * cos_w0 - tsa;

    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = a1 / a0;
    f->a2 = a2 / a0;
}

/* ── 参数夹取（NaN 防护；与 Zig 一致）───────────────────────────── */

static float peq_clamp_freq(float freq, int sample_rate)
{
    float sr = (float)sample_rate;
    float hi = sr * 0.5f * 0.999f;
    if (!(freq > 0.0f)) return PEQ_MIN_FREQ; /* 含 NaN */
    if (freq < PEQ_MIN_FREQ) return PEQ_MIN_FREQ;
    if (freq > hi) return hi;
    return freq;
}

static float peq_clamp_q(float q)
{
    if (!(q >= PEQ_MIN_Q)) return PEQ_DEFAULT_Q; /* 含 NaN */
    if (q > PEQ_MAX_Q) return PEQ_MAX_Q;
    return q;
}

static float peq_sanitize_gain(float gain_db)
{
    if (!isfinite(gain_db)) return 0.0f;
    return gain_db;
}

static void peq_recompute_passthrough(ParametricEq *eq)
{
    bool zero = true;
    for (int i = 0; i < eq->band_count; i++) {
        if (eq->bands[i].enabled && eq->bands[i].gain_db != 0.0f) { zero = false; break; }
    }
    eq->passthrough = zero && eq->preamp_db == 0.0f;
}

/* 计算某段全部声道系数（不改变历史状态） */
static void peq_recompute_band(ParametricEq *eq, int index)
{
    PeqBand *b = &eq->bands[index];
    for (int ch = 0; ch < eq->channels; ch++) {
        PeqBiquad *f = &eq->filters[index * eq->channels + ch];
        switch (b->kind) {
        case PEQ_KIND_LOW_SHELF:
            peq_calc_low_shelf(f, b->freq, b->q, b->gain_db, eq->sample_rate);
            break;
        case PEQ_KIND_HIGH_SHELF:
            peq_calc_high_shelf(f, b->freq, b->q, b->gain_db, eq->sample_rate);
            break;
        case PEQ_KIND_PEAK:
        default:
            peq_calc_peaking(f, b->freq, b->q, b->gain_db, eq->sample_rate);
            break;
        }
    }
}

ParametricEq* parametric_eq_create(int sample_rate, int channels, int max_bands)
{
    if (sample_rate <= 0 || channels <= 0) return NULL;
    if (max_bands < 1) max_bands = 1;
    if (max_bands > PEQ_MAX_BANDS) max_bands = PEQ_MAX_BANDS;

    ParametricEq *eq = calloc(1, sizeof(*eq));
    if (!eq) return NULL;

    eq->sample_rate = sample_rate;
    eq->channels = channels;
    eq->max_bands = max_bands;
    eq->band_count = 0;
    eq->preamp_db = 0.0f;
    eq->enabled = true;
    eq->passthrough = true;
    for (int i = 0; i < PEQ_MAX_BANDS; i++) {
        eq->bands[i].kind = PEQ_KIND_PEAK;
        eq->bands[i].freq = 1000.0f;
        eq->bands[i].q = PEQ_DEFAULT_Q;
        eq->bands[i].gain_db = 0.0f;
        eq->bands[i].enabled = false;
    }

#if defined(HAS_ARCHOERA_KERNEL)
    eq->zk = zk_dsp_peq_create(sample_rate, channels, max_bands);
    if (!eq->zk) {
        eq->filters = calloc((size_t)max_bands * channels, sizeof(PeqBiquad));
        if (!eq->filters) { free(eq); return NULL; }
    }
#else
    eq->filters = calloc((size_t)max_bands * channels, sizeof(PeqBiquad));
    if (!eq->filters) { free(eq); return NULL; }
#endif

    fprintf(stderr, "%s 创建: %dHz / %dch / 最多 %d 段\n",
            LOG_TAG, sample_rate, channels, max_bands);
    return eq;
}

void parametric_eq_set_bands(ParametricEq *eq, const float *flat, int band_count)
{
    if (!eq || !flat || band_count <= 0) return;
    if (band_count > eq->max_bands) band_count = eq->max_bands;
    eq->band_count = band_count;

#if defined(HAS_ARCHOERA_KERNEL)
    if (eq->zk) {
        zk_dsp_peq_clear(eq->zk);
        for (int i = 0; i < band_count; i++) {
            zk_dsp_peq_set_band(eq->zk, i,
                                (int)flat[i * 4 + 0],
                                flat[i * 4 + 1],
                                flat[i * 4 + 2],
                                flat[i * 4 + 3]);
        }
        return;
    }
#endif

    /* 复位段表与状态（与内核 clear 对齐） */
    for (int j = 0; j < eq->max_bands * eq->channels; j++) {
        eq->filters[j].x1 = eq->filters[j].x2 = 0.0f;
        eq->filters[j].y1 = eq->filters[j].y2 = 0.0f;
    }

    for (int i = 0; i < band_count; i++) {
        int kind = (int)flat[i * 4 + 0];
        PeqBand *b = &eq->bands[i];
        if (kind != PEQ_KIND_PEAK && kind != PEQ_KIND_LOW_SHELF &&
            kind != PEQ_KIND_HIGH_SHELF) {
            b->enabled = false;
            continue;
        }
        b->kind = kind;
        b->freq = peq_clamp_freq(flat[i * 4 + 1], eq->sample_rate);
        b->q = peq_clamp_q(flat[i * 4 + 2]);
        b->gain_db = peq_sanitize_gain(flat[i * 4 + 3]);
        b->enabled = true;
        peq_recompute_band(eq, i);
    }
    peq_recompute_passthrough(eq);
}

void parametric_eq_set_enabled(ParametricEq *eq, bool enabled)
{
    if (!eq) return;
    eq->enabled = enabled;
#if defined(HAS_ARCHOERA_KERNEL)
    if (eq->zk) {
        zk_dsp_peq_set_enabled(eq->zk, enabled ? 1 : 0);
        return;
    }
#endif
}

void parametric_eq_set_preamp(ParametricEq *eq, float preamp_db)
{
    if (!eq) return;
    eq->preamp_db = peq_sanitize_gain(preamp_db);
#if defined(HAS_ARCHOERA_KERNEL)
    if (eq->zk) {
        zk_dsp_peq_set_preamp(eq->zk, preamp_db);
        return;
    }
#endif
    peq_recompute_passthrough(eq);
}

void parametric_eq_process(ParametricEq *eq, float *pcm, int samples)
{
    if (!eq || !pcm || samples <= 0) return;

#if defined(HAS_ARCHOERA_KERNEL)
    if (eq->zk) {
        zk_dsp_peq_process(eq->zk, pcm, samples);
        return;
    }
#endif

    if (!eq->enabled || eq->passthrough) return;

    float preamp = powf(10.0f, eq->preamp_db / 20.0f);

    for (int band = 0; band < eq->band_count; band++) {
        PeqBand *b = &eq->bands[band];
        if (!b->enabled || b->gain_db == 0.0f) continue;

        for (int ch = 0; ch < eq->channels; ch++) {
            PeqBiquad *f = &eq->filters[band * eq->channels + ch];
            for (int i = 0; i < samples; i++) {
                float x = pcm[i * eq->channels + ch];
                float y = f->b0 * x + f->b1 * f->x1 + f->b2 * f->x2
                        - f->a1 * f->y1 - f->a2 * f->y2;
                f->x2 = f->x1;
                f->x1 = x;
                f->y2 = f->y1;
                f->y1 = y;
                pcm[i * eq->channels + ch] = y;
            }
        }
    }

    if (preamp != 1.0f) {
        int total = samples * eq->channels;
        for (int i = 0; i < total; i++) pcm[i] *= preamp;
    }
}

void parametric_eq_destroy(ParametricEq *eq)
{
    if (!eq) return;
#if defined(HAS_ARCHOERA_KERNEL)
    if (eq->zk) zk_dsp_peq_destroy(eq->zk);
#endif
    if (eq->filters) free(eq->filters);
    free(eq);
}

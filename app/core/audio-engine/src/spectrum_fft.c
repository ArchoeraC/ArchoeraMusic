// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_fft.c — 纯 FFmpeg 频谱后端（libavutil/tx 多分辨率 FFT）
 *
 * 设计目标：不链接 Zig 内核时仍提供与 v2 事件契约一致的 128 对数带频谱。
 * 算法与 `kernel/dsp/spectrum.zig` 的分工：
 *   - 本文件用 FFmpeg 的 RDFT（`av_tx_init` / `AV_TX_FLOAT_RDFT`）做分析，
 *     4 种窗长按频带宽度自动选择（低频长窗、高频短窗）；
 *   - 显示增强（AGC / 高频倾斜 / 显示量程 / dB + 软膝 / γ / 峰值保持 /
 *     对数谱通量节拍）逐条镜像 Zig 实现，保证前端看到同一口径。
 *
 * 已知差异（文档 docs/spectrum-analyzer.md §4.10 记录）：
 *   - VQT 是每带独立复解调；这里是 FFT + 频带取最大 bin，低频选择性弱于
 *     VQT（40–80Hz 受最长窗 12288 限制，约 3.9Hz/bin @48k）；
 *   - 带内取 max 而非功率和，保持 0dBFS 正弦 ≈ 1.0 的校准口径。
 */
#define _DEFAULT_SOURCE
#include "spectrum_fft.h"

#include <libavutil/mem.h>
#include <libavutil/tx.h>

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* MSVC 默认不定义 M_PI（必须显式 _USE_MATH_DEFINES 或用自有常量）。 */
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* 与 kernel/dsp/spectrum.zig 对齐的显示常量。 */
#define ERA_FFT_DB_FLOOR (-60.0f)
#define ERA_FFT_DB_CEILING (0.0f)
#define ERA_FFT_DISPLAY_GAIN 0.28f
#define ERA_FFT_SOFT_KNEE 0.06f
#define ERA_FFT_FLUX_LEN 43
#define ERA_FFT_BEAT_COOLDOWN 2
#define ERA_FFT_FRAME_INTERVAL_S 0.05f
#define ERA_FFT_PEAK_DECAY_PER_S 2.0f
#define ERA_FFT_AGC_TARGET_DB (-24.0f)
#define ERA_FFT_AGC_ATTACK_S 3.0f
#define ERA_FFT_AGC_RELEASE_S 3.0f
#define ERA_FFT_AGC_MIN 0.25f
#define ERA_FFT_AGC_MAX 4.0f

/* 窗长阶梯（升序）：按「bin 宽度 ≤ 频带宽度」选满足条件的最小窗。 */
#define ERA_FFT_STAGES 4
static const int era_fft_stage_sizes[ERA_FFT_STAGES] = {256, 1024, 4096, 12288};

typedef struct EraFftStage {
    int n;
    AVTXContext *tx;
    av_tx_fn run;
    float *window; /* n：Blackman 周期窗 */
    float *input;  /* n：乘窗输入 */
    float *out;    /* n + 2：RDFT 打包输出 */
    float win_sum;
} EraFftStage;

struct EraFftSpectrum {
    int sample_rate;
    int bins;
    float min_hz;
    float max_hz;

    /* 频带表（create 时一次建好）。 */
    float *edges;      /* bins + 1 */
    int *band_stage;   /* 每个带使用的窗长档位 */
    int *band_klo;     /* 带内起始 bin（含） */
    int *band_khi;     /* 带内结束 bin（含） */
    float *band_freq;  /* 带中心频率 */
    float *tilt_gain;  /* 高频倾斜线性增益 */

    EraFftStage stages[ERA_FFT_STAGES];

    /* 每帧缓冲（零分配）。 */
    float *prev_mag;
    float *band_l;
    float *band_r;
    float *peak_l;
    float *peak_r;

    /* 帧间状态。 */
    float agc_gain;
    int has_prev;
    float flux_hist[ERA_FFT_FLUX_LEN];
    int flux_pos;
    int flux_count;
    int cooldown;

    bool agc_enabled;
    bool peak_hold;
    float gamma;
    float tilt_db_per_oct;
};

/* ── 建表 ─────────────────────────────────────────────────────────── */

static float era_fft_tilt_gain(float db_per_oct, float freq)
{
    const double tilt_db = (double)db_per_oct * log2((double)freq / 1000.0);
    return (float)pow(10.0, tilt_db / 20.0);
}

static void era_fft_stage_free(EraFftStage *st)
{
    if (st->tx) {
        av_tx_uninit(&st->tx);
        st->tx = NULL;
    }
    av_free(st->window);
    av_free(st->input);
    av_free(st->out);
    st->window = NULL;
    st->input = NULL;
    st->out = NULL;
    st->n = 0;
    st->run = NULL;
    st->win_sum = 0.0f;
}

static int era_fft_stage_init(EraFftStage *st, int n)
{
    double wsum = 0.0;

    memset(st, 0, sizeof(*st));
    st->n = n;
    /* av_tx 要求 in/out 按 CPU SIMD 最大宽度对齐（malloc 只保证 16B）。 */
    st->window = (float *)av_malloc((size_t)n * sizeof(float));
    st->input = (float *)av_malloc((size_t)n * sizeof(float));
    st->out = (float *)av_malloc(((size_t)n + 2) * sizeof(float));
    if (!st->window || !st->input || !st->out) {
        era_fft_stage_free(st);
        return -1;
    }

    for (int i = 0; i < n; i++) {
        const double t = 2.0 * M_PI * (double)i / (double)n;
        const double w = 0.42 - 0.5 * cos(t) + 0.08 * cos(2.0 * t);
        st->window[i] = (float)w;
        wsum += w;
    }
    if (wsum <= 0.0) {
        era_fft_stage_free(st);
        return -1;
    }
    st->win_sum = (float)wsum;

    if (av_tx_init(&st->tx, &st->run, AV_TX_FLOAT_RDFT, 0, n, NULL, 0) < 0) {
        st->tx = NULL;
        era_fft_stage_free(st);
        return -1;
    }
    return 0;
}

EraFftSpectrum *era_fft_spectrum_create(int sample_rate, int bins,
                                        float min_hz, float max_hz)
{
    EraFftSpectrum *s;
    double log_ratio;

    if (sample_rate <= 0 || bins <= 0 || bins > 1024) return NULL;
    if (!(min_hz > 0.0f) || !(max_hz > min_hz)) return NULL;
    if ((double)max_hz >= (double)sample_rate * 0.5) return NULL;

    s = (EraFftSpectrum *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->sample_rate = sample_rate;
    s->bins = bins;
    s->min_hz = min_hz;
    s->max_hz = max_hz;
    s->agc_gain = 1.0f;
    s->gamma = 1.0f;

    for (int i = 0; i < ERA_FFT_STAGES; i++) {
        if (era_fft_stage_init(&s->stages[i], era_fft_stage_sizes[i]) != 0) {
            era_fft_spectrum_destroy(s);
            return NULL;
        }
    }

    s->edges = (float *)malloc(((size_t)bins + 1) * sizeof(float));
    s->band_stage = (int *)calloc((size_t)bins, sizeof(int));
    s->band_klo = (int *)calloc((size_t)bins, sizeof(int));
    s->band_khi = (int *)calloc((size_t)bins, sizeof(int));
    s->band_freq = (float *)calloc((size_t)bins, sizeof(float));
    s->tilt_gain = (float *)malloc((size_t)bins * sizeof(float));
    s->prev_mag = (float *)calloc((size_t)bins, sizeof(float));
    s->band_l = (float *)calloc((size_t)bins, sizeof(float));
    s->band_r = (float *)calloc((size_t)bins, sizeof(float));
    s->peak_l = (float *)calloc((size_t)bins, sizeof(float));
    s->peak_r = (float *)calloc((size_t)bins, sizeof(float));
    if (!s->edges || !s->band_stage || !s->band_klo || !s->band_khi ||
        !s->band_freq || !s->tilt_gain || !s->prev_mag || !s->band_l ||
        !s->band_r || !s->peak_l || !s->peak_r) {
        era_fft_spectrum_destroy(s);
        return NULL;
    }

    /* 对数带边界：f_i = min·(max/min)^(i/bins)。 */
    log_ratio = log((double)max_hz / (double)min_hz);
    for (int i = 0; i <= bins; i++) {
        const double frac = (double)i / (double)bins;
        s->edges[i] = (float)((double)min_hz * exp(log_ratio * frac));
    }

    for (int i = 0; i < bins; i++) {
        const double f_lo = s->edges[i];
        const double f_hi = s->edges[i + 1];
        const double width = f_hi - f_lo;
        double need = (double)sample_rate / (width > 1e-9 ? width : 1e-9);
        int si = ERA_FFT_STAGES - 1; /* 默认最长窗 */
        int n, klo, khi;

        /* 升序阶梯：取第一个「bin 宽度 ≤ 频带宽度」的窗长。 */
        for (int k = 0; k < ERA_FFT_STAGES; k++) {
            if ((double)era_fft_stage_sizes[k] >= need) {
                si = k;
                break;
            }
        }
        s->band_stage[i] = si;
        s->band_freq[i] = (float)sqrt(f_lo * f_hi);
        n = era_fft_stage_sizes[si];
        klo = (int)ceil(f_lo * (double)n / (double)sample_rate);
        khi = (int)floor(f_hi * (double)n / (double)sample_rate);
        if (klo < 1) klo = 1;
        if (khi > n / 2 - 1) khi = n / 2 - 1;
        if (khi < klo) {
            klo = khi = (int)lround((double)s->band_freq[i] *
                                    (double)n / (double)sample_rate);
            if (klo < 1) klo = 1;
            if (khi > n / 2 - 1) khi = n / 2 - 1;
            if (khi < klo) klo = khi;
        }
        s->band_klo[i] = klo;
        s->band_khi[i] = khi;
        s->tilt_gain[i] = era_fft_tilt_gain(s->tilt_db_per_oct, s->band_freq[i]);
    }
    return s;
}

void era_fft_spectrum_destroy(EraFftSpectrum *s)
{
    if (!s) return;
    for (int i = 0; i < ERA_FFT_STAGES; i++) {
        era_fft_stage_free(&s->stages[i]);
    }
    free(s->edges);
    free(s->band_stage);
    free(s->band_klo);
    free(s->band_khi);
    free(s->band_freq);
    free(s->tilt_gain);
    free(s->prev_mag);
    free(s->band_l);
    free(s->band_r);
    free(s->peak_l);
    free(s->peak_r);
    free(s);
}

void era_fft_spectrum_reset(EraFftSpectrum *s)
{
    if (!s) return;
    memset(s->prev_mag, 0, (size_t)s->bins * sizeof(float));
    memset(s->peak_l, 0, (size_t)s->bins * sizeof(float));
    memset(s->peak_r, 0, (size_t)s->bins * sizeof(float));
    memset(s->flux_hist, 0, sizeof(s->flux_hist));
    s->agc_gain = 1.0f;
    s->flux_pos = 0;
    s->flux_count = 0;
    s->cooldown = 0;
    s->has_prev = 0;
}

/* ── 运行时参数 ───────────────────────────────────────────────────── */

void era_fft_spectrum_set_peak_hold(EraFftSpectrum *s, bool enabled)
{
    if (!s) return;
    s->peak_hold = enabled;
    if (!enabled) {
        memset(s->peak_l, 0, (size_t)s->bins * sizeof(float));
        memset(s->peak_r, 0, (size_t)s->bins * sizeof(float));
    }
}

void era_fft_spectrum_set_agc(EraFftSpectrum *s, bool enabled)
{
    if (!s) return;
    s->agc_enabled = enabled;
    if (!enabled) s->agc_gain = 1.0f;
}

void era_fft_spectrum_set_gamma(EraFftSpectrum *s, float gamma)
{
    if (!s || !isfinite(gamma) || gamma <= 0.0f) return;
    s->gamma = gamma < 0.25f ? 0.25f : (gamma > 4.0f ? 4.0f : gamma);
}

void era_fft_spectrum_set_tilt(EraFftSpectrum *s, float db_per_oct)
{
    if (!s || !isfinite(db_per_oct)) return;
    s->tilt_db_per_oct = db_per_oct < -24.0f ? -24.0f
                         : (db_per_oct > 24.0f ? 24.0f : db_per_oct);
    for (int i = 0; i < s->bins; i++) {
        s->tilt_gain[i] = era_fft_tilt_gain(s->tilt_db_per_oct, s->band_freq[i]);
    }
}

/* ── 分析 ─────────────────────────────────────────────────────────── */

/* 填一段乘窗输入：窗口中心对准「当前位置」（src[frames-1] 对应 pos+future）。 */
static void era_fft_fill(EraFftStage *st, const float *src, int frames,
                         int future)
{
    const int n = st->n;
    const int center = frames - future;
    const int start = center - n / 2;

    for (int i = 0; i < n; i++) {
        const int idx = start + i;
        const float v = (idx >= 0 && idx < frames) ? src[idx] : 0.0f;
        st->input[i] = v * st->window[i];
    }
}

/* 单带幅度：带内 bin 取最大（保持 0dBFS 正弦 → 1.0 的校准口径）。 */
static float era_fft_band_mag(const EraFftStage *st, int klo, int khi)
{
    float best = 0.0f;
    for (int k = klo; k <= khi; k++) {
        const float re = st->out[2 * k];
        const float im = st->out[2 * k + 1];
        const float m = 2.0f * sqrtf(re * re + im * im) / st->win_sum;
        if (m > best) best = m;
    }
    if (!(best >= 0.0f)) best = 0.0f;
    if (best > 1.0f) best = 1.0f;
    return best;
}

static float era_fft_map_db(float amp)
{
    const float db = 20.0f * log10f(amp + 1e-12f);
    float t = (db - ERA_FFT_DB_FLOOR) / (ERA_FFT_DB_CEILING - ERA_FFT_DB_FLOOR);
    float gate;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    gate = t / ERA_FFT_SOFT_KNEE;
    if (gate > 1.0f) gate = 1.0f;
    return t * gate * gate * (3.0f - 2.0f * gate);
}

/* 慢 AGC：按带幅度 RMS 估电平，目标 -24dB，攻/放 3s，增益限 [0.25, 4.0]。 */
static float era_fft_agc_step(EraFftSpectrum *s)
{
    float sum = 0.0f;
    float level, desired, tau, coef;

    if (!s->agc_enabled) return 1.0f;
    for (int i = 0; i < s->bins; i++) {
        const float m = 0.5f * (s->band_l[i] + s->band_r[i]);
        sum += m * m;
    }
    level = sqrtf(sum / (float)s->bins);
    desired = 1.0f;
    if (level > 1e-6f) {
        const float target = powf(10.0f, ERA_FFT_AGC_TARGET_DB / 20.0f);
        desired = target / level;
        if (desired < ERA_FFT_AGC_MIN) desired = ERA_FFT_AGC_MIN;
        if (desired > ERA_FFT_AGC_MAX) desired = ERA_FFT_AGC_MAX;
    }
    tau = desired > s->agc_gain ? ERA_FFT_AGC_ATTACK_S : ERA_FFT_AGC_RELEASE_S;
    coef = 1.0f - expf(-ERA_FFT_FRAME_INTERVAL_S / tau);
    s->agc_gain += (desired - s->agc_gain) * coef;
    if (s->agc_gain < ERA_FFT_AGC_MIN) s->agc_gain = ERA_FFT_AGC_MIN;
    if (s->agc_gain > ERA_FFT_AGC_MAX) s->agc_gain = ERA_FFT_AGC_MAX;
    return s->agc_gain;
}

/* 对数谱通量节拍：阈值 = 最近 43 帧中位数×1.5+0.02；冷却 2 帧。 */
static float era_fft_beat_step(EraFftSpectrum *s, float flux, int had_prev)
{
    float sorted[ERA_FFT_FLUX_LEN];
    int count;
    float median, threshold, peak = 0.0f;

    s->flux_hist[s->flux_pos] = flux;
    s->flux_pos = (s->flux_pos + 1) % ERA_FFT_FLUX_LEN;
    if (s->flux_count < ERA_FFT_FLUX_LEN) s->flux_count += 1;
    if (!had_prev) return 0.0f;

    count = s->flux_count;
    for (int i = 0; i < count; i++) sorted[i] = s->flux_hist[i];

    for (int a = 1; a < count; a++) {
        const float v = sorted[a];
        int b = a;
        while (b > 0 && sorted[b - 1] > v) {
            sorted[b] = sorted[b - 1];
            b--;
        }
        sorted[b] = v;
    }

    median = sorted[count / 2];
    threshold = median * 1.5f + 0.02f;
    peak = threshold;
    for (int i = 0; i < count; i++) {
        if (sorted[i] > peak) peak = sorted[i];
    }

    if (s->cooldown > 0) {
        s->cooldown -= 1;
        return 0.0f;
    }
    if (flux <= threshold) return 0.0f;

    s->cooldown = ERA_FFT_BEAT_COOLDOWN;
    if (peak - threshold <= 0.0f) return 0.0f;
    {
        float strength = (flux - threshold) / (peak - threshold);
        if (strength < 0.0f) strength = 0.0f;
        if (strength > 1.0f) strength = 1.0f;
        return strength;
    }
}

float era_fft_spectrum_process_centered(EraFftSpectrum *s,
                                        const float *l, const float *r,
                                        int frames, int future_samples,
                                        float *out_l, float *out_r)
{
    float flux = 0.0f;
    float agc;
    float decay;
    int had_prev;

    if (!s || !l || !r || !out_l || !out_r) return 0.0f;
    if (s->bins <= 0) return 0.0f;
    if (frames <= 0) {
        memset(out_l, 0, (size_t)s->bins * sizeof(float));
        memset(out_r, 0, (size_t)s->bins * sizeof(float));
        return 0.0f;
    }
    if (future_samples < 0) future_samples = 0;
    if (future_samples > frames) future_samples = frames;

    /* 每种窗长只算一次变换，回填属于该档位的频带。 */
    for (int si = 0; si < ERA_FFT_STAGES; si++) {
        EraFftStage *st = &s->stages[si];
        if (!st->tx || !st->run) continue;

        era_fft_fill(st, l, frames, future_samples);
        st->run(st->tx, st->out, st->input, sizeof(float));
        for (int i = 0; i < s->bins; i++) {
            if (s->band_stage[i] == si) {
                s->band_l[i] = era_fft_band_mag(st, s->band_klo[i], s->band_khi[i]);
            }
        }

        era_fft_fill(st, r, frames, future_samples);
        st->run(st->tx, st->out, st->input, sizeof(float));
        for (int i = 0; i < s->bins; i++) {
            if (s->band_stage[i] == si) {
                s->band_r[i] = era_fft_band_mag(st, s->band_klo[i], s->band_khi[i]);
            }
        }
    }

    /* 节拍通量：L/R 平均原始带幅度。 */
    had_prev = s->has_prev;
    for (int i = 0; i < s->bins; i++) {
        const float comb = 0.5f * (s->band_l[i] + s->band_r[i]);
        if (had_prev) {
            const float d = logf(1.0f + comb) - logf(1.0f + s->prev_mag[i]);
            if (d > 0.0f) flux += d;
        }
        s->prev_mag[i] = comb;
    }
    s->has_prev = 1;

    agc = era_fft_agc_step(s);
    decay = ERA_FFT_PEAK_DECAY_PER_S * ERA_FFT_FRAME_INTERVAL_S;

    for (int i = 0; i < s->bins; i++) {
        const float gain = agc * s->tilt_gain[i] * ERA_FFT_DISPLAY_GAIN;
        float v_l = era_fft_map_db(s->band_l[i] * gain);
        float v_r = era_fft_map_db(s->band_r[i] * gain);
        if (s->gamma != 1.0f) {
            v_l = powf(v_l, s->gamma);
            v_r = powf(v_r, s->gamma);
        }
        if (!(v_l >= 0.0f)) v_l = 0.0f;
        if (!(v_r >= 0.0f)) v_r = 0.0f;
        if (v_l > 1.0f) v_l = 1.0f;
        if (v_r > 1.0f) v_r = 1.0f;
        out_l[i] = v_l;
        out_r[i] = v_r;

        if (s->peak_hold) {
            const float floor_l = s->peak_l[i] - decay > 0.0f
                                  ? s->peak_l[i] - decay : 0.0f;
            const float floor_r = s->peak_r[i] - decay > 0.0f
                                  ? s->peak_r[i] - decay : 0.0f;
            s->peak_l[i] = v_l > floor_l ? v_l : floor_l;
            s->peak_r[i] = v_r > floor_r ? v_r : floor_r;
        } else {
            s->peak_l[i] = v_l;
            s->peak_r[i] = v_r;
        }
    }

    return era_fft_beat_step(s, flux, had_prev);
}

void era_fft_spectrum_peaks(const EraFftSpectrum *s, float *out_l, float *out_r)
{
    if (!s || !out_l || !out_r) return;
    memcpy(out_l, s->peak_l, (size_t)s->bins * sizeof(float));
    memcpy(out_r, s->peak_r, (size_t)s->bins * sizeof(float));
}

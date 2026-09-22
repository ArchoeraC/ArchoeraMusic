// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_dsp_kernel.c — 内核 DSP（zk_dsp_*）与纯 C 实现逐块对照
 *
 * 方向① 地基「DSP 下沉 Zig」验收：把生产线的 C 实现（equalizer.c /
 * limiter.c / loudness.c，经 tests/dsp_ref 的 C 源以重命名符号再编译一份）
 * 与内核实现（zk_dsp_*，Zig）在**同一确定性输入**上对拍：
 *   - 无损/直通路径：逐位一致；
 *   - 有损路径（IIR EQ / 软膝限幅 / 增益）：|corr| ≥ 0.999 且样本误差有界。
 *
 * 该测试同时覆盖「C 壳路由内核后对外行为不变」的核心风险点。
 */

#include "../include/kernel_bridge.h"
#include "../src/equalizer.h"
#include "../src/limiter.h"
#include "../src/loudness.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── 纯 C 参考实现（tests/dsp_ref 的 C 源，符号前缀 dspref_）── */
Equalizer *dspref_eq_create(int sample_rate, int channels);
void dspref_eq_set_gains(Equalizer *eq, const float gains[EQ_BANDS]);
void dspref_eq_set_preamp(Equalizer *eq, float preamp_db);
void dspref_eq_process(Equalizer *eq, float *pcm, int samples);
void dspref_eq_destroy(Equalizer *eq);

Limiter *dspref_lim_create(int sample_rate, int channels);
void dspref_lim_set_enabled(Limiter *lim, bool enabled);
void dspref_lim_set_threshold(Limiter *lim, float threshold_db);
void dspref_lim_process(Limiter *lim, float *pcm, int samples);
float dspref_lim_get_threshold(const Limiter *lim);
void dspref_lim_destroy(Limiter *lim);

Loudness *dspref_loud_create(int sample_rate, int channels);
void dspref_loud_set_enabled(Loudness *loud, bool enabled);
void dspref_loud_set_target(Loudness *loud, float target_lufs);
void dspref_loud_set_gain(Loudness *loud, float gain_db);
void dspref_loud_process(Loudness *loud, float *pcm, int samples);
void dspref_loud_destroy(Loudness *loud);

#define N_FRAMES 2048
#define N_CH 2
#define N_SAMPLES (N_FRAMES * N_CH)

static void fill_signal(float *buf, int n, unsigned seed)
{
    unsigned s = seed ? seed : 1u;
    for (int i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        buf[i] = (float)((double)(s >> 8) / 8388608.0 - 1.0); /* [-1, 1) */
    }
}

static double correlation(const float *a, const float *b, int n)
{
    double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
    for (int i = 0; i < n; i++) {
        double x = a[i], y = b[i];
        sa += x;
        sb += y;
        saa += x * x;
        sbb += y * y;
        sab += x * y;
    }
    double cov = sab - sa * sb / n;
    double va = saa - sa * sa / n;
    double vb = sbb - sb * sb / n;
    double denom = sqrt(va * vb);
    return denom > 0.0 ? cov / denom : 1.0;
}

static double max_abs_diff(const float *a, const float *b, int n)
{
    double m = 0.0;
    for (int i = 0; i < n; i++) {
        double d = fabs((double)a[i] - (double)b[i]);
        if (d > m) m = d;
    }
    return m;
}

static int fails = 0;
#define CHECK(cond, fmt, ...)                                          \
    do {                                                               \
        if (!(cond)) {                                                 \
            fprintf(stderr, "FAIL %s:%d: " fmt "\n", __FILE__, __LINE__, \
                    ##__VA_ARGS__);                                    \
            fails++;                                                   \
        }                                                              \
    } while (0)

/* ── 均衡器 ─────────────────────────────────────────────────── */

static void test_eq_passthrough(void)
{
    float in_a[N_SAMPLES], in_b[N_SAMPLES];
    fill_signal(in_a, N_SAMPLES, 0xE9u);
    memcpy(in_b, in_a, sizeof(in_a));

    Equalizer *cref = dspref_eq_create(48000, N_CH);
    ZkDspEq *zk = zk_dsp_eq_create(48000, N_CH);
    CHECK(cref != NULL && zk != NULL, "eq create failed");

    /* 默认全零增益 + preamp=0：逐位直通 */
    dspref_eq_process(cref, in_a, N_FRAMES);
    zk_dsp_eq_process(zk, in_b, N_FRAMES);
    CHECK(memcmp(in_a, in_b, sizeof(in_a)) == 0, "eq passthrough 非逐位一致");

    dspref_eq_destroy(cref);
    zk_dsp_eq_destroy(zk);
}

static void test_eq_processing(void)
{
    const float gains[EQ_BANDS] = { 2.0f, 0.0f, -1.5f, 0.0f, 3.0f,
                                    4.0f, 0.0f, -2.0f, 1.0f, 0.0f };
    const float preamp = -3.0f;

    float in_a[N_SAMPLES], in_b[N_SAMPLES];
    fill_signal(in_a, N_SAMPLES, 0x1234u);
    memcpy(in_b, in_a, sizeof(in_a));

    Equalizer *cref = dspref_eq_create(48000, N_CH);
    ZkDspEq *zk = zk_dsp_eq_create(48000, N_CH);
    CHECK(cref != NULL && zk != NULL, "eq create failed");
    if (!cref || !zk) return;

    dspref_eq_set_gains(cref, gains);
    dspref_eq_set_preamp(cref, preamp);
    zk_dsp_eq_set_gains(zk, gains);
    zk_dsp_eq_set_preamp(zk, preamp);

    dspref_eq_process(cref, in_a, N_FRAMES);
    zk_dsp_eq_process(zk, in_b, N_FRAMES);

    double corr = correlation(in_a, in_b, N_SAMPLES);
    double mad = max_abs_diff(in_a, in_b, N_SAMPLES);
    printf("  EQ vs C: corr=%.8f max_abs=%.3e\n", corr, mad);
    CHECK(fabs(corr) >= 0.999, "eq corr=%.8f < 0.999", corr);
    CHECK(mad <= 1e-3, "eq max_abs=%.3e > 1e-3", mad);

    dspref_eq_destroy(cref);
    zk_dsp_eq_destroy(zk);
}

/* ── 限幅器 ─────────────────────────────────────────────────── */

static void test_limiter(const float threshold_db)
{
    float in_a[N_SAMPLES], in_b[N_SAMPLES];
    fill_signal(in_a, N_SAMPLES, 0xABCDu);
    /* 放大到含超阈值样本 */
    for (int i = 0; i < N_SAMPLES; i++) in_a[i] *= 1.8f;
    memcpy(in_b, in_a, sizeof(in_a));

    Limiter *cref = dspref_lim_create(48000, N_CH);
    ZkDspLimiter *zk = zk_dsp_limiter_create(48000, N_CH);
    CHECK(cref != NULL && zk != NULL, "limiter create failed");
    if (!cref || !zk) return;

    dspref_lim_set_threshold(cref, threshold_db);
    zk_dsp_limiter_set_threshold(zk, threshold_db);
    dspref_lim_process(cref, in_a, N_FRAMES);
    zk_dsp_limiter_process(zk, in_b, N_FRAMES);

    double corr = correlation(in_a, in_b, N_SAMPLES);
    double mad = max_abs_diff(in_a, in_b, N_SAMPLES);
    printf("  Limiter(%.1fdB) vs C: corr=%.8f max_abs=%.3e\n", threshold_db, corr, mad);
    CHECK(fabs(corr) >= 0.999, "limiter corr=%.8f < 0.999", corr);
    CHECK(mad <= 1e-5, "limiter max_abs=%.3e > 1e-5", mad);

    dspref_lim_destroy(cref);
    zk_dsp_limiter_destroy(zk);
}

static void test_limiter_defaults(void)
{
    ZkDspLimiter *zk = zk_dsp_limiter_create(48000, N_CH);
    CHECK(zk != NULL, "limiter create failed");
    if (!zk) return;
    float t = zk_dsp_limiter_get_threshold(zk);
    CHECK(fabsf(t - (-1.0f)) < 1e-6f, "limiter 默认阈值=%.4f != -1", t);
    zk_dsp_limiter_destroy(zk);
}

/* ── 响度 ───────────────────────────────────────────────────── */

static void test_loudness(void)
{
    float in_a[N_SAMPLES], in_b[N_SAMPLES];
    fill_signal(in_a, N_SAMPLES, 0x55AAu);
    for (int i = 0; i < N_SAMPLES; i++) in_a[i] *= 0.2f;
    memcpy(in_b, in_a, sizeof(in_a));

    Loudness *cref = dspref_loud_create(48000, N_CH);
    ZkDspLoudness *zk = zk_dsp_loudness_create(48000, N_CH);
    CHECK(cref != NULL && zk != NULL, "loudness create failed");
    if (!cref || !zk) return;

    dspref_loud_set_enabled(cref, true);
    zk_dsp_loudness_set_enabled(zk, 1);
    dspref_loud_set_gain(cref, 3.0f);
    zk_dsp_loudness_set_gain(zk, 3.0f);

    dspref_loud_process(cref, in_a, N_FRAMES);
    zk_dsp_loudness_process(zk, in_b, N_FRAMES);

    double corr = correlation(in_a, in_b, N_SAMPLES);
    double mad = max_abs_diff(in_a, in_b, N_SAMPLES);
    printf("  Loudness(+3dB) vs C: corr=%.8f max_abs=%.3e\n", corr, mad);
    CHECK(fabs(corr) >= 0.999, "loudness corr=%.8f < 0.999", corr);
    CHECK(mad <= 1e-6, "loudness max_abs=%.3e > 1e-6", mad);

    dspref_loud_destroy(cref);
    zk_dsp_loudness_destroy(zk);
}

int main(void)
{
    printf("test_dsp_kernel: Zig 内核 DSP vs C 实现对照\n");
    test_eq_passthrough();
    test_eq_processing();
    test_limiter(-1.0f);
    test_limiter(-6.0f);
    test_limiter_defaults();
    test_loudness();

    if (fails) {
        fprintf(stderr, "test_dsp_kernel: %d 处失败\n", fails);
        return 1;
    }
    printf("test_dsp_kernel: ALL PASS\n");
    return 0;
}

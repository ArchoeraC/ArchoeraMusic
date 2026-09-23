// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_parametric_eq.c — 参数化 EQ（方向① D1）验收
 *
 * 覆盖：
 *   - 生产线 C API（`parametric_eq_*`，HAS_ARCHOERA_KERNEL 时路由内核）行为与
 *     逐位旁通；
 *   - 内核 `zk_dsp_peq_*` 与纯 C 参考（tests/dsp_ref/parametric_eq_ref.c，
 *     重命名符号再编译一份 src/parametric_eq.c）逐块对照：|corr| ≥ 0.999
 *     且样本误差有界；
 *   - peak/low-shelf/high-shelf 频响行为、NaN/越界参数防护。
 */

#include "../include/kernel_bridge.h"
#include "../src/parametric_eq.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ── 纯 C 参考实现（tests/dsp_ref/parametric_eq_ref.c，符号前缀 dspref_peq_）── */
ParametricEq *dspref_peq_create(int sample_rate, int channels, int max_bands);
void dspref_peq_set_bands(ParametricEq *eq, const float *flat, int band_count);
void dspref_peq_set_enabled(ParametricEq *eq, bool enabled);
void dspref_peq_set_preamp(ParametricEq *eq, float preamp_db);
void dspref_peq_process(ParametricEq *eq, float *pcm, int samples);
void dspref_peq_destroy(ParametricEq *eq);

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
        sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y;
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

static double rms_of(const float *a, int n)
{
    double s = 0.0;
    for (int i = 0; i < n; i++) s += (double)a[i] * (double)a[i];
    return sqrt(s / n);
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

/* 3 段测试用参数（peak + low-shelf + high-shelf） */
static const float k_flat[] = {
    PEQ_KIND_PEAK,       1000.0f, 1.0f,    6.0f,
    PEQ_KIND_LOW_SHELF,  120.0f,  0.7071f, 8.0f,
    PEQ_KIND_HIGH_SHELF, 6000.0f, 0.7071f, -5.0f,
};
#define K_BANDS 3

/* ── 生产线 C API：旁通逐位 ─────────────────────────────────────── */

static void test_c_api_passthrough(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0xE9u);
    memcpy(b, a, sizeof(a));

    ParametricEq *c = parametric_eq_create(48000, N_CH, PEQ_MAX_BANDS);
    CHECK(c != NULL, "parametric_eq_create failed");
    if (!c) return;

    parametric_eq_process(c, a, N_FRAMES); /* 默认无段 = 直通 */
    CHECK(memcmp(a, b, sizeof(a)) == 0, "peq 默认旁通非逐位一致");

    /* 有段但全零增益仍逐位 */
    float zero[] = { PEQ_KIND_PEAK, 1000.0f, 1.0f, 0.0f };
    parametric_eq_set_bands(c, zero, 1);
    parametric_eq_process(c, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "peq 全零增益非逐位一致");

    /* 显式禁用 → 逐位 */
    parametric_eq_set_bands(c, k_flat, K_BANDS);
    parametric_eq_set_enabled(c, false);
    parametric_eq_process(c, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "peq 禁用非逐位一致");

    parametric_eq_destroy(c);
}

/* ── 生产线 C API：峰值抬升所在频段 ───────────────────────────── */

static void test_c_api_peak_boost(void)
{
    ParametricEq *c = parametric_eq_create(48000, 1, PEQ_MAX_BANDS);
    CHECK(c != NULL, "create failed");
    if (!c) return;
    float one[] = { PEQ_KIND_PEAK, 1000.0f, 1.0f, 6.0f };
    parametric_eq_set_bands(c, one, 1);

    const int n = 8192;
    float *buf = malloc((size_t)n * sizeof(float));
    if (!buf) { parametric_eq_destroy(c); return; }
    const double w = 2.0 * M_PI * 1000.0 / 48000.0;
    for (int i = 0; i < n; i++) buf[i] = (float)sin(w * i);

    parametric_eq_process(c, buf, n);
    double r = rms_of(buf + n / 4, n / 2);
    printf("  PEQ peak +6dB @1k: rms=%.4f\n", r);
    CHECK(r > 1.1, "peak 未抬升（rms=%.4f）", r);

    free(buf);
    parametric_eq_destroy(c);
}

/* ── 生产线 C API：NaN/越界参数防护 ───────────────────────────── */

static void test_c_api_guard(void)
{
    ParametricEq *c = parametric_eq_create(48000, N_CH, PEQ_MAX_BANDS);
    CHECK(c != NULL, "create failed");
    if (!c) return;

    float bad[] = {
        PEQ_KIND_PEAK,      NAN,      0.0f,  NAN,
        PEQ_KIND_LOW_SHELF, 1.0e9f,  -1.0f,  -1.0e9f,
        99,                 1000.0f,  1.0f,  6.0f, /* 非法 kind → 禁用 */
    };
    parametric_eq_set_bands(c, bad, 3);
    parametric_eq_set_preamp(c, NAN);

    float buf[N_SAMPLES];
    fill_signal(buf, N_SAMPLES, 0x77u);
    parametric_eq_process(c, buf, N_FRAMES);
    int ok = 1;
    for (int i = 0; i < N_SAMPLES; i++) if (!isfinite(buf[i])) { ok = 0; break; }
    CHECK(ok, "peq 非法参数产生 NaN/Inf");

    parametric_eq_destroy(c);
}

/* ── 内核 vs 纯 C 参考 ───────────────────────────────────────── */

#if defined(HAS_ARCHOERA_KERNEL)
static void test_kernel_vs_c(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0x1234u);
    memcpy(b, a, sizeof(a));

    ParametricEq *cref = dspref_peq_create(48000, N_CH, PEQ_MAX_BANDS);
    ZkDspPeq *zk = zk_dsp_peq_create(48000, N_CH, PEQ_MAX_BANDS);
    CHECK(cref != NULL && zk != NULL, "peq create failed");
    if (!cref || !zk) { if (cref) dspref_peq_destroy(cref); return; }

    dspref_peq_set_bands(cref, k_flat, K_BANDS);
    dspref_peq_set_preamp(cref, -2.0f);
    zk_dsp_peq_clear(zk);
    for (int i = 0; i < K_BANDS; i++) {
        zk_dsp_peq_set_band(zk, i, (int)k_flat[i * 4], k_flat[i * 4 + 1],
                            k_flat[i * 4 + 2], k_flat[i * 4 + 3]);
    }
    zk_dsp_peq_set_preamp(zk, -2.0f);

    dspref_peq_process(cref, a, N_FRAMES);
    zk_dsp_peq_process(zk, b, N_FRAMES);

    double corr = correlation(a, b, N_SAMPLES);
    double mad = max_abs_diff(a, b, N_SAMPLES);
    printf("  PEQ vs C: corr=%.8f max_abs=%.3e\n", corr, mad);
    CHECK(fabs(corr) >= 0.999, "peq corr=%.8f < 0.999", corr);
    CHECK(mad <= 2e-3, "peq max_abs=%.3e > 2e-3", mad);

    dspref_peq_destroy(cref);
    zk_dsp_peq_destroy(zk);
}

static void test_kernel_passthrough(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0x55AAu);
    memcpy(b, a, sizeof(a));

    ZkDspPeq *zk = zk_dsp_peq_create(48000, N_CH, PEQ_MAX_BANDS);
    CHECK(zk != NULL, "zk peq create failed");
    if (!zk) return;

    zk_dsp_peq_process(zk, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "zk peq 默认旁通非逐位一致");

    /* 一阶非法参数防护 */
    zk_dsp_peq_set_band(zk, 0, 0, NAN, 0.0f, INFINITY);
    zk_dsp_peq_set_band(zk, 1, 1, 1.0e9f, -1.0f, -1.0e9f);
    zk_dsp_peq_set_band(zk, 2, 7, 1000.0f, 1.0f, 6.0f);
    zk_dsp_peq_set_preamp(zk, NAN);
    zk_dsp_peq_process(zk, a, N_FRAMES);
    int ok = 1;
    for (int i = 0; i < N_SAMPLES; i++) if (!isfinite(a[i])) { ok = 0; break; }
    CHECK(ok, "zk peq 非法参数产生 NaN/Inf");

    zk_dsp_peq_destroy(zk);
}
#endif /* HAS_ARCHOERA_KERNEL */

int main(void)
{
    printf("test_parametric_eq: 参数化 EQ（方向① D1）\n");
    test_c_api_passthrough();
    test_c_api_peak_boost();
    test_c_api_guard();
#if defined(HAS_ARCHOERA_KERNEL)
    test_kernel_vs_c();
    test_kernel_passthrough();
#else
    printf("  (HAS_ARCHOERA_KERNEL 未定义，跳过内核对照)\n");
#endif

    if (fails) {
        fprintf(stderr, "test_parametric_eq: %d 处失败\n", fails);
        return 1;
    }
    printf("test_parametric_eq: ALL PASS\n");
    return 0;
}

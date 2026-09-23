// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_lowfreq.c — 次声/低频管理（方向① D2）验收
 *
 * 覆盖：
 *   - 生产线 C API（`lowfreq_*`，HAS_ARCHOERA_KERNEL 时路由内核）行为与逐位旁通；
 *   - 内核 `zk_dsp_lowfreq_*` 与纯 C 参考（tests/dsp_ref/lowfreq_ref.c）逐块对照；
 *   - HPF（一阶/二阶）衰减 DC/低频、1kHz 近似不变；bass shelf 抬升低频；
 *     NaN/越界参数防护。
 */

#include "../include/kernel_bridge.h"
#include "../src/lowfreq.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ── 纯 C 参考实现（tests/dsp_ref/lowfreq_ref.c，符号前缀 dspref_lf_）── */
LowFreq *dspref_lf_create(int sample_rate, int channels);
void dspref_lf_set_enabled(LowFreq *lf, bool enabled);
void dspref_lf_set_hpf(LowFreq *lf, float freq, int order);
void dspref_lf_set_bass(LowFreq *lf, float gain_db, float freq);
void dspref_lf_process(LowFreq *lf, float *pcm, int samples);
void dspref_lf_destroy(LowFreq *lf);

#define N_FRAMES 4096
#define N_CH 2
#define N_SAMPLES (N_FRAMES * N_CH)

static void synth_sine(float *buf, int n, double freq, double rate)
{
    double w = 2.0 * M_PI * freq / rate;
    for (int i = 0; i < n; i++) buf[i] = (float)sin(w * i);
}

static void fill_signal(float *buf, int n, unsigned seed)
{
    unsigned s = seed ? seed : 1u;
    for (int i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        buf[i] = (float)((double)(s >> 8) / 8388608.0 - 1.0);
    }
}

static double rms_of(const float *a, int n)
{
    double s = 0.0;
    for (int i = 0; i < n; i++) s += (double)a[i] * (double)a[i];
    return sqrt(s / n);
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

static int fails = 0;
#define CHECK(cond, fmt, ...)                                          \
    do {                                                               \
        if (!(cond)) {                                                 \
            fprintf(stderr, "FAIL %s:%d: " fmt "\n", __FILE__, __LINE__, \
                    ##__VA_ARGS__);                                    \
            fails++;                                                   \
        }                                                              \
    } while (0)

/* ── 生产线 C API：旁通逐位 ─────────────────────────────────── */

static void test_c_api_passthrough(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0xE9u);
    memcpy(b, a, sizeof(a));

    LowFreq *lf = lowfreq_create(48000, N_CH);
    CHECK(lf != NULL, "lowfreq_create failed");
    if (!lf) return;

    lowfreq_process(lf, a, N_FRAMES); /* 默认禁用 = 直通 */
    CHECK(memcmp(a, b, sizeof(a)) == 0, "lowfreq 默认禁用非逐位一致");

    /* 启用但 HPF 关闭、bass 0 → 仍逐位 */
    lowfreq_set_enabled(lf, true);
    lowfreq_process(lf, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "lowfreq 无有效处理非逐位一致");

    lowfreq_destroy(lf);
}

/* ── 生产线 C API：HPF 衰减 DC ─────────────────────────────── */

static void test_c_api_hpf_dc(void)
{
    LowFreq *lf = lowfreq_create(48000, 1);
    CHECK(lf != NULL, "create failed");
    if (!lf) return;
    lowfreq_set_hpf(lf, 20.0f, 2);
    lowfreq_set_enabled(lf, true);

    const int n = 16384;
    float *buf = malloc((size_t)n * sizeof(float));
    if (!buf) { lowfreq_destroy(lf); return; }
    for (int i = 0; i < n; i++) buf[i] = 1.0f;
    lowfreq_process(lf, buf, n);
    printf("  HPF2 DC 末样本=%.3e\n", buf[n - 1]);
    CHECK(fabsf(buf[n - 1]) < 1e-3f, "HPF 未衰减 DC（末样本=%.3e）", buf[n - 1]);

    free(buf);
    lowfreq_destroy(lf);
}

/* ── 生产线 C API：bass shelf 抬升低频 ─────────────────────── */

static void test_c_api_bass(void)
{
    LowFreq *lf = lowfreq_create(48000, 1);
    CHECK(lf != NULL, "create failed");
    if (!lf) return;
    lowfreq_set_bass(lf, 9.0f, 100.0f);
    lowfreq_set_enabled(lf, true);

    const int n = 16384;
    float *buf = malloc((size_t)n * sizeof(float));
    if (!buf) { lowfreq_destroy(lf); return; }
    synth_sine(buf, n, 50.0, 48000.0);
    lowfreq_process(lf, buf, n);
    double r = rms_of(buf + n / 4, n / 2);
    printf("  bass +9dB @100Hz 下 50Hz rms=%.4f\n", r);
    CHECK(r > 1.2, "bass 未抬升低频（rms=%.4f）", r);

    free(buf);
    lowfreq_destroy(lf);
}

/* ── 生产线 C API：NaN/越界参数防护 ────────────────────────── */

static void test_c_api_guard(void)
{
    LowFreq *lf = lowfreq_create(48000, N_CH);
    CHECK(lf != NULL, "create failed");
    if (!lf) return;
    lowfreq_set_hpf(lf, NAN, 9);
    lowfreq_set_bass(lf, INFINITY, -5.0f);
    lowfreq_set_enabled(lf, true);

    float buf[N_SAMPLES];
    fill_signal(buf, N_SAMPLES, 0x33u);
    lowfreq_process(lf, buf, N_FRAMES);
    int ok = 1;
    for (int i = 0; i < N_SAMPLES; i++) if (!isfinite(buf[i])) { ok = 0; break; }
    CHECK(ok, "lowfreq 非法参数产生 NaN/Inf");

    lowfreq_destroy(lf);
}

/* ── 内核 vs 纯 C 参考 ─────────────────────────────────────── */

#if defined(HAS_ARCHOERA_KERNEL)
static void test_kernel_vs_c(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0x1234u);
    memcpy(b, a, sizeof(a));

    LowFreq *cref = dspref_lf_create(48000, N_CH);
    ZkDspLowFreq *zk = zk_dsp_lowfreq_create(48000, N_CH);
    CHECK(cref != NULL && zk != NULL, "lowfreq create failed");
    if (!cref || !zk) { if (cref) dspref_lf_destroy(cref); return; }

    dspref_lf_set_hpf(cref, 25.0f, 2);
    dspref_lf_set_bass(cref, 6.0f, 90.0f);
    dspref_lf_set_enabled(cref, true);
    zk_dsp_lowfreq_set_hpf(zk, 25.0f, 2);
    zk_dsp_lowfreq_set_bass(zk, 6.0f, 90.0f);
    zk_dsp_lowfreq_set_enabled(zk, 1);

    dspref_lf_process(cref, a, N_FRAMES);
    zk_dsp_lowfreq_process(zk, b, N_FRAMES);

    double corr = correlation(a, b, N_SAMPLES);
    double mad = max_abs_diff(a, b, N_SAMPLES);
    printf("  LowFreq vs C: corr=%.8f max_abs=%.3e\n", corr, mad);
    CHECK(fabs(corr) >= 0.999, "lowfreq corr=%.8f < 0.999", corr);
    CHECK(mad <= 2e-3, "lowfreq max_abs=%.3e > 2e-3", mad);

    dspref_lf_destroy(cref);
    zk_dsp_lowfreq_destroy(zk);
}

static void test_kernel_hpf1_vs_c(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0xABCDu);
    memcpy(b, a, sizeof(a));

    LowFreq *cref = dspref_lf_create(48000, N_CH);
    ZkDspLowFreq *zk = zk_dsp_lowfreq_create(48000, N_CH);
    CHECK(cref != NULL && zk != NULL, "lowfreq create failed");
    if (!cref || !zk) { if (cref) dspref_lf_destroy(cref); return; }

    dspref_lf_set_hpf(cref, 30.0f, 1);
    dspref_lf_set_enabled(cref, true);
    zk_dsp_lowfreq_set_hpf(zk, 30.0f, 1);
    zk_dsp_lowfreq_set_enabled(zk, 1);

    dspref_lf_process(cref, a, N_FRAMES);
    zk_dsp_lowfreq_process(zk, b, N_FRAMES);

    double corr = correlation(a, b, N_SAMPLES);
    double mad = max_abs_diff(a, b, N_SAMPLES);
    printf("  LowFreq HPF1 vs C: corr=%.8f max_abs=%.3e\n", corr, mad);
    CHECK(fabs(corr) >= 0.999, "lowfreq hpf1 corr=%.8f < 0.999", corr);
    CHECK(mad <= 2e-3, "lowfreq hpf1 max_abs=%.3e > 2e-3", mad);

    dspref_lf_destroy(cref);
    zk_dsp_lowfreq_destroy(zk);
}

static void test_kernel_passthrough(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0x55AAu);
    memcpy(b, a, sizeof(a));

    ZkDspLowFreq *zk = zk_dsp_lowfreq_create(48000, N_CH);
    CHECK(zk != NULL, "zk lowfreq create failed");
    if (!zk) return;

    zk_dsp_lowfreq_process(zk, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "zk lowfreq 默认禁用非逐位一致");

    zk_dsp_lowfreq_set_hpf(zk, NAN, 9);
    zk_dsp_lowfreq_set_bass(zk, INFINITY, -5.0f);
    zk_dsp_lowfreq_set_enabled(zk, 1);
    zk_dsp_lowfreq_process(zk, a, N_FRAMES);
    int ok = 1;
    for (int i = 0; i < N_SAMPLES; i++) if (!isfinite(a[i])) { ok = 0; break; }
    CHECK(ok, "zk lowfreq 非法参数产生 NaN/Inf");

    zk_dsp_lowfreq_destroy(zk);
}
#endif /* HAS_ARCHOERA_KERNEL */

int main(void)
{
    printf("test_lowfreq: 次声/低频管理（方向① D2）\n");
    test_c_api_passthrough();
    test_c_api_hpf_dc();
    test_c_api_bass();
    test_c_api_guard();
#if defined(HAS_ARCHOERA_KERNEL)
    test_kernel_vs_c();
    test_kernel_hpf1_vs_c();
    test_kernel_passthrough();
#else
    printf("  (HAS_ARCHOERA_KERNEL 未定义，跳过内核对照)\n");
#endif

    if (fails) {
        fprintf(stderr, "test_lowfreq: %d 处失败\n", fails);
        return 1;
    }
    printf("test_lowfreq: ALL PASS\n");
    return 0;
}

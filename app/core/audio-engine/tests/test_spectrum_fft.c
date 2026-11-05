// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_spectrum_fft.c — FFmpeg FFT 频谱后端（libavutil/tx）
 *
 * 验证（headless，无设备/文件依赖）：
 *   - 非法参数拒绝创建；
 *   - 60Hz / 1kHz / 12kHz 正弦峰值落在期望对数带 ±2；
 *   - 静音全 0、白噪声有限非负；
 *   - 左右分离（仅 L 有信号 → R 全 0）；
 *   - 0dBFS 正弦校准 ≈ 0.7–0.9（-60..0dB 映射 + 0.28 量程）；
 *   - 峰值保持：静音后保持并衰减，关闭后清零；
 *   - γ / 倾斜 / AGC 运行时不崩溃且方向正确。
 *
 * 直接调用 `era_fft_spectrum_*`，与内核开关 / 默认后端选择无关。
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spectrum_fft.h"

#define TEST_SR 48000
#define TEST_BINS 128
#define TEST_MIN_HZ 40.0
#define TEST_MAX_HZ 16000.0
#define TEST_FRAMES 12288
#define TEST_FUTURE 6144
#define TEST_PI 3.14159265358979323846

static int g_fail;

static void check(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_fail = 1;
    }
}

static void fill_sine(float *buf, int n, double freq, double amp)
{
    for (int i = 0; i < n; i++) {
        buf[i] = (float)(amp * sin(2.0 * TEST_PI * freq * (double)i / TEST_SR));
    }
}

static int expected_band(double freq, double min_hz, double max_hz, int bins)
{
    const double frac = log(freq / min_hz) / log(max_hz / min_hz);
    int b = (int)floor(frac * (double)bins);
    if (b < 0) b = 0;
    if (b >= bins) b = bins - 1;
    return b;
}

static int peak_band(const float *v, int bins)
{
    int best = 0;
    for (int i = 1; i < bins; i++) {
        if (v[i] > v[best]) best = i;
    }
    return best;
}

static int all_finite_nonneg(const float *v, int bins)
{
    for (int i = 0; i < bins; i++) {
        if (!isfinite(v[i]) || v[i] < 0.0f || v[i] > 1.0f) return 0;
    }
    return 1;
}

static void process(EraFftSpectrum *s, const float *l, const float *r,
                    float *out_l, float *out_r)
{
    (void)era_fft_spectrum_process_centered(s, l, r, TEST_FRAMES,
                                            TEST_FUTURE, out_l, out_r);
}

int main(void)
{
    float *mono = (float *)calloc(TEST_FRAMES, sizeof(float));
    float *silence = (float *)calloc(TEST_FRAMES, sizeof(float));
    float *out_l = (float *)calloc(TEST_BINS, sizeof(float));
    float *out_r = (float *)calloc(TEST_BINS, sizeof(float));
    float *peak_l = (float *)calloc(TEST_BINS, sizeof(float));
    float *peak_r = (float *)calloc(TEST_BINS, sizeof(float));

    if (!mono || !silence || !out_l || !out_r || !peak_l || !peak_r) {
        fprintf(stderr, "FAIL: OOM\n");
        return 1;
    }

    /* 1. 非法参数 */
    check(era_fft_spectrum_create(0, 128, 40.0f, 16000.0f) == NULL, "sample_rate=0 拒绝");
    check(era_fft_spectrum_create(48000, 0, 40.0f, 16000.0f) == NULL, "bins=0 拒绝");
    check(era_fft_spectrum_create(48000, 128, 40.0f, 24000.0f) == NULL,
          "max_hz 达 Nyquist 拒绝");
    check(era_fft_spectrum_create(48000, 128, 400.0f, 40.0f) == NULL,
          "min_hz>max_hz 拒绝");

    EraFftSpectrum *s = era_fft_spectrum_create(TEST_SR, TEST_BINS,
                                                TEST_MIN_HZ, TEST_MAX_HZ);
    check(s != NULL, "创建分析器");
    if (!s) return 1;

    /* 2. 正弦落带：60Hz / 1kHz / 12kHz */
    {
        const double freqs[] = {60.0, 1000.0, 12000.0};
        for (size_t k = 0; k < sizeof(freqs) / sizeof(freqs[0]); k++) {
            const int want = expected_band(freqs[k], TEST_MIN_HZ, TEST_MAX_HZ,
                                           TEST_BINS);
            int got;
            fill_sine(mono, TEST_FRAMES, freqs[k], 0.8);
            era_fft_spectrum_reset(s);
            process(s, mono, mono, out_l, out_r);
            got = peak_band(out_l, TEST_BINS);
            check(abs(got - want) <= 2, "正弦峰值落在期望带 ±2");
            check(all_finite_nonneg(out_l, TEST_BINS), "输出有限且 [0,1]");
        }
    }

    /* 3. 静音全 0 */
    era_fft_spectrum_reset(s);
    process(s, silence, silence, out_l, out_r);
    {
        int zero = 1;
        for (int i = 0; i < TEST_BINS; i++) {
            if (out_l[i] != 0.0f || out_r[i] != 0.0f) zero = 0;
        }
        check(zero, "静音全 0");
    }

    /* 4. 白噪声：有限、非负、不全 0 */
    era_fft_spectrum_reset(s);
    srand(12345);
    for (int i = 0; i < TEST_FRAMES; i++) {
        mono[i] = (float)((rand() / (double)RAND_MAX) * 2.0 - 1.0) * 0.2f;
    }
    process(s, mono, mono, out_l, out_r);
    check(all_finite_nonneg(out_l, TEST_BINS), "白噪声输出合法");
    check(peak_band(out_l, TEST_BINS) >= 0, "白噪声有能量");

    /* 5. 左右分离：仅 L 有信号 → R 全 0 */
    fill_sine(mono, TEST_FRAMES, 1000.0, 0.8);
    era_fft_spectrum_reset(s);
    process(s, mono, silence, out_l, out_r);
    {
        int r_zero = 1;
        for (int i = 0; i < TEST_BINS; i++) {
            if (out_r[i] != 0.0f) r_zero = 0;
        }
        check(r_zero, "仅 L 有信号 → R 全 0");
        check(peak_band(out_l, TEST_BINS) >= 0, "L 有能量");
    }

    /* 6. 0dBFS 校准：在带中心附近，显示值约 0.7–0.9 */
    fill_sine(mono, TEST_FRAMES, 1000.0, 1.0);
    era_fft_spectrum_reset(s);
    process(s, mono, mono, out_l, out_r);
    {
        const int b = peak_band(out_l, TEST_BINS);
        check(b == expected_band(1000.0, TEST_MIN_HZ, TEST_MAX_HZ, TEST_BINS),
              "1kHz 峰值带");
        check(out_l[b] > 0.60f && out_l[b] < 0.92f, "0dBFS 正弦校准 ≈ 0.7–0.9");
    }

    /* 7. 峰值保持：静音后保持并衰减，关闭后清零 */
    era_fft_spectrum_set_peak_hold(s, 1);
    era_fft_spectrum_reset(s);
    fill_sine(mono, TEST_FRAMES, 1000.0, 0.8);
    process(s, mono, mono, out_l, out_r);
    era_fft_spectrum_peaks(s, peak_l, peak_r);
    {
        const int b = peak_band(out_l, TEST_BINS);
        check(peak_l[b] >= out_l[b], "峰值 ≥ 当前值");
        for (int k = 0; k < 60; k++) {
            process(s, silence, silence, out_l, out_r);
        }
        era_fft_spectrum_peaks(s, peak_l, peak_r);
        check(peak_l[b] < 1e-6f, "静音 60 帧后峰值衰减到 0");
    }
    era_fft_spectrum_set_peak_hold(s, 0);
    era_fft_spectrum_peaks(s, peak_l, peak_r);
    {
        int zero = 1;
        for (int i = 0; i < TEST_BINS; i++) {
            if (peak_l[i] != 0.0f || peak_r[i] != 0.0f) zero = 0;
        }
        check(zero, "关闭峰值保持后清零");
    }

    /* 8. γ / 倾斜 / AGC 运行时方向 */
    fill_sine(mono, TEST_FRAMES, 1000.0, 0.3);
    era_fft_spectrum_reset(s);
    process(s, mono, mono, out_l, out_r);
    {
        const int b = expected_band(1000.0, TEST_MIN_HZ, TEST_MAX_HZ, TEST_BINS);
        const float base = out_l[b];
        era_fft_spectrum_set_gamma(s, 2.0f);
        era_fft_spectrum_reset(s);
        process(s, mono, mono, out_l, out_r);
        check(out_l[b] <= base + 1e-3f, "γ>1 压暗小信号");

        era_fft_spectrum_set_gamma(s, 1.0f);
        era_fft_spectrum_set_tilt(s, 6.0f);
        era_fft_spectrum_reset(s);
        process(s, mono, mono, out_l, out_r);
        check(all_finite_nonneg(out_l, TEST_BINS), "倾斜后输出合法");

        era_fft_spectrum_set_tilt(s, 0.0f);
        era_fft_spectrum_set_agc(s, 1);
        era_fft_spectrum_reset(s);
        process(s, mono, mono, out_l, out_r);
        check(all_finite_nonneg(out_l, TEST_BINS), "AGC 输出合法");
        era_fft_spectrum_set_agc(s, 0);
    }

    /* 9. 因果窗口（future=0）不崩溃 */
    era_fft_spectrum_reset(s);
    (void)era_fft_spectrum_process_centered(s, mono, mono, TEST_FRAMES, 0,
                                            out_l, out_r);
    check(all_finite_nonneg(out_l, TEST_BINS), "因果窗口输出合法");

    /* 10. reset / destroy 幂等 */
    era_fft_spectrum_reset(s);
    era_fft_spectrum_reset(NULL);
    era_fft_spectrum_destroy(s);
    era_fft_spectrum_destroy(NULL);

    free(mono);
    free(silence);
    free(out_l);
    free(out_r);
    free(peak_l);
    free(peak_r);

    if (g_fail) return 1;
    printf("ALL PASS\n");
    return 0;
}

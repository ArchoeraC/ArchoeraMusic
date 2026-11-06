// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_chorus_mix.c — 多重奏抽头混音验收
 *
 * 覆盖：
 *   - voices=1 / 延迟 0 时为无损旁通；
 *   - N 份等间隔延迟抽头按帧对齐求和（含历史环回绕）；
 *   - 增益缩放与 [-1, 1] 硬限幅；
 *   - 多声道各通道独立（不串声道）；
 *   - 单脉冲在 N 个延迟位置各出现一次；
 *   - 128 份 × 长间隔在真实容量下不越界且限幅。
 */

#include "../src/chorus_mix.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#define CHECK(cond, msg)                                                   \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);  \
            fails++;                                                       \
        }                                                                  \
    } while (0)

static int fails = 0;

static void fill_pattern(float *buf, size_t n, unsigned seed)
{
    unsigned s = seed ? seed : 1u;
    for (size_t i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        buf[i] = (float)((double)(s >> 8) / 8388608.0 - 1.0);
    }
}

static int feq(float a, float b, float eps)
{
    return fabsf(a - b) <= eps;
}

/* voices=1 且 step 任意、gain=1：应与环内当前帧逐样本一致（含回绕）。 */
static void test_passthrough(void)
{
    enum { CAP = 16, CH = 1, FRAMES = 12 };
    float hist[CAP * CH];
    float out[FRAMES * CH];
    float expect[FRAMES * CH];
    size_t base = 16 + 12; /* 故意让块跨过环尾回绕 */
    fill_pattern(hist, CAP * CH, 0xA1u);
    for (unsigned f = 0; f < FRAMES; f++)
        expect[f] = hist[(base + f) & (CAP - 1)];
    memcpy(out, expect, sizeof(out));

    chorus_mix_taps(hist, CAP, base, FRAMES, CH, 1, 5, 1.0f, out);

    for (unsigned f = 0; f < FRAMES; f++) {
        CHECK(feq(out[f], expect[f], 1e-7f), "voices=1 应无损旁通");
    }
}

/* voices=2 / step=2 / gain=0.5：out[n] = (x[n] + x[n-2]) / 2，跨环回绕正确。 */
static void test_two_voices_sum(void)
{
    enum { CAP = 32, CH = 1, FRAMES = 20 };
    float hist[CAP * CH];
    float out[FRAMES * CH];
    size_t base = 32 + 25;
    fill_pattern(hist, CAP * CH, 0xB2u);

    memset(out, 0, sizeof(out));
    chorus_mix_taps(hist, CAP, base, FRAMES, CH, 2, 2, 0.5f, out);

    for (unsigned f = 0; f < FRAMES; f++) {
        float want = 0.5f * (hist[(base + f) & (CAP - 1)] +
                             hist[(base + f - 2) & (CAP - 1)]);
        CHECK(feq(out[f], want, 1e-6f), "两抽头求和/缩放不符");
    }
}

/* 预缩放后超过 ±1 必须硬限幅。 */
static void test_clamp(void)
{
    enum { CAP = 8, FRAMES = 4 };
    float hist[CAP];
    float out[FRAMES];
    for (int i = 0; i < CAP; i++) hist[i] = (i & 1) ? -1.5f : 1.5f;

    memset(out, 0, sizeof(out));
    chorus_mix_taps(hist, CAP, 0, FRAMES, 1, 1, 1, 1.0f, out);
    for (unsigned f = 0; f < FRAMES; f++) {
        CHECK(out[f] <= 1.0f && out[f] >= -1.0f, "正向限幅失败");
        CHECK(feq(out[f], (f & 1) ? -1.0f : 1.0f, 1e-6f), "限幅值不符");
    }

    /* 128 份全 1：0.85/sqrt(128)*128 ≈ 9.6，必须收敛到 1.0。 */
    {
        enum { BIG = 4096, N = 128, STEP = 48, FR = 64 };
        static float bh[BIG];
        static float bo[FR];
        for (int i = 0; i < BIG; i++) bh[i] = 1.0f;
        memset(bo, 0, sizeof(bo));
        chorus_mix_taps(bh, BIG, BIG - FR, FR, 1, N, STEP,
                        0.85f / sqrtf((float)N), bo);
        for (unsigned f = 0; f < FR; f++)
            CHECK(feq(bo[f], 1.0f, 1e-6f), "128 份叠加应限幅到 1.0");
    }
}

/* 左右通道各自独立：左 0.5 / 右 -0.5，3 份 step=1 / gain=1/3 → 原值。 */
static void test_channels_independent(void)
{
    enum { CAP = 64, CH = 2, FRAMES = 10 };
    float hist[CAP * CH];
    float out[FRAMES * CH];
    size_t base = 64 + 7;
    for (int i = 0; i < CAP; i++) {
        hist[i * CH + 0] = 0.5f;
        hist[i * CH + 1] = -0.5f;
    }
    memset(out, 0, sizeof(out));
    chorus_mix_taps(hist, CAP, base, FRAMES, CH, 3, 1, 1.0f / 3.0f, out);

    for (unsigned f = 0; f < FRAMES; f++) {
        CHECK(feq(out[f * CH + 0], 0.5f, 1e-6f), "左声道不应被右声道影响");
        CHECK(feq(out[f * CH + 1], -0.5f, 1e-6f), "右声道不应被左声道影响");
    }
}

/* 单脉冲输入：N 份应以 step 间隔各出现一次（每份增益一致）。 */
static void test_impulse_delays(void)
{
    enum { CAP = 256, FRAMES = 64, VOICES = 4, STEP = 5 };
    const size_t impulse_at = 100; /* 已写入历史环的脉冲位置 */
    float hist[CAP];
    float out[FRAMES];
    const float gain = 0.5f;
    memset(hist, 0, sizeof(hist));
    hist[impulse_at] = 1.0f;
    memset(out, 0, sizeof(out));

    /* base=96：voice 0 读到 96..159，voice 3 读到 81..144，四份都覆盖脉冲。 */
    chorus_mix_taps(hist, CAP, 96, FRAMES, 1, VOICES, STEP, gain, out);

    for (unsigned f = 0; f < FRAMES; f++) {
        const size_t pos = 96 + f;
        int hits = 0;
        for (int v = 0; v < VOICES; v++) {
            if (pos == impulse_at + (size_t)v * STEP) hits++;
        }
        const float want = hits ? gain : 0.0f;
        CHECK(feq(out[f], want, 1e-6f), "脉冲延迟位置/幅度不符");
    }
}

int main(void)
{
    test_passthrough();
    test_two_voices_sum();
    test_clamp();
    test_channels_independent();
    test_impulse_delays();

    if (fails) {
        fprintf(stderr, "%d check(s) failed\n", fails);
        return 1;
    }
    printf("ALL PASS test_chorus_mix\n");
    return 0;
}

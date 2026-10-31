// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_channel_merge.c — 多声道合并（单侧设备兜底）验收
 *
 * 覆盖：
 *   - 生产线 C API（`channel_merge_*`，HAS_ARCHOERA_KERNEL 时路由内核）默认
 *     逐位旁通、单声道输入空操作、立体声/多声道等功率合并；
 *   - 内核 `zk_dsp_channel_merge_*` 与纯 C 参考（tests/dsp_ref/channel_merge_ref.c）
 *     逐块对照；
 *   - 非法声道数防护。
 */

#include "../include/kernel_bridge.h"
#include "../src/channel_merge.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── 纯 C 参考实现（tests/dsp_ref/channel_merge_ref.c，符号前缀 dspref_cm_）── */
ChannelMerge *dspref_cm_create(int channels);
void dspref_cm_set_enabled(ChannelMerge *cm, bool enabled);
void dspref_cm_process(ChannelMerge *cm, float *pcm, int samples);
void dspref_cm_destroy(ChannelMerge *cm);

#define N_FRAMES 2048
#define N_CH 2
#define N_SAMPLES (N_FRAMES * N_CH)

static void fill_signal(float *buf, int n, unsigned seed)
{
    unsigned s = seed ? seed : 1u;
    for (int i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        buf[i] = (float)((double)(s >> 8) / 8388608.0 - 1.0);
    }
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

/* ── 默认禁用：逐位旁通 ────────────────────────────────────── */

static void test_passthrough(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0xABu);
    memcpy(b, a, sizeof(a));

    ChannelMerge *cm = channel_merge_create(N_CH);
    CHECK(cm != NULL, "channel_merge_create failed");
    if (!cm) return;

    channel_merge_process(cm, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "默认禁用非逐位一致");

    channel_merge_destroy(cm);
}

/* ── 单声道输入：空操作 ───────────────────────────────────── */

static void test_mono_noop(void)
{
    float a[N_FRAMES], b[N_FRAMES];
    fill_signal(a, N_FRAMES, 0x11u);
    memcpy(b, a, sizeof(a));

    ChannelMerge *cm = channel_merge_create(1);
    CHECK(cm != NULL, "create(1) failed");
    if (!cm) return;

    channel_merge_set_enabled(cm, true);
    channel_merge_process(cm, a, N_FRAMES);
    CHECK(memcmp(a, b, sizeof(a)) == 0, "单声道输入未保持逐位一致");

    channel_merge_destroy(cm);
}

/* ── 立体声：单侧内容复制到两侧 ───────────────────────────── */

static void test_stereo_merge(void)
{
    enum { FRAMES = 8 };
    float a[FRAMES * 2];
    for (int i = 0; i < FRAMES; i++) {
        a[i * 2] = (float)(i + 1) * 0.05f; /* L 有内容 */
        a[i * 2 + 1] = 0.0f;              /* R 静音 */
    }

    ChannelMerge *cm = channel_merge_create(2);
    CHECK(cm != NULL, "create(2) failed");
    if (!cm) return;

    channel_merge_set_enabled(cm, true);
    channel_merge_process(cm, a, FRAMES);

    const float g = (float)(1.0 / sqrt(2.0));
    for (int i = 0; i < FRAMES; i++) {
        const float expected = (float)(i + 1) * 0.05f * g;
        CHECK(fabsf(a[i * 2] - expected) < 1e-6f, "L 合并错误 frame=%d", i);
        CHECK(fabsf(a[i * 2 + 1] - expected) < 1e-6f, "R 未复制到同相内容 frame=%d", i);
    }

    channel_merge_destroy(cm);
}

/* ── 多声道：按 1/√N 求和 ─────────────────────────────────── */

static void test_multichannel_merge(void)
{
    enum { CH = 6, FRAMES = 4 };
    float a[FRAMES * CH];
    for (int i = 0; i < FRAMES * CH; i++) a[i] = (float)(i + 1) * 0.01f;

    ChannelMerge *cm = channel_merge_create(CH);
    CHECK(cm != NULL, "create(6) failed");
    if (!cm) return;

    channel_merge_set_enabled(cm, true);
    channel_merge_process(cm, a, FRAMES);

    const float g = (float)(1.0 / sqrt(6.0));
    for (int i = 0; i < FRAMES; i++) {
        float sum = 0.0f;
        for (int c = 0; c < CH; c++) sum += (float)(i * CH + c + 1) * 0.01f;
        const float expected = sum * g;
        for (int c = 0; c < CH; c++) {
            CHECK(fabsf(a[i * CH + c] - expected) < 1e-6f,
                  "多声道合并错误 frame=%d ch=%d", i, c);
        }
    }

    channel_merge_destroy(cm);
}

/* ── 非法参数：创建失败 ─────────────────────────────────────── */

static void test_invalid_args(void)
{
    CHECK(channel_merge_create(0) == NULL, "create(0) 应失败");
    CHECK(channel_merge_create(-1) == NULL, "create(-1) 应失败");
    CHECK(channel_merge_create(65) == NULL, "create(65) 应失败");
}

/* ── 内核 vs 纯 C 参考 ─────────────────────────────────────── */

#if defined(HAS_ARCHOERA_KERNEL)
static void test_kernel_vs_c(void)
{
    float a[N_SAMPLES], b[N_SAMPLES];
    fill_signal(a, N_SAMPLES, 0x1234u);
    memcpy(b, a, sizeof(a));

    ChannelMerge *cref = dspref_cm_create(N_CH);
    ZkDspChannelMerge *zk = zk_dsp_channel_merge_create(N_CH);
    CHECK(cref != NULL && zk != NULL, "create failed");
    if (!cref || !zk) {
        if (cref) dspref_cm_destroy(cref);
        if (zk) zk_dsp_channel_merge_destroy(zk);
        return;
    }

    dspref_cm_set_enabled(cref, true);
    zk_dsp_channel_merge_set_enabled(zk, 1);
    dspref_cm_process(cref, a, N_FRAMES);
    zk_dsp_channel_merge_process(zk, b, N_FRAMES);

    const double diff = max_abs_diff(a, b, N_SAMPLES);
    printf("  kernel vs C max_abs_diff=%.3e\n", diff);
    CHECK(diff <= 1e-6, "内核与纯 C 不一致（max_abs_diff=%.3e）", diff);

    dspref_cm_destroy(cref);
    zk_dsp_channel_merge_destroy(zk);
}
#endif

int main(void)
{
    printf("test_channel_merge\n");
    test_passthrough();
    test_mono_noop();
    test_stereo_merge();
    test_multichannel_merge();
    test_invalid_args();
#if defined(HAS_ARCHOERA_KERNEL)
    test_kernel_vs_c();
#endif

    if (fails == 0) {
        printf("ALL PASS\n");
        return 0;
    }
    fprintf(stderr, "%d failure(s)\n", fails);
    return 1;
}

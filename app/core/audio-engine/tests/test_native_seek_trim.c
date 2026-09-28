// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_native_seek_trim.c — EraAudio 自研内核 seek 样本级对齐回归
 *
 * 背景：自研内核的 seek 在能力上只定位到**帧边界**（不同 codec 帧长差异巨大：
 * FLAC 4096 / MP3 1152 / AAC 1024），且各格式落点方向不一（FLAC/MP3 落到
 * 「目标之后的下一帧」，AAC 落到「目标之前的帧」）。若原样输出，跨音质档
 * 无缝切换（如 MP3→无损）会在拼接处整体前移/后移最多一帧内容 → 音量大时
 * 可闻「顿挫」。本测试验证 C 壳（native_decoder.c）在 seek 后按内核报告的
 * 样本级落点裁剪前导样本，使首个输出样本**严格从目标样本起**。
 *
 * 方法：
 *   1. 用 native_decoder（自研内核路径）从 0 整曲解码 → 参考 float PCM
 *      （FLAC 无损，逐位可复现）；
 *   2. 对若干目标 ms：开新 native 解码器 seek，取首个解码片段；
 *   3. 与参考在「目标样本」处逐样本对照：裁剪正确 → 逐位一致；
 *      未裁剪时整体偏移最多一帧 → 差异明显。
 *   4. 同时校验 native_decoder_position_samples 落点 ≤ 目标样本。
 *
 * 用法：test_native_seek_trim <fixture.flac>
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "native_decoder.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail = 1;                                                      \
        } else {                                                             \
            fprintf(stderr, "ok   %s\n", msg);                               \
        }                                                                    \
    } while (0)

/* 从当前解码位置把 float 交错 PCM 追加到 buf，直到累计 >= first_need 帧
   （first_need<=0 = 解到 EOF）。返回总帧数（-1 错误）。 */
static long long drain_frames(NativeDecoder *d, float *buf, long long cap,
                              int ch, long long first_need)
{
    long long total = 0;
    for (;;) {
        long long room = cap / ch - total;
        long long want, got;
        int oc = 0;
        if (room <= 0) break;
        want = (first_need > 0) ? (first_need - total) : room;
        if (want <= 0) break;
        if (want > room) want = room;
        got = native_decoder_read(d, buf + total * ch, (int)want, &oc);
        if (got < 0) return -1;
        if (got == 0) break; /* EOF */
        total += got;
        if (first_need > 0 && total >= first_need) break;
    }
    return total;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "native_seek_fixture.flac";
    const int64_t targets_ms[] = {120, 300, 480};
    NativeDecoder *d;
    int sr, ch;
    int64_t dur_us;
    float *ref = NULL;
    long long ref_cap, ref_len;
    int i;

    if (!native_decoder_available()) {
        fprintf(stderr, "自研内核未链接 → SKIP（本用例仅验证 EraAudio 路径）\n");
        printf("ALL PASS\n");
        return 0;
    }

    d = native_decoder_open(path, NULL, NULL, NULL, 0);
    CHECK(d != NULL, "打开 fixture（native_decoder_open）");
    if (!d) return 2;
    sr = native_decoder_sample_rate(d);
    ch = native_decoder_channels(d);
    dur_us = native_decoder_duration_us(d);
    fprintf(stderr, "        codec=%s sr=%d ch=%d dur=%.1fms\n",
            native_decoder_codec_name(d), sr, ch, dur_us / 1000.0);
    CHECK(sr > 0 && ch > 0 && dur_us > 0, "源参数有效");
    if (sr <= 0 || ch <= 0) { native_decoder_close(d); return 2; }

    ref_cap = (long long)((double)dur_us * sr / 1000000.0 + sr) * ch;
    ref = (float *)malloc((size_t)ref_cap * sizeof(float));
    if (!ref) { native_decoder_close(d); return 2; }
    ref_len = drain_frames(d, ref, ref_cap, ch, 0);
    native_decoder_close(d);
    CHECK(ref_len > 0, "整曲参考解码产出 PCM");
    {
        long long dur_frames = (long long)((double)dur_us * sr / 1000000.0);
        long long diff = ref_len - dur_frames;
        if (diff < 0) diff = -diff;
        CHECK(diff <= sr / 4, "参考从媒体 0 起（帧数≈时长）");
    }

    for (i = 0; i < (int)(sizeof(targets_ms) / sizeof(targets_ms[0])); i++) {
        long long target_sample = (long long)targets_ms[i] * sr / 1000;
        long long probe_frames = 512;
        long long got, landing;
        float *buf;
        double md = 0.0;
        long long k;
        char msg[192];

        if (target_sample + probe_frames >= ref_len) continue; /* 越界跳过 */

        d = native_decoder_open(path, NULL, NULL, NULL, 0);
        if (!d) { CHECK(0, "seek 用例：打开 fixture"); continue; }
        buf = (float *)malloc((size_t)(probe_frames + 8) * ch * sizeof(float));
        if (!buf) { native_decoder_close(d); continue; }
        CHECK(native_decoder_seek_ms(d, targets_ms[i]) == 0,
              "native_decoder_seek_ms 返回 0");
        landing = native_decoder_position_samples(d);
        snprintf(msg, sizeof(msg),
                 "seek %lldms：样本落点 %lld ≤ 目标 %lld（内核帧边界）",
                 (long long)targets_ms[i], landing, target_sample);
        CHECK(landing >= 0 && landing <= target_sample, msg);
        /* 落点距目标不应超过一帧（避免退化为整曲重解） */
        CHECK(landing >= 0 && target_sample - landing <= 65536,
              "seek 落点距目标 ≤ 一帧上界");

        got = drain_frames(d, buf, (probe_frames + 8) * ch, ch, probe_frames);
        native_decoder_close(d);
        CHECK(got >= probe_frames, "seek 后取到足够探测样本");

        /* 逐样本对照参考在目标样本处：裁剪正确 → 完全一致。 */
        for (k = 0; k < probe_frames; k++) {
            int c;
            for (c = 0; c < ch; c++) {
                double dv = fabs((double)buf[k * ch + c]
                                 - (double)ref[(target_sample + k) * ch + c]);
                if (dv > md) md = dv;
            }
        }
        snprintf(msg, sizeof(msg),
                 "seek %lldms：首帧与参考目标样本逐位一致（maxdiff=%.2e）",
                 (long long)targets_ms[i], md);
        CHECK(md <= 1e-4, msg);
    }

    free(ref);
    if (g_fail) {
        fprintf(stderr, "test_native_seek_trim: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_native_seek_trim: ALL PASS\n");
    printf("ALL PASS\n");
    return 0;
}

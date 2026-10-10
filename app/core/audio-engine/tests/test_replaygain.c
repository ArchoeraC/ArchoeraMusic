// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_replaygain.c — FFmpeg 解码器 ReplayGain 元数据提取回归
 *
 * 验证 [decoder_replaygain] 从容器/流 metadata 读出 REPLAYGAIN_* 标签：
 *   - 含标签的 fixture：四个字段（track/album gain+peak）全部命中且数值正确；
 *   - 不含标签的 fixture：位掩码为 0（不误报）。
 *
 * 用法：test_replaygain <with_rg.flac> <without_rg.flac>
 */

#include <math.h>
#include <stdio.h>

#include "decoder.h"

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

static int approx(float a, float b, float eps) { return fabsf(a - b) <= eps; }

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <with_rg.flac> <without_rg.flac>\n", argv[0]);
        return 2;
    }

    /* 1. 含 ReplayGain 标签：四字段全部命中且数值正确。 */
    Decoder *d = decoder_open(argv[1]);
    CHECK(d != NULL, "decoder_open(with_rg)");
    if (!d) return 1;

    float tg = -123.0f, tp = -1.0f, ag = -123.0f, ap = -1.0f;
    int mask = decoder_replaygain(d, &tg, &tp, &ag, &ap);
    CHECK((mask & 0x1) != 0, "track_gain present");
    CHECK((mask & 0x2) != 0, "track_peak present");
    CHECK((mask & 0x4) != 0, "album_gain present");
    CHECK((mask & 0x8) != 0, "album_peak present");
    CHECK(approx(tg, -7.89f, 1e-3f), "track_gain == -7.89 dB");
    CHECK(approx(tp, 0.999023f, 1e-5f), "track_peak == 0.999023");
    CHECK(approx(ag, -8.00f, 1e-3f), "album_gain == -8.00 dB");
    CHECK(approx(ap, 0.987654f, 1e-5f), "album_peak == 0.987654");
    fprintf(stderr, "     mask=0x%x tg=%.3f tp=%.6f ag=%.3f ap=%.6f\n",
            mask, tg, tp, ag, ap);
    decoder_close(d);

    /* 2. 不含标签：掩码为 0，输出保持调用方初值。 */
    Decoder *e = decoder_open(argv[2]);
    CHECK(e != NULL, "decoder_open(without_rg)");
    if (e) {
        float x = -123.0f, y = -1.0f, z = -123.0f, w = -1.0f;
        int m2 = decoder_replaygain(e, &x, &y, &z, &w);
        CHECK(m2 == 0, "no replaygain tags -> mask == 0");
        CHECK(x == -123.0f && z == -123.0f, "outputs untouched when absent");
        decoder_close(e);
    }

    if (g_fail) {
        fprintf(stderr, "FAILED\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}

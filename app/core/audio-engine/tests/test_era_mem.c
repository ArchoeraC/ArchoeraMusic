// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* EraAudio 纯内存源解码冒烟（docs/audio-memory-source.md §7）：
 * 把 fixture 读入连续内存 → native_decoder_open_mem 打开 → 全量读帧，
 * 与 native_decoder_open(路径) 对拍帧数/采样率/声道。证明自研内核已接入
 * 「纯内存源」解码（此前 store 源一律回退 FFmpeg，属残血态）。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "native_decoder.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg); \
            g_fail++;                                                   \
        } else {                                                        \
            fprintf(stderr, "ok   %s\n", msg);                          \
        }                                                               \
    } while (0)

static unsigned char *read_all(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    unsigned char *buf = (unsigned char *)malloc((size_t)n);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

/* 全量读帧；返回累计帧数，<0 = 解码错误 */
static long drain(NativeDecoder *d)
{
    float out[4096 * 8];
    long total = 0;
    int ch = 0;
    for (;;) {
        int n = native_decoder_read(d, out, 4096, &ch);
        if (n < 0) return -1;
        if (n == 0) break;
        total += n;
    }
    return total;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <audio>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    size_t len = 0;
    unsigned char *buf = read_all(path, &len);
    if (!buf) { fprintf(stderr, "read %s failed\n", path); return 2; }

    char err[256];
    NativeInfo mi;
    int st = 0;

    /* 路径后端（参照系） */
    NativeDecoder *pd = native_decoder_open(path, &mi, &st, err, sizeof(err));
    if (!pd) {
        free(buf);
        fprintf(stderr, "SKIP: 内核未接管 %s (status=%d %s)\n", path, st, err);
        return 0; /* 未接管 → 交由 FFmpeg 回退，本用例不适用 */
    }
    long pf = drain(pd);
    int prate = native_decoder_sample_rate(pd);
    int pch = native_decoder_channels(pd);
    native_decoder_close(pd);

    /* 内存后端（新增路径） */
    NativeInfo mi2;
    int st2 = 0;
    char err2[256];
    NativeDecoder *md = native_decoder_open_mem(buf, len, &mi2, &st2, err2, sizeof(err2));
    CHECK(md != NULL, "native_decoder_open_mem 打开成功");
    if (!md) {
        fprintf(stderr, "    status=%d %s\n", st2, err2);
        free(buf);
        return g_fail ? 1 : 0;
    }
    long mf = drain(md);
    int mrate = native_decoder_sample_rate(md);
    int mch = native_decoder_channels(md);
    native_decoder_close(md);
    free(buf);

    CHECK(mf > 0, "内存源解码帧数 > 0");
    CHECK(mf == pf, "内存源帧数与路径后端一致");
    CHECK(mrate == prate && mch == pch, "采样率/声道与路径后端一致");

    if (g_fail == 0) fprintf(stderr, "ALL PASS\n");
    return g_fail ? 1 : 0;
}

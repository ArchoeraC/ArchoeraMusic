// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* EraAudio 宿主回调流解码冒烟（docs/audio-kernel-zig.md §6.1/§7）：
 * 把 fixture 字节放在内存里，经 native_decoder_open_cb(宿主 read/seek 回调)
 * 打开 → 全量读帧，与 native_decoder_open(路径) 对拍**解码 PCM 逐样本** +
 * 帧数/采样率/声道；再验证 seek 后仍能继续解码。证明「在线流式源」已能进入
 * 自研内核（此前 URL 源一律回退 FFmpeg，属残血态），且 callback seek 的
 * `off - buffered` 语义正确。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "native_decoder.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail++;                                                        \
        } else {                                                             \
            fprintf(stderr, "ok   %s\n", msg);                               \
        }                                                                    \
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

/* 逐样本累积的 PCM（float 交错） */
typedef struct {
    float *data;
    size_t n;
    size_t cap;
} Pcm;

static void pcm_free(Pcm *b) { free(b->data); b->data = NULL; b->n = b->cap = 0; }

static int pcm_push(Pcm *b, const float *src, size_t n)
{
    if (b->n + n > b->cap) {
        size_t nc = b->cap ? b->cap : 65536;
        while (nc < b->n + n) nc *= 2;
        float *p = (float *)realloc(b->data, nc * sizeof(float));
        if (!p) return -1;
        b->data = p;
        b->cap = nc;
    }
    memcpy(b->data + b->n, src, n * sizeof(float));
    b->n += n;
    return 0;
}

/* 全量读帧并累积 PCM；返回累计帧数，<0 = 解码错误 */
static long drain(NativeDecoder *d, Pcm *b)
{
    static float out[4096 * 8];
    long total = 0;
    int ch = 0;
    for (;;) {
        int n = native_decoder_read(d, out, 4096, &ch);
        if (n < 0) return -1;
        if (n == 0) break;
        if (pcm_push(b, out, (size_t)n * (size_t)(ch > 0 ? ch : 1)) != 0) return -1;
        total += n;
    }
    return total;
}

typedef struct {
    const unsigned char *data;
    size_t len;
    size_t pos; /* 底层流位置（= 内核逻辑游标 + peek 缓冲内未消费字节） */
} CbCtx;

static size_t cb_read(void *ctx, unsigned char *buf, size_t len)
{
    CbCtx *c = (CbCtx *)ctx;
    if (c->pos >= c->len) return 0; /* EOF */
    size_t n = c->len - c->pos;
    if (n > len) n = len;
    memcpy(buf, c->data + c->pos, n);
    c->pos += n;
    return n;
}

static int cb_seek(void *ctx, long long off, int whence, size_t buffered)
{
    CbCtx *c = (CbCtx *)ctx;
    long long base;
    switch (whence) {
    case 0: base = 0; break;                                        /* start */
    case 1: base = (long long)c->pos - (long long)buffered; break;  /* current */
    case 2: base = (long long)c->len; break;                        /* end */
    default: return 0;
    }
    long long np = base + off;
    if (np < 0 || np > (long long)c->len) return 0;
    c->pos = (size_t)np;
    return 1;
}

static int pcm_equal(const Pcm *a, const Pcm *b)
{
    return a->n == b->n && a->data && b->data &&
           memcmp(a->data, b->data, a->n * sizeof(float)) == 0;
}

static int run_case(const char *path)
{
    size_t len = 0;
    unsigned char *buf = read_all(path, &len);
    if (!buf) {
        fprintf(stderr, "SKIP: 读取失败 %s\n", path);
        return 0;
    }

    char err[256];
    NativeInfo mi;
    int st = 0;

    /* 路径后端（参照系）；未接管 → 跳过（该格式由 FFmpeg 负责） */
    NativeDecoder *pd = native_decoder_open(path, &mi, &st, err, sizeof(err));
    if (!pd) {
        fprintf(stderr, "SKIP: 内核未接管 %s (status=%d %s)\n", path, st, err);
        free(buf);
        return 0;
    }
    Pcm pb = {0};
    long pf = drain(pd, &pb);
    int prate = native_decoder_sample_rate(pd);
    int pch = native_decoder_channels(pd);
    native_decoder_close(pd);


    /* 回调流后端（新增路径） */
    CbCtx ctx = { .data = buf, .len = len, .pos = 0 };
    NativeInfo mi2;
    int st2 = 0;
    char err2[256];
    NativeDecoder *cd = native_decoder_open_cb(&ctx, cb_read, cb_seek,
                                               (unsigned long long)len,
                                               &mi2, &st2, err2, sizeof(err2));
    CHECK(cd != NULL, "native_decoder_open_cb 打开成功");
    if (!cd) {
        fprintf(stderr, "    status=%d %s\n", st2, err2);
        pcm_free(&pb);
        free(buf);
        return 0;
    }
    Pcm cb = {0};
    long cf = drain(cd, &cb);
    int crate = native_decoder_sample_rate(cd);
    int cch = native_decoder_channels(cd);

    CHECK(cf > 0, "回调源解码帧数 > 0");
    CHECK(cf == pf, "回调源帧数与路径后端一致");
    CHECK(crate == prate && cch == pch, "采样率/声道与路径后端一致");
    CHECK(pcm_equal(&pb, &cb), "解码 PCM 与路径后端逐样本一致");

    /* seek 后仍可继续解码（EOF 后 seek 回起点 → 应重新产出帧） */
    CHECK(native_decoder_seek_ms(cd, 0) == 0, "回调源 seek 到 0ms 成功");
    static float one[4096 * 8];
    int ch = 0;
    int n = native_decoder_read(cd, one, 4096, &ch);
    CHECK(n > 0, "回调源 seek 后仍能解码出帧");

    native_decoder_close(cd);
    pcm_free(&cb);
    pcm_free(&pb);
    free(buf);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <audio> [audio ...]\n", argv[0]);
        return 2;
    }
    for (int i = 1; i < argc; i++) {
        fprintf(stderr, "--- case: %s ---\n", argv[i]);
        run_case(argv[i]);
    }
    if (g_fail == 0) fprintf(stderr, "ALL PASS\n");
    return g_fail ? 1 : 0;
}

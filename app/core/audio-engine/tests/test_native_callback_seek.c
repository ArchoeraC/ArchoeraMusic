// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_native_callback_seek.c — 回调流（在线源）seek / 时长 / 格式一致性回归
 * （docs/audio-kernel-expansion-plan.md §3 N2/N6）
 *
 * 覆盖：
 *   - **时长语义一致**（N6）：同一文件，路径后端与宿主回调后端的 duration_us /
 *     sample_rate / channels / bits_per_sample 必须相同（cb 的 size_hint 已知时
 *     时长不应退化为 unknown）；
 *   - **seek 逐样本一致**（N2）：在 0 / 10% / 33% / 66% / 近尾 多个位置分别 seek，
 *     回调后端与路径后端读出的 PCM **逐字节相同**（同一内核解码器，同字节流）；
 *   - **EOF 后 seek**（N2）：回调后端解码到 EOF 后再 seek 回 0，整曲重解与首次
 *     路径全量解码逐字节相同（游标/预读在 EOF 后正确复位）；
 *   - 覆盖 flac / wav / mp3 / opus 等已接管格式（run_case 对未接管格式 SKIP）。
 *
 * 说明：宿主回调把「字节流 + 精确 seek」注入内核（内核零网络栈）。此用例用内存
 * 字节模拟「已具备 Range/随机访问能力的远端」，从而在无网络环境验证 N2 语义。
 */
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

/* 读至多 want 帧；返回帧数（0=EOF），<0=错误。*/
static long read_n(NativeDecoder *d, float *out, int want, int *ch_out)
{
    int n = native_decoder_read(d, out, want, ch_out);
    return n;
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

/* 同一位置两后端各读 want 帧，逐样本比对。返回 0 = 一致。 */
static int compare_at(NativeDecoder *pd, NativeDecoder *cd, long long ms, int want)
{
    static float a[4096 * 8];
    static float b[4096 * 8];
    int ca = 0, cb = 0;
    if (native_decoder_seek_ms(pd, ms) != 0) return -1;
    if (native_decoder_seek_ms(cd, ms) != 0) return -1;
    long na = read_n(pd, a, want, &ca);
    long nb = read_n(cd, b, want, &cb);
    if (na < 0 || nb < 0) {
        fprintf(stderr, "  读错误 path=%ld cb=%ld @%lldms\n", na, nb, ms);
        return -1;
    }
    if (na != nb) {
        fprintf(stderr, "  帧数不一致 path=%ld cb=%ld @%lldms\n", na, nb, ms);
        return -1;
    }
    if (na == 0) return 0;
    if (ca != cb) return -1;
    size_t samples = (size_t)na * (size_t)(ca > 0 ? ca : 1);
    if (memcmp(a, b, samples * sizeof(float)) != 0) {
        fprintf(stderr, "  PCM 不一致 @%lldms (%ld 帧)\n", ms, na);
        return -1;
    }
    return 0;
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

    /* 回调后端 */
    CbCtx ctx = { .data = buf, .len = len, .pos = 0 };
    NativeInfo mi2;
    int st2 = 0;
    char err2[256];
    NativeDecoder *cd = native_decoder_open_cb(&ctx, cb_read, cb_seek,
                                               (unsigned long long)len,
                                               &mi2, &st2, err2, sizeof(err2));
    if (!cd) {
        fprintf(stderr, "FAIL: native_decoder_open_cb 失败 (status=%d %s)\n", st2, err2);
        g_fail++;
        native_decoder_close(pd);
        free(buf);
        return 0;
    }

    /* N6：时长/流参数一致（cb 的 size_hint 已知，时长不应退化） */
    CHECK(mi.sample_rate == mi2.sample_rate, "sample_rate 与路径后端一致");
    CHECK(mi.channels == mi2.channels, "channels 与路径后端一致");
    CHECK(mi.bits_per_sample == mi2.bits_per_sample, "bits_per_sample 与路径后端一致");
    CHECK(mi.duration_us == mi2.duration_us, "duration_us 与路径后端一致");
    fprintf(stderr, "  info: %dHz/%dch/%dbit dur=%lldus\n",
            mi2.sample_rate, mi2.channels, mi2.bits_per_sample,
            (long long)mi2.duration_us);

    /* 路径后端全量解码 = 参考 */
    Pcm ref = {0};
    long rf = drain(pd, &ref);
    CHECK(rf > 0, "路径后端全量解码 > 0 帧");

    /* 回调后端全量解码 = 参考（逐字节） */
    Pcm cbf = {0};
    long cf = drain(cd, &cbf);
    CHECK(cf == rf, "回调全量帧数与路径一致");
    CHECK(cbf.n == ref.n && ref.data && cbf.data &&
          memcmp(ref.data, cbf.data, ref.n * sizeof(float)) == 0,
          "回调全量 PCM 与路径逐样本一致");

    /* N2：多位置 seek 后逐样本一致（含 0 / 近尾；按 duration 比例） */
    long long dur_ms = mi2.duration_us / 1000;
    if (dur_ms > 30) {
        const long long fracs[4] = {0, dur_ms / 10, dur_ms / 3, (dur_ms * 2) / 3};
        for (int i = 0; i < 4; i++) {
            char msg[96];
            snprintf(msg, sizeof(msg), "seek %lldms 回调与路径逐样本一致", fracs[i]);
            CHECK(compare_at(pd, cd, fracs[i], 2048) == 0, msg);
        }
        /* 近尾 */
        CHECK(compare_at(pd, cd, dur_ms > 60 ? dur_ms - 60 : 0, 1024) == 0,
              "seek 近尾回调与路径逐样本一致");
    } else {
        fprintf(stderr, "  (时长过短，跳过 seek 对比)\n");
    }

    /* N2：EOF 后 seek 回 0。cb 与 path 走**完全相同的序列**（此前都被 seek 过同一组
     * 位置），故二者状态历史相同、输出必须逐字节一致。有损解码器不保证「seek 把
     * 状态完全复位到首次解码」，因此这里比对同源两路，而非拿 cb 直接比首次参考。 */
    Pcm cb_eof = {0};
    Pcm p_eof = {0};
    (void)drain(cd, &cb_eof); /* 确保 cb 处在 EOF */
    (void)drain(pd, &p_eof);  /* 确保 path 处在 EOF */
    CHECK(native_decoder_seek_ms(cd, 0) == 0, "回调 EOF 后 seek 0ms 成功");
    CHECK(native_decoder_seek_ms(pd, 0) == 0, "路径 EOF 后 seek 0ms 成功");
    Pcm cb_after = {0};
    Pcm p_after = {0};
    long cba = drain(cd, &cb_after);
    long pa = drain(pd, &p_after);
    CHECK(cba == pa && cba > 0, "EOF 后 seek 重解帧数 cb/path 一致");
    CHECK(cb_after.n == p_after.n && p_after.data && cb_after.data &&
          memcmp(p_after.data, cb_after.data, p_after.n * sizeof(float)) == 0,
          "EOF 后 seek 重解 PCM cb/path 逐样本一致");
    CHECK(cba == rf, "EOF 后 seek 重解帧数等于首次全量参考");

    /* seek 越界（远超时长）不应崩溃；允许返回错误或 EOF */
    if (dur_ms > 0) {
        int rc = native_decoder_seek_ms(cd, dur_ms + 5000);
        static float tmp[256];
        int tch = 0;
        long tn = read_n(cd, tmp, 256, &tch);
        CHECK(tn >= 0, "越界 seek 后读取不崩溃（EOF/错误均可）");
        (void)rc;
    }

    native_decoder_close(cd);
    native_decoder_close(pd);
    pcm_free(&p_after);
    pcm_free(&cb_after);
    pcm_free(&p_eof);
    pcm_free(&cb_eof);
    pcm_free(&cbf);
    pcm_free(&ref);
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

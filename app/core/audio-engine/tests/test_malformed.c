// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_malformed.c — 损坏文件 / 恶意越界 健壮性回归（headless）
 *
 * 目标：内核面对**畸形输入**与**恶意越界调用**时只返回错误/EOF，绝不崩溃/挂起。
 * 覆盖：
 *   1. 截断文件（0/1/8/64/半长/末-1 字节）：open 允许失败；成功则解码有界；
 *   2. 错误魔数 / 随机字节：open 必须失败返回 NULL（不崩溃）；
 *   3. 恶意 seek：INT64_MIN / INT64_MAX / 负值 / 远超时长；随后 read 有界；
 *   4. 头部 fuzz-lite：随机翻转头 64 字节，open+read 有界不崩溃；
 *   5. 流式 seam（池）：畸形文件 open/seek/read/close 全程不崩溃。
 *
 * 用法：test_malformed <file1> [file2 ...]
 */
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kernel_bridge.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail = 1;                                                      \
        }                                                                    \
    } while (0)

static unsigned char *read_file(const char *p, long *n)
{
    FILE *f = fopen(p, "rb");
    if (!f) { *n = 0; return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = (unsigned char *)malloc((size_t)sz + 1);
    size_t got = fread(b, 1, (size_t)sz, f);
    fclose(f);
    b[got] = 0;
    *n = (long)got;
    return b;
}

static void write_file(const char *p, const unsigned char *b, long n)
{
    FILE *f = fopen(p, "wb");
    if (!f) return;
    if (n > 0) fwrite(b, 1, (size_t)n, f);
    fclose(f);
}

/* 有界解码：最多 max_iters 块，断言返回值合法（≤ max_frames 或负错误码） */
static void bounded_decode(ZkDecoder *d, int max_iters)
{
    float buf[4096];
    int ch = 0;
    for (int i = 0; i < max_iters; i++) {
        long long n = zk_decoder_read(d, buf, 2048, &ch);
        CHECK(n <= 2048, "read frames <= max_frames");
        if (n <= 0) break;
    }
}

/* 1+2+4：截断 / 错误魔数 / 头部 fuzz-lite（sync 内核） */
static void test_sync(const char *path, const unsigned char *full, long fsz)
{
    char err[128];
    ZkInfo info;

    /* 截断 */
    const long cuts[] = { 0, 1, 8, 64, fsz / 2, fsz > 0 ? fsz - 1 : 0 };
    for (unsigned k = 0; k < sizeof(cuts) / sizeof(cuts[0]); k++) {
        long n = cuts[k] < 0 ? 0 : cuts[k];
        if (n > fsz) n = fsz;
        char tmp[256];
        snprintf(tmp, sizeof(tmp), "/tmp/opencode/mal_cut_%ld", n);
        write_file(tmp, full, n);
        ZkDecoder *d = zk_decoder_open(tmp, &info, err, sizeof(err));
        if (d) { bounded_decode(d, 64); zk_decoder_close(d); }
    }

    /* 错误魔数 / 随机字节 */
    {
        unsigned char junk[256];
        for (int i = 0; i < 256; i++) junk[i] = (unsigned char)(i * 7 + 13);
        write_file("/tmp/opencode/mal_junk", junk, sizeof(junk));
        ZkDecoder *d = zk_decoder_open("/tmp/opencode/mal_junk", &info, err, sizeof(err));
        CHECK(d == NULL, "random junk → open 失败");
        if (d) zk_decoder_close(d);
    }

    /* 头部 fuzz-lite：翻转头 64 字节 */
    if (fsz > 64) {
        unsigned char *copy = (unsigned char *)malloc((size_t)fsz);
        memcpy(copy, full, (size_t)fsz);
        unsigned seed = 0x1234;
        for (int it = 0; it < 200; it++) {
            seed = seed * 1103515245u + 12345u;
            int off = (int)((seed >> 8) % 64);
            seed = seed * 1103515245u + 12345u;
            copy[off] ^= (unsigned char)(seed >> 16);
            write_file("/tmp/opencode/mal_fuzz", copy, fsz);
            ZkDecoder *d = zk_decoder_open("/tmp/opencode/mal_fuzz", &info, err, sizeof(err));
            if (d) { bounded_decode(d, 16); zk_decoder_close(d); }
            copy[off] ^= (unsigned char)(seed >> 16); /* 还原 */
        }
        free(copy);
    }

    /* 3：恶意 seek（有效文件） */
    {
        ZkDecoder *d = zk_decoder_open(path, &info, err, sizeof(err));
        if (d) {
            const long long seeks[] = { LLONG_MIN, LLONG_MAX, -1000, 0,
                                        (long long)info.duration_us / 1000 + 100000 };
            for (unsigned k = 0; k < sizeof(seeks) / sizeof(seeks[0]); k++) {
                int rc = zk_decoder_seek_ms(d, seeks[k]);
                (void)rc; /* 允许失败 */
                bounded_decode(d, 8);
            }
            zk_decoder_close(d);
        }
    }
}

/* 5：流式 seam（池）畸形/越界 */
static void test_stream(const char *path, const char *cut_path)
{
    char err[128];
    ZkInfo info;
    ZkEngine *h = zk_engine_init_streams(1, 4, 64, 8);
    CHECK(h != NULL, "engine init");
    if (!h) return;

    /* 畸形文件 open 允许失败 */
    ZkEngineStream *s = zk_engine_open(h, cut_path, &info, err, sizeof(err));
    if (s) {
        float buf[4096]; int ch = 0;
        for (int i = 0; i < 32; i++) { long long n = zk_engine_read(s, buf, 2048, &ch); if (n <= 0) break; }
        zk_engine_close(s);
    }

    /* 有效文件 + 恶意 seek */
    s = zk_engine_open(h, path, &info, err, sizeof(err));
    if (s) {
        const long long seeks[] = { LLONG_MIN, LLONG_MAX, -1, LLONG_MAX / 2,
                                    (long long)info.duration_us / 1000 * 10 };
        float buf[4096]; int ch = 0;
        for (unsigned k = 0; k < sizeof(seeks) / sizeof(seeks[0]); k++) {
            zk_engine_seek_ms(s, seeks[k]);
            for (int i = 0; i < 4; i++) { long long n = zk_engine_read(s, buf, 2048, &ch); if (n <= 0) break; }
        }
        zk_engine_close(s);
    }
    zk_engine_shutdown(h);
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [file...]\n", argv[0]); return 2; }

    for (int a = 1; a < argc; a++) {
        long fsz = 0;
        unsigned char *full = read_file(argv[a], &fsz);
        if (!full || fsz <= 0) { free(full); continue; }
        fprintf(stderr, "-- malformed: %s (%ld bytes)\n", argv[a], fsz);
        test_sync(argv[a], full, fsz);
        test_stream(argv[a], "/tmp/opencode/mal_cut_64");
        free(full);
    }

    if (g_fail) { fprintf(stderr, "FAILED\n"); return 1; }
    printf("ALL PASS\n");
    return 0;
}

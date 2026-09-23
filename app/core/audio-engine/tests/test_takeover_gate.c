// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_takeover_gate.c — 方向③ F5「接管门控」C ABI 验收
 *
 * 覆盖：
 *   1. 静态接管位图 `zk_takeover_bitmap()` 与逐格式判定 `zk_takeover_of_format()`
 *      按 `probe.Format` 枚举序**逐位一致**（含越界安全）；`unknown` 恒未接管；
 *   2. 扩展名判定 `zk_takeover_of_ext()`：已知接管/未接管/未知三态 + 大小写；
 *   3. C 壳门控 `native_decoder_taken_over_by_ext()` 对真实路径取扩展名；
 *   4. 接管命中/未命中计数 `native_decoder_stats()` 随 open 结果递增；
 *   5. `pipeline_backend()`：未接管 mov → "ffmpeg"，已接管 flac → "zig"。
 *
 * probe.Format 枚举序（kernel/probe.zig）——顺序敏感，改动须同步本文件：
 *   0 ogg_opus 1 ogg_vorbis 2 ogg_flac 3 ogg_speex 4 flac 5 wav 6 mp3 7 m4a
 *   8 aac 9 latm 10 ape 11 wv 12 shn 13 tak 14 dsd 15 amr 16 amrwb 17 ac3
 *   18 mlp 19 truehd 20 wma 21 dts 22 mka 23 mpc 24 tta 25 unknown
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/kernel_bridge.h"
#include "../include/audio_engine.h"
#include "../src/native_decoder.h"

#define FMT_FLAC    4
#define FMT_AC3     17
#define FMT_DTS     21
#define FMT_UNKNOWN 25
#define FMT_COUNT   26

static int g_fail = 0;
#define CHECK(cond, msg)                                                   \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);  \
            g_fail = 1;                                                    \
        } else {                                                           \
            fprintf(stderr, "ok   %s\n", msg);                             \
        }                                                                  \
    } while (0)

static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

/* 建管线取 backend（不 process，仅验证解码后端选择），拷回调用方缓冲。 */
static void backend_of(const char *path, char *out, size_t cap)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    cfg.engine_mode = 1;      /* EraAudio：优先自研内核 */
    cfg.skip_encoder = true;  /* 纯解码，无 Opus 输出 */
    AudioPipeline *p = pipeline_create(path, &cfg, dummy_output, NULL);
    if (!p) {
        snprintf(out, cap, "<create-failed>");
        return;
    }
    snprintf(out, cap, "%s", pipeline_backend(p));
    pipeline_destroy(p);
}

static void check_bitmap_and_format(void)
{
    unsigned long long bm = zk_takeover_bitmap();
    for (int i = 0; i < FMT_COUNT; i++) {
        int f = zk_takeover_of_format(i);
        unsigned long long bit = (bm >> i) & 1ULL;
        if (f != (int)bit) {
            fprintf(stderr, "FAIL %s:%d  bitmap/format 不一致 i=%d bit=%llu f=%d\n",
                    __FILE__, __LINE__, i, bit, f);
            g_fail = 1;
        }
    }
    CHECK(zk_takeover_of_format(FMT_UNKNOWN) == 0, "unknown 恒未接管");
    CHECK(zk_takeover_of_format(-1) == 0, "format 越界(-1) → 0");
    CHECK(zk_takeover_of_format(FMT_COUNT) == 0, "format 越界(count) → 0");
    fprintf(stderr, "ok   bitmap 与 of_format 全 %d 索引一致 (bitmap=0x%llx)\n",
            FMT_COUNT, bm);
}

static void check_ext(void)
{
    CHECK(zk_takeover_of_ext(".flac") == 1, ".flac → 1（已接管）");
    CHECK(zk_takeover_of_ext("flac") == 1, "flac 无前导点 → 1");
    CHECK(zk_takeover_of_ext(".FLAC") == 1, "扩展名大小写不敏感");
    CHECK(zk_takeover_of_ext(".m4a") == zk_takeover_of_format(7), ".m4a 随开关");
    CHECK(zk_takeover_of_ext(".dts") == zk_takeover_of_format(FMT_DTS), ".dts 随开关");
    CHECK(zk_takeover_of_ext(".ac3") == zk_takeover_of_format(FMT_AC3), ".ac3 随开关");
    CHECK(zk_takeover_of_ext(".xyz") == -1, "未知扩展名 → -1");
    CHECK(zk_takeover_of_ext("") == -1, "空扩展名 → -1");
    CHECK(zk_takeover_of_ext(".ogg") == -1, "容器歧义(.ogg) → -1（保留 try）");
}

static void check_c_gate(const char *mov)
{
    CHECK(native_decoder_taken_over_by_ext("/music/a.flac") == 1, "路径 .flac → 1");
    CHECK(native_decoder_taken_over_by_ext("/music/a.FLAC") == 1, "路径大小写 → 1");
    CHECK(native_decoder_taken_over_by_ext("http://h/a.flac") == 1, "URL .flac → 1");
    CHECK(native_decoder_taken_over_by_ext("http://h/a.dtshd?x=1") == -1,
          "URL 含查询串 → -1（保守）");
    CHECK(native_decoder_taken_over_by_ext("/music/noext") == -1, "无扩展名 → -1");
    CHECK(native_decoder_taken_over_by_ext(NULL) == -1, "NULL → -1");
    if (mov) {
        /* mov 不在 ext→Format 表：unknown（保留 try-then-fallback），
         * native 仍会尝试并失败 → backend 回退 ffmpeg（见 check_backend）。 */
        int v = native_decoder_taken_over_by_ext(mov);
        CHECK(v == -1, "表外容器(.mov) → -1（unknown，保留 try）");
    }
}

static void check_counters(const char *flac, const char *mov)
{
    long long a0 = 0, h0 = 0, u0 = 0, a1 = 0, h1 = 0, u1 = 0;

    native_decoder_stats(&a0, &h0, &u0);
    {
        NativeInfo ni;
        int st = -1;
        char eb[256];
        NativeDecoder *d = native_decoder_open(flac, &ni, &st, eb, sizeof(eb));
        if (!d) {
            fprintf(stderr, "FAIL native_decoder_open(flac) 失败 st=%d %s\n", st, eb);
            g_fail = 1;
        } else {
            native_decoder_close(d);
        }
    }
    native_decoder_stats(&a1, &h1, &u1);
    CHECK(a1 == a0 + 1, "命中：attempts +1");
    CHECK(h1 == h0 + 1, "命中：hits +1");
    CHECK(u1 == u0, "命中：misses 不变");

    native_decoder_stats(&a0, &h0, &u0);
    {
        NativeInfo ni;
        int st = -1;
        char eb[256];
        NativeDecoder *d = native_decoder_open(mov, &ni, &st, eb, sizeof(eb));
        CHECK(d == NULL && st == 1, "未接管文件 open → NULL + ZK_UNSUPPORTED");
        if (d) native_decoder_close(d);
    }
    native_decoder_stats(&a1, &h1, &u1);
    CHECK(a1 == a0 + 1, "未命中：attempts +1");
    CHECK(h1 == h0, "未命中：hits 不变");
    CHECK(u1 == u0 + 1, "未命中：misses +1");
}

static void check_backend(const char *flac, const char *mov)
{
    char b[32];
    backend_of(flac, b, sizeof(b));
    CHECK(strcmp(b, "zig") == 0, "已接管 flac → backend=zig");
    backend_of(mov, b, sizeof(b));
    CHECK(strcmp(b, "ffmpeg") == 0, "未接管 mov → backend=ffmpeg");
}

int main(int argc, char **argv)
{
    const char *flac = (argc > 1) ? argv[1] : NULL;
    const char *mov = (argc > 2) ? argv[2] : NULL;

    check_bitmap_and_format();
    check_ext();
    check_c_gate(mov);
    if (flac && mov) {
        check_counters(flac, mov);
        check_backend(flac, mov);
    } else {
        fprintf(stderr, "skip 计数器/backend：未提供 flac+mov fixture\n");
    }

    if (g_fail) {
        fprintf(stderr, "test_takeover_gate: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_takeover_gate: ALL PASS\n");
    return 0;
}

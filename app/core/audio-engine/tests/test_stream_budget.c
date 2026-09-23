// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/*
 * test_stream_budget.c — N4 流式 Reader 缓冲预算 C ABI 回归
 *
 *   - 默认每路 16 KiB、预算不限；
 *   - set/peek 夹取到 [16 KiB, 64 KiB]；
 *   - 预算不足 → cb 流（池内 + sync 直通）拒绝打开，账目回滚；
 *   - 预算充足 → 打开后已用 = 每路缓冲，关闭后归零。
 * 结束打印 ALL PASS。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kernel_bridge.h"

#define FRAMES 16

/* 8kHz mono i16 0..15 WAV（44 字节头 + 32 字节数据 = 76 字节） */
static void gold_wav(unsigned char out[76]) {
    unsigned char hdr[] = {
        'R','I','F','F', 0x34,0x00,0x00,0x00, 'W','A','V','E',
        'f','m','t',' ', 0x10,0x00,0x00,0x00,
        0x01,0x00, 0x01,0x00, 0x40,0x1f,0x00,0x00,
        0x80,0x3e,0x00,0x00, 0x02,0x00, 0x10,0x00,
        'd','a','t','a', 0x20,0x00,0x00,0x00
    };
    memcpy(out, hdr, sizeof hdr);
    for (int i = 0; i < FRAMES; i++) {
        int16_t s = (int16_t)i;
        memcpy(out + 44 + 2 * i, &s, 2);
    }
}

typedef struct { const unsigned char *data; size_t len; size_t pos; } CbCtx;

static size_t cb_read(void *ctx, unsigned char *buf, size_t len) {
    CbCtx *c = (CbCtx *)ctx;
    if (c->pos >= c->len) return 0;
    size_t n = c->len - c->pos;
    if (n > len) n = len;
    memcpy(buf, c->data + c->pos, n);
    c->pos += n;
    return n;
}

static int cb_seek(void *ctx, long long off, int whence, size_t buffered) {
    CbCtx *c = (CbCtx *)ctx;
    long long base;
    switch (whence) {
    case 0: base = 0; break;
    case 1: base = (long long)c->pos - (long long)buffered; break;
    case 2: base = (long long)c->len; break;
    default: return 0;
    }
    long long np = base + off;
    if (np < 0 || np > (long long)c->len) return 0;
    c->pos = (size_t)np;
    return 1;
}

int main(void) {
    /* 默认值 */
    if (zk_stream_peek_bytes() != 16384) {
        fprintf(stderr, "default peek should be 16384, got %u\n", zk_stream_peek_bytes());
        return 1;
    }

    /* 夹取 */
    zk_stream_peek_set_bytes(32768);
    if (zk_stream_peek_bytes() != 32768) { fprintf(stderr, "peek set 32768 failed\n"); return 1; }
    zk_stream_peek_set_bytes(1024);
    if (zk_stream_peek_bytes() != 16384) { fprintf(stderr, "peek min clamp failed: %u\n", zk_stream_peek_bytes()); return 1; }
    zk_stream_peek_set_bytes(1u << 20);
    if (zk_stream_peek_bytes() != 65536) { fprintf(stderr, "peek max clamp failed: %u\n", zk_stream_peek_bytes()); return 1; }
    zk_stream_peek_set_bytes(16384);
    printf("peek default/set/clamp OK\n");

    unsigned long long used0 = zk_stream_mem_used();

    unsigned char wav[76];
    gold_wav(wav);
    ZkInfo info;
    char eb[64];
    memset(&info, 0, sizeof info);
    memset(eb, 0, sizeof eb);

    ZkEngine *h = zk_engine_init(1, 2, 4);
    if (!h) { fprintf(stderr, "zk_engine_init failed\n"); return 1; }

    /* 预算不足（< 每路 16 KiB）→ 池内 cb 流拒绝打开，账目回滚 */
    zk_stream_mem_set_budget(8192);
    {
        CbCtx c = { wav, sizeof wav, 0 };
        ZkEngineStream *s = zk_engine_open_cb(h, &c, cb_read, cb_seek, sizeof wav,
                                              &info, eb, sizeof eb);
        if (s != NULL) {
            fprintf(stderr, "over-budget cb stream should be rejected\n");
            zk_engine_close(s); zk_stream_mem_set_budget(0);
            zk_engine_shutdown(h); return 1;
        }
        if (zk_stream_mem_used() != used0) {
            fprintf(stderr, "over-budget reject must roll back accounting\n");
            zk_stream_mem_set_budget(0); zk_engine_shutdown(h); return 1;
        }
    }
    printf("over-budget cb reject + rollback OK\n");

    /* 预算不限 → 打开成功，已用 = 每路，关闭归零 */
    zk_stream_mem_set_budget(0);
    {
        CbCtx c = { wav, sizeof wav, 0 };
        ZkEngineStream *s = zk_engine_open_cb(h, &c, cb_read, cb_seek, sizeof wav,
                                              &info, eb, sizeof eb);
        if (!s) {
            int code = (int)((unsigned char)eb[0] | ((unsigned char)eb[1] << 8) |
                             ((unsigned char)eb[2] << 16) | ((unsigned char)eb[3] << 24));
            fprintf(stderr, "cb stream open failed (status=%d, used=%llu)\n",
                    code, zk_stream_mem_used());
            zk_engine_shutdown(h); return 1;
        }
        if (zk_stream_mem_used() != used0 + 16384) {
            fprintf(stderr, "expected used=%llu, got %llu\n", used0 + 16384, zk_stream_mem_used());
            zk_engine_close(s); zk_engine_shutdown(h); return 1;
        }
        zk_engine_close(s);
        if (zk_stream_mem_used() != used0) {
            fprintf(stderr, "accounting should return to baseline after close, got %llu\n", zk_stream_mem_used());
            zk_engine_shutdown(h); return 1;
        }
    }
    printf("engine cb accounting (open→used, close→zero) OK\n");

    /* sync 直通 cb 路径（zk_decoder_open_cb）同样计入预算 */
    zk_stream_mem_set_budget(4096);
    {
        CbCtx c = { wav, sizeof wav, 0 };
        ZkDecoder *d = zk_decoder_open_cb(&c, cb_read, cb_seek, sizeof wav, &info, eb, sizeof eb);
        if (d != NULL) {
            fprintf(stderr, "over-budget sync cb should be rejected\n");
            zk_decoder_close(d); zk_stream_mem_set_budget(0);
            zk_engine_shutdown(h); return 1;
        }
    }
    zk_stream_mem_set_budget(0);
    {
        CbCtx c = { wav, sizeof wav, 0 };
        ZkDecoder *d = zk_decoder_open_cb(&c, cb_read, cb_seek, sizeof wav, &info, eb, sizeof eb);
        if (!d) { fprintf(stderr, "sync cb open failed\n"); zk_engine_shutdown(h); return 1; }
        if (zk_stream_mem_used() != used0 + 16384) {
            fprintf(stderr, "sync cb used mismatch: %llu\n", zk_stream_mem_used());
            zk_decoder_close(d); zk_engine_shutdown(h); return 1;
        }
        zk_decoder_close(d);
        if (zk_stream_mem_used() != used0) {
            fprintf(stderr, "sync cb accounting should return to baseline\n");
            zk_engine_shutdown(h); return 1;
        }
    }
    printf("sync cb accounting + over-budget reject OK\n");

    zk_engine_shutdown(h);
    printf("ALL PASS\n");
    return 0;
}

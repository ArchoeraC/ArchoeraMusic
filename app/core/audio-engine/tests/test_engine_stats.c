// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/*
 * test_engine_stats.c — AS6 可观测聚合（zk_engine_stats）C ABI 回归
 *
 *   - 固定容量 (min=max=2) 初始化后计数精确：active/spawn/idle/stall/fail 可断言；
 *   - 开/关一个流式会话 → stream_count 1/0；
 *   - h/out 为 NULL 时安全空操作。
 * 结束打印 ALL PASS。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kernel_bridge.h"

#define FRAMES 16
#define SR 8000

static int write_gold_wav(const char *path) {
    unsigned char hdr[] = {
        'R','I','F','F', 0x34,0x00,0x00,0x00, 'W','A','V','E',
        'f','m','t',' ', 0x10,0x00,0x00,0x00,
        0x01,0x00, 0x01,0x00, 0x40,0x1f,0x00,0x00,
        0x80,0x3e,0x00,0x00, 0x02,0x00, 0x10,0x00,
        'd','a','t','a', 0x20,0x00,0x00,0x00
    };
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(hdr, 1, sizeof(hdr), f);
    for (int i = 0; i < FRAMES; i++) {
        int16_t s = (int16_t)i;
        fwrite(&s, 2, 1, f);
    }
    fclose(f);
    return 0;
}

int main(void) {
    const char *path = "zkstats_test.wav";
    if (write_gold_wav(path) != 0) { fprintf(stderr, "cannot write wav\n"); return 1; }

    ZkEngine *h = zk_engine_init(2, 2, 8);
    if (!h) { fprintf(stderr, "zk_engine_init failed\n"); remove(path); return 1; }

    ZkEngineStats st;
    memset(&st, 0, sizeof st);
    zk_engine_stats(h, &st);
    if (st.active != 2 || st.spawn_count != 2 || st.stall_count != 0 ||
        st.spawn_failed_count != 0 || st.stream_count != 0 ||
        st.inflight != 0 || st.running != 0 || st.idle != 2) {
        fprintf(stderr,
                "unexpected initial stats: active=%llu spawn=%llu idle=%llu stall=%llu "
                "fail=%llu stream=%llu inflight=%llu running=%llu\n",
                st.active, st.spawn_count, st.idle, st.stall_count,
                st.spawn_failed_count, st.stream_count, st.inflight, st.running);
        zk_engine_shutdown(h); remove(path); return 1;
    }
    printf("initial stats exact (active=2 spawn=2 idle=2) OK\n");

    /* NULL 安全：h/out 任一为空 → 空操作，不得崩溃 */
    zk_engine_stats(NULL, &st);
    zk_engine_stats(h, NULL);

    /* 流计数并入聚合 */
    ZkInfo info;
    char eb[64];
    memset(&info, 0, sizeof info);
    memset(eb, 0, sizeof eb);
    ZkEngineStream *s = zk_engine_open(h, path, &info, eb, sizeof eb);
    if (!s) { fprintf(stderr, "zk_engine_open failed\n"); zk_engine_shutdown(h); remove(path); return 1; }
    if (info.sample_rate != SR) { fprintf(stderr, "stream info sr=%d\n", info.sample_rate); zk_engine_close(s); zk_engine_shutdown(h); remove(path); return 1; }
    zk_engine_stats(h, &st);
    if (st.stream_count != 1) {
        fprintf(stderr, "stream_count should be 1, got %llu\n", st.stream_count);
        zk_engine_close(s); zk_engine_shutdown(h); remove(path); return 1;
    }
    zk_engine_close(s);
    zk_engine_stats(h, &st);
    if (st.stream_count != 0) {
        fprintf(stderr, "stream_count should be 0 after close, got %llu\n", st.stream_count);
        zk_engine_shutdown(h); remove(path); return 1;
    }
    printf("stream_count aggregate 1→0 OK\n");

    zk_engine_shutdown(h);
    remove(path);
    printf("ALL PASS\n");
    return 0;
}

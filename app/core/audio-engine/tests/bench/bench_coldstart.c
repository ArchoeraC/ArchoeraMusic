// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// bench_coldstart.c — 引擎「冷/热启动 → 首帧」基准（headless，无声卡）。
//
// 口径（同一 C 壳，苹果对苹果），每项拆两段：
//   create = pipeline_create（打开解码器 + 建重采样/DSP/缓冲）；
//   first  = 首次 pipeline_process 产出数据块（解码首帧）。
// 场景：
//   - EraAudio 冷：常驻池 begin(含 init) + create + first（应用每会话真实付出）；
//   - EraAudio 热：池已就绪，create + first；
//   - Stable(FFmpeg)：create + first（FFmpeg 无常驻池，冷=热）。
// 交错测量（每轮 era/stable 交换先后）以消顺序/热漂移。用法: bench_coldstart FILE [N]
#define _POSIX_C_SOURCE 199309L
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "audio_engine.h"
#include "native_decoder.h"

static long long now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
static int dummy_output(const uint8_t *d, size_t s, void *u) {
    (void)d; (void)s; (void)u;
    return 0;
}
static int cmp_ll(const void *a, const void *b) {
    long long x = *(const long long *)a, y = *(const long long *)b;
    return (x > y) - (x < y);
}
static void stats(const char *tag, long long *v, int n) {
    qsort(v, (size_t)n, sizeof(long long), cmp_ll);
    long long sum = 0;
    for (int i = 0; i < n; i++) sum += v[i];
    printf("%s p50=%lld p90=%lld mean=%lld\n", tag, v[n / 2], v[(int)(0.9 * (n - 1))], sum / n);
}

/* create + 首帧；分别输出两段 µs（失败置 -1） */
static void create_and_first(int mode, const char *path, long long *create_us, long long *first_us) {
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    cfg.engine_mode = mode;
    cfg.skip_encoder = true;
    cfg.output_sample_rate = 0;
    long long t = now_us();
    AudioPipeline *p = pipeline_create(path, &cfg, dummy_output, NULL);
    *create_us = now_us() - t;
    if (!p) { *create_us = -1; *first_us = -1; return; }
    pipeline_set_playback_streaming(p, true); /* 真首帧：一次 process ≈ 一块 */
    long long t2 = now_us();
    long long f = -1;
    for (int i = 0; i < 100000; i++) {
        ssize_t n = pipeline_process(p);
        if (n < 0) break;
        if (n > 0) { f = now_us() - t2; break; }
    }
    pipeline_destroy(p);
    *first_us = f;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s FILE [N]\n", argv[0]); return 2; }
    const char *path = argv[1];
    int N = (argc > 2) ? atoi(argv[2]) : 30;
    if (N < 1) N = 1;

    long long *hc = malloc(sizeof(long long) * (size_t)N); /* era hot create */
    long long *hf = malloc(sizeof(long long) * (size_t)N); /* era hot first  */
    long long *sc = malloc(sizeof(long long) * (size_t)N); /* stable create  */
    long long *sf = malloc(sizeof(long long) * (size_t)N); /* stable first   */
    long long *cc = malloc(sizeof(long long) * (size_t)N); /* era cold create(含 begin) */
    long long *cf = malloc(sizeof(long long) * (size_t)N); /* era cold first */
    long long inits[64];

    /* 预热（含两路各 3 次） */
    { long long a, b; for (int i = 0; i < 3; i++) { create_and_first(1, path, &a, &b); create_and_first(0, path, &a, &b); } }

    /* 池 init 单独测（begin→end→begin） */
    int M = N < 64 ? N : 64;
    for (int i = 0; i < M; i++) {
        native_decoder_pool_end();
        long long t = now_us();
        native_decoder_pool_begin(1, 2, 16);
        inits[i] = now_us() - t;
    }
    native_decoder_pool_end();

    /* 热：交错（交替先后） */
    native_decoder_pool_begin(1, 2, 16);
    for (int i = 0; i < N; i++) {
        if (i & 1) { create_and_first(0, path, &sc[i], &sf[i]); create_and_first(1, path, &hc[i], &hf[i]); }
        else       { create_and_first(1, path, &hc[i], &hf[i]); create_and_first(0, path, &sc[i], &sf[i]); }
    }
    native_decoder_pool_end();

    /* 冷：每次 begin(含 init)+create+首帧 */
    for (int i = 0; i < N; i++) {
        native_decoder_pool_end();
        long long t0 = now_us();
        native_decoder_pool_begin(1, 2, 16);
        long long cr, f;
        create_and_first(1, path, &cr, &f);
        cc[i] = now_us() - t0;   /* 含 begin(init)+create */
        cf[i] = f;
    }
    native_decoder_pool_end();

    printf("RESULT file=%s N=%d\n", path, N);
    stats("RESULT pool_init", inits, M);
    printf("RESULT --- EraAudio hot ---\n");
    stats("RESULT era hot create", hc, N);
    stats("RESULT era hot first-frame", hf, N);
    printf("RESULT --- Stable/FFmpeg ---\n");
    stats("RESULT stable create", sc, N);
    stats("RESULT stable first-frame", sf, N);
    printf("RESULT --- EraAudio cold (begin+create) ---\n");
    stats("RESULT era cold begin+create", cc, N);
    stats("RESULT era cold first-frame", cf, N);
    free(hc); free(hf); free(sc); free(sf); free(cc); free(cf);
    return 0;
}

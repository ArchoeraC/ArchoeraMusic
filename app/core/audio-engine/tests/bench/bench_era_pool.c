// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

// ArchoeraMusic Audio Framework · bench_era_pool.c
// 常驻内核池（ZkEngine）并发解码基准（headless：静音、无设备）。
// 用法：
//   bench_era_pool HOST_MAX FILE...       并发解码（pthread 数 = FILE 数，各开一个流式会话
//                                         读到 EOF，丢弃 PCM 只计数）→ 打印 RESULT 行
//   bench_era_pool -latency FILE          冷/热首帧：引擎 init 后首次 open+read 首块 vs 第二次
#define _POSIX_C_SOURCE 199309L
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "kernel_bridge.h"

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static long long now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

typedef struct { const char *path; long long frames; } Job;
static ZkEngine *g_host = NULL;

static void *dec_one(void *arg) {
    Job *j = (Job *)arg;
    char eb[64];
    ZkInfo info;
    ZkEngineStream *s = zk_engine_open(g_host, j->path, &info, eb, sizeof eb);
    if (!s) { j->frames = -1; return NULL; }
    float buf[4096 * 8];
    long long f = 0;
    for (;;) {
        int ch = 0;
        long long n = zk_engine_read(s, buf, 4096, &ch);
        if (n < 0) { f = n; break; }
        if (n == 0) break;
        f += n;
    }
    zk_engine_close(s);
    j->frames = f;
    return NULL;
}

static int cmp_ll(const void *a, const void *b) {
    long long x = *(const long long *)a, y = *(const long long *)b;
    return (x > y) - (x < y);
}
static long long pct(const long long *v, int n, double p) {
    int i = (int)(p * (n - 1) + 0.5);
    if (i < 0) i = 0; if (i >= n) i = n - 1;
    return v[i];
}
static void print_stats(const char *tag, long long *v, int n) {
    qsort(v, (size_t)n, sizeof(long long), cmp_ll);
    long long sum = 0; for (int i = 0; i < n; i++) sum += v[i];
    printf("%s p50=%lld p90=%lld p99=%lld mean=%lld\n", tag,
           pct(v, n, 0.50), pct(v, n, 0.90), pct(v, n, 0.99), sum / n);
}

int main(int argc, char **argv) {
    int latency = 0;
    int host_max = 1;
    int base = 1;
    int max_streams = 0; /* 0 = 跟随 host_max（压测用） */
    if (argc > 1 && strcmp(argv[1], "-bench") == 0) {
        /* 稳态往返统计：预热后 N 次「open+首读+close」，池化 vs sync（µs 分位） */
        if (argc < 4) { fprintf(stderr, "usage: %s -bench FILE N\n", argv[0]); return 2; }
        const char *p = argv[2];
        int N = atoi(argv[3]);
        if (N < 1) N = 1;
        char eb[64]; ZkInfo info; float buf[4096]; int ch = 0;
        long long t = now_us();
        ZkEngine *h = zk_engine_init(1, 4, 64);
        long long t_init = now_us() - t;
        if (!h) { fprintf(stderr, "init fail\n"); return 1; }
        for (int w = 0; w < 3; w++) {
            ZkEngineStream *s = zk_engine_open(h, p, &info, eb, sizeof eb);
            if (s) { zk_engine_read(s, buf, 2048, &ch); zk_engine_close(s); }
        }
        long long *pl = malloc(sizeof(long long) * (size_t)N);
        for (int i = 0; i < N; i++) {
            long long a = now_us();
            ZkEngineStream *s = zk_engine_open(h, p, &info, eb, sizeof eb);
            if (s) { zk_engine_read(s, buf, 2048, &ch); zk_engine_close(s); }
            pl[i] = now_us() - a;
        }
        zk_engine_shutdown(h);
        for (int w = 0; w < 3; w++) {
            ZkDecoder *d = zk_decoder_open(p, &info, eb, sizeof eb);
            if (d) { zk_decoder_read(d, buf, 2048, &ch); zk_decoder_close(d); }
        }
        long long *sl = malloc(sizeof(long long) * (size_t)N);
        for (int i = 0; i < N; i++) {
            long long a = now_us();
            ZkDecoder *d = zk_decoder_open(p, &info, eb, sizeof eb);
            if (d) { zk_decoder_read(d, buf, 2048, &ch); zk_decoder_close(d); }
            sl[i] = now_us() - a;
        }
        printf("RESULT init_us=%lld N=%d\n", t_init, N);
        print_stats("RESULT pool_open+read+close", pl, N);
        print_stats("RESULT sync_open+read+close", sl, N);
        free(pl); free(sl);
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "-us") == 0) {
        /* 微秒级冷启动分解：init / pool open / 首块 / sync open / 首块 */
        if (argc < 3) { fprintf(stderr, "usage: %s -us FILE\n", argv[0]); return 2; }
        const char *p = argv[2];
        long long t = now_us();
        ZkEngine *h = zk_engine_init(1, 4, 64);
        if (!h) { fprintf(stderr, "init fail\n"); return 1; }
        long long t_init = now_us() - t;
        char eb[64]; ZkInfo info;
        t = now_us();
        ZkEngineStream *s = zk_engine_open(h, p, &info, eb, sizeof eb);
        long long t_open = now_us() - t;
        float buf[4096]; int ch = 0;
        t = now_us();
        long long n = s ? zk_engine_read(s, buf, 2048, &ch) : -1;
        long long t_read = now_us() - t;
        if (s) zk_engine_close(s);
        zk_engine_shutdown(h);
        /* sync 直通对照（无池/无线程） */
        t = now_us();
        ZkDecoder *d = zk_decoder_open(p, &info, eb, sizeof eb);
        long long t_sopen = now_us() - t;
        t = now_us();
        long long n2 = d ? zk_decoder_read(d, buf, 2048, &ch) : -1;
        long long t_sread = now_us() - t;
        if (d) zk_decoder_close(d);
        printf("RESULT init_us=%lld pool_open_us=%lld pool_first_read_us=%lld (n=%lld) "
               "sync_open_us=%lld sync_first_read_us=%lld (n=%lld)\n",
               t_init, t_open, t_read, n, t_sopen, t_sread, n2);
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "-latency") == 0) { latency = 1; base = 2; }
    if (argc > base && strcmp(argv[base], "-streams") == 0 && argc > base + 1) {
        max_streams = atoi(argv[base + 1]);
        base += 2;
    }
    if (argc > base && argv[base][0] >= '0' && argv[base][0] <= '9') {
        host_max = atoi(argv[base]);
        base++;
    }
    if (argc - base < 1) { fprintf(stderr, "usage\n"); return 2; }

    if (latency) {
        const char *path = argv[base];
        /* 冷：引擎 init（常驻池）+ open + 首块 read 墙钟 */
        long long t0 = now_ms();
        ZkEngine *h = zk_engine_init(1, 4, 64);
        if (!h) return 1;
        char eb[64];
        ZkInfo info;
        ZkEngineStream *s = zk_engine_open(h, path, &info, eb, sizeof eb);
        if (!s) { fprintf(stderr, "open fail\n"); return 1; }
        float buf[4096];
        int ch = 0;
        long long cold_first = -1;
        long long n = zk_engine_read(s, buf, 2048, &ch);
        if (n > 0) cold_first = now_ms() - t0; /* 含引擎 init */
        /* 热：同一 host 已就绪，再一次 open+首块（不含 init） */
        long long t1 = now_ms();
        ZkEngineStream *s2 = zk_engine_open(h, path, &info, eb, sizeof eb);
        long long n2 = s2 ? zk_engine_read(s2, buf, 2048, &ch) : -1;
        long long warm_first = (s2 && n2 > 0) ? (now_ms() - t1) : -1;
        zk_engine_close(s);
        if (s2) zk_engine_close(s2);
        zk_engine_shutdown(h);
        printf("RESULT cold_first_ms=%lld warm_first_ms=%lld (host init incl in cold)\n",
               cold_first, warm_first);
        return 0;
    }

    /* 并发解码：FILE 数即并发线程数 */
    if (max_streams <= 0) max_streams = host_max;
    ZkEngine *h = zk_engine_init_streams(1, host_max, 256, max_streams);
    if (!h) return 1;
    g_host = h;
    int nf = argc - base;
    Job *jobs = malloc(sizeof(Job) * (size_t)nf);
    pthread_t *th = malloc(sizeof(pthread_t) * (size_t)nf);
    for (int i = 0; i < nf; i++) { jobs[i].path = argv[base + i]; jobs[i].frames = 0; }
    long long t0 = now_ms();
    for (int i = 0; i < nf; i++) pthread_create(&th[i], NULL, dec_one, &jobs[i]);
    for (int i = 0; i < nf; i++) pthread_join(th[i], NULL);
    long long wall = now_ms() - t0;
    long long total = 0;
    int ok = 0;
    for (int i = 0; i < nf; i++) { if (jobs[i].frames >= 0) { total += jobs[i].frames; ok++; } }
    zk_engine_shutdown(h);
    printf("RESULT era concurrency=%d host_max=%d files_ok=%d/%d total_frames=%lld wall_ms=%lld\n",
           nf, host_max, ok, nf, total, wall);
    return ok == nf ? 0 : 1;
}

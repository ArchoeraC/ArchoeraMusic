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

int main(int argc, char **argv) {
    int latency = 0;
    int host_max = 1;
    int base = 1;
    if (argc > 1 && strcmp(argv[1], "-latency") == 0) { latency = 1; base = 2; }
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
    ZkEngine *h = zk_engine_init(1, host_max, 256);
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

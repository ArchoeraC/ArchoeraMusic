// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_scraper_wait.c — archoera_scraper_wait_event 单元测试
 *
 * 覆盖契约（对齐音频引擎 test_mediaengine_wait.c 的语义）：
 *   A. 事件到达立即返回（阻塞唤醒，无轮询延迟）；
 *   B. 无事件 + timeout_ms>=0 → 按时超时返 0（条件变量睡眠，非忙等）；
 *   C. destroy 唤醒阻塞中的 wait_event（返回 -1，无 UAF/无泄漏）；
 *   D. 多次 create/run/destroy/再 create 句柄安全；
 *   E. 空闲等待的 CPU 佐证：进程 CPU 时间远小于墙钟（睡眠而非自旋）。
 *
 * 直接链接 libarchoera_scraper.so（真实导出符号），真实句柄 + 空目录触发
 * empty+done 事件（全程无网络请求）。
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

/* archoera_scraper C ABI（scraper_lib.cpp 内 extern "C" 导出） */
void* archoera_scraper_create(const char* configJson);
int archoera_scraper_run(void* handle);
int archoera_scraper_is_done(void* handle);
const char* archoera_scraper_poll_event(void* handle);
int archoera_scraper_wait_event(void* handle, char* buf, int cap,
                                int timeout_ms);
void archoera_scraper_cancel(void* handle);
void archoera_scraper_destroy(void* handle);

static int g_fail = 0;

#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail = 1;                                                      \
        } else {                                                             \
            fprintf(stderr, "ok   %s\n", msg);                               \
        }                                                                    \
    } while (0)

static long long now_ms(void)
{
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void* make_handle(const char* dir, const char* db)
{
    char cfg[2048];
    snprintf(cfg, sizeof(cfg),
             "{\"dirs\":[\"%s\"],\"scraperDbPath\":\"%s\","
             "\"useMusicBrainz\":false,\"useDeezer\":false,\"useItunes\":false,"
             "\"useNetease\":false,\"useQQMusic\":false,\"useKugou\":false,"
             "\"useKuwo\":false,\"useMigu\":false,\"useAcoustID\":false}",
             dir, db);
    return archoera_scraper_create(cfg);
}

/* 排空事件队列直到空（poll_event 兼容路径仍在用） */
static void drain_events(void* h)
{
    while (archoera_scraper_poll_event(h) != NULL) {
    }
}

/* 等 worker 线程退出（is_done），budget 毫秒 */
static void wait_done(void* h, int ms_budget)
{
    int waited = 0;
    while (!archoera_scraper_is_done(h) && waited < ms_budget) {
        struct timespec ts = {0, 5 * 1000000L};
        nanosleep(&ts, NULL);
        waited += 5;
    }
}

/* ── 测试 C 辅助：独立线程阻塞在 wait_event(-1)，destroy 应唤醒它 ── */
typedef struct {
    void* h;
    char buf[4096];
    int r;
    int finished;
    volatile int about_to_enter; /* 即将调用 wait_event（销毁方等其入阻塞） */
} Waiter;

static void* waiter_fn(void* arg)
{
    Waiter* w = (Waiter*)arg;
    w->about_to_enter = 1;
    w->r = archoera_scraper_wait_event(w->h, w->buf, sizeof(w->buf), -1);
    w->finished = 1;
    return NULL;
}

int main(void)
{
    char workdir[] = "/tmp/archoera-scraper-wait-XXXXXX";
    if (!mkdtemp(workdir)) {
        perror("mkdtemp");
        return 2;
    }
    char dir[512];
    char db[512];
    snprintf(dir, sizeof(dir), "%s/nofiles", workdir);
    snprintf(db, sizeof(db), "%s/scraper-state.db", workdir);
    mkdir(dir, 0755);

    /* ── A：run 后事件即时到达（wait_event 阻塞唤醒，非轮询节拍） ─── */
    void* h = make_handle(dir, db);
    CHECK(h != NULL, "A create");
    if (h) {
        CHECK(archoera_scraper_run(h) == 1, "A run 启动");
        char buf[4096];
        long long t0 = now_ms();
        int r = archoera_scraper_wait_event(h, buf, sizeof(buf), 8000);
        long long dt = now_ms() - t0;
        CHECK(r > 0, "A 事件即时返回 (>0)");
        CHECK(strstr(buf, "\"type\"") != NULL, "A 事件为 JSON 行");
        if (r > 0) fprintf(stderr, "        first event: %.*s (%.0fms)\n",
                           r < 80 ? r : 80, buf, (double)dt);
        CHECK(dt < 3000, "A 到达应即时（<3s，非轮询节拍）");

        /* worker 跑完（empty+done）后排空，制造「无事件」稳态 */
        wait_done(h, 10000);
        drain_events(h);

        /* ── B：超时返 0，且为睡眠等待（CPU 远小于墙钟） ─────── */
        {
            clock_t c0 = clock();
            long long w0 = now_ms();
            int r2 = archoera_scraper_wait_event(h, buf, sizeof(buf), 300);
            long long dt2 = now_ms() - w0;
            double cpu = (double)(clock() - c0) / CLOCKS_PER_SEC;
            CHECK(r2 == 0, "B 超时（无事件）返 0");
            CHECK(dt2 >= 250 && dt2 < 3000,
                  "B 超时按时返回（约 300ms，非忙等暴走）");
            CHECK(cpu < 0.2, "B 阻塞期间 CPU≈0（条件变量睡眠，非轮询自旋）");
            fprintf(stderr, "        timeout elapsed=%lldms cpu=%.0fms\n",
                    dt2, cpu * 1000.0);
        }

        /* ── C：destroy 唤醒阻塞中的 wait_event（返回 -1） ────── */
        {
            pthread_t th;
            Waiter w;
            memset(&w, 0, sizeof(w));
            w.h = h;
            CHECK(pthread_create(&th, NULL, waiter_fn, &w) == 0,
                  "C 派生阻塞等待线程");
            /* 确定性：等线程即将进入 wait_event 再留调度余量，确保其已
               阻塞在条件变量上（destroy 与 wait_event 并发契约的落点） */
            {
                long long t0 = now_ms();
                while (!w.about_to_enter && now_ms() - t0 < 2000) {
                    struct timespec ts = {0, 1 * 1000000L};
                    nanosleep(&ts, NULL);
                }
            }
            {
                struct timespec ts = {0, 50 * 1000000L};
                nanosleep(&ts, NULL);
            }
            CHECK(w.finished == 0, "C 等待线程此刻仍阻塞（未自退）");
            archoera_scraper_destroy(h); /* 应唤醒 + drain + 释放 */
            pthread_join(th, NULL);
            CHECK(w.finished == 1, "C destroy 后等待线程返回");
            CHECK(w.r == -1, "C 等待线程返回 -1（已销毁）");
            h = NULL; /* 已释放 */
        }

        /* ── E：空闲 1.5s 睡眠 CPU 佐证（全新句柄、不 run） ──── */
        if (!h) {
            h = make_handle(dir, db);
            CHECK(h != NULL, "E re-create");
        }
        if (h) {
            char buf[4096];
            clock_t c0 = clock();
            long long w0 = now_ms();
            int r3 = archoera_scraper_wait_event(h, buf, sizeof(buf), 1500);
            long long dt3 = now_ms() - w0;
            double cpu = (double)(clock() - c0) / CLOCKS_PER_SEC;
            CHECK(r3 == 0, "E 静置 1.5s 超时返 0");
            CHECK(dt3 >= 1300 && dt3 < 5000, "E 约 1.5s 返回");
            CHECK(cpu < 0.3, "E 1.5s 静置 CPU≈0（无周期唤醒/自旋）");
            fprintf(stderr, "        idle elapsed=%lldms cpu=%.0fms\n",
                    dt3, cpu * 1000.0);
            archoera_scraper_destroy(h);
            h = NULL;
        }
    }
    if (h) archoera_scraper_destroy(h);

    /* ── D：create/run/destroy/再 create 稳定（无泄漏/无悬垂） ──── */
    for (int i = 0; i < 3; i++) {
        void* h2 = make_handle(dir, db);
        CHECK(h2 != NULL, "D create 循环");
        if (h2) {
            CHECK(archoera_scraper_run(h2) == 1, "D run 循环");
            char buf[4096];
            int r = archoera_scraper_wait_event(h2, buf, sizeof(buf), 8000);
            CHECK(r > 0, "D 新句柄事件可取");
            archoera_scraper_destroy(h2);
        }
    }

    /* 清理临时文件（db + wal/shm + 空目录） */
    remove(db);
    {
        char p[600];
        snprintf(p, sizeof(p), "%s-wal", db);
        remove(p);
        snprintf(p, sizeof(p), "%s-shm", db);
        remove(p);
    }
    rmdir(dir);
    rmdir(workdir);

    if (g_fail) {
        fprintf(stderr, "test_scraper_wait: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_scraper_wait: ALL PASS\n");
    return 0;
}

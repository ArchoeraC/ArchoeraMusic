/**
 * test_mediaengine_wait.c — archoera_mediaengine_wait_event 单元测试
 *
 * 覆盖契约：
 *   A. 事件到达立即返回（阻塞唤醒，无轮询延迟）；
 *   B. 无事件 + timeout_ms>=0 → 按时超时返 0（条件变量睡眠，非忙等）；
 *   C. destroy 唤醒阻塞中的 wait_event（返回 -1，无 UAF/无泄漏）；
 *   D. 多次 create/destroy/再 create 句柄安全；
 *   E. 空闲 1.5s 的 CPU 佐证：进程 CPU 时间远小于墙钟（证明睡眠而非自旋）。
 *
 * 直接编译 mediaengine_lib.c（与 libarchoera_mediaengine.so 同源），
 * 不走 dlopen，便于 ctest 独立运行。
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#include "audio_engine.h"
#include "player.h"
#include "archoera_mediaengine.h"

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

/* 建真实引擎会话（player_file=NULL：不触碰音频输出设备，仅解码出事件）。
   返回句柄；失败打印错误并返回 NULL。 */
static ArchoeraMediaEngine *make_engine(const char *src, const char *sdir,
                                        char *errbuf, int errcap)
{
    ArchoeraMediaEngine *e = archoera_mediaengine_create(
        src, NULL, NULL, sdir, errbuf, errcap);
    if (!e) {
        fprintf(stderr, "create failed: %s\n", errbuf);
    }
    return e;
}

/* 排空事件队列直到空（poll_event 兼容路径仍在用） */
static void drain_events(ArchoeraMediaEngine *e)
{
    char buf[4096];
    while (archoera_mediaengine_poll_event(e, buf, sizeof(buf)) > 0) {
    }
}

/* 等引擎线程退出（is_done）*/
static void wait_done(ArchoeraMediaEngine *e, int ms_budget)
{
    int waited = 0;
    while (!archoera_mediaengine_is_done(e) && waited < ms_budget) {
        struct timespec ts = {0, 5 * 1000000L};
        nanosleep(&ts, NULL);
        waited += 5;
    }
}

/* ── 测试 C 辅助：独立线程阻塞在 wait_event(-1)，destroy 应唤醒它 ── */
typedef struct {
    ArchoeraMediaEngine *e;
    char buf[4096];
    int r;
    int finished;
    volatile int about_to_enter; /* 即将调用 wait_event（销毁方等其入阻塞） */
} Waiter;

static void *waiter_fn(void *arg)
{
    Waiter *w = (Waiter *)arg;
    w->about_to_enter = 1;
    w->r = archoera_mediaengine_wait_event(w->e, w->buf, sizeof(w->buf), -1);
    w->finished = 1;
    return NULL;
}

static void run_case(const char *src)
{
    char sdir[] = "/tmp/archoera-wait-test-XXXXXX";
    if (!mkdtemp(sdir)) {
        perror("mkdtemp");
        exit(2);
    }

    char errbuf[256];

    /* ── A：事件即时到达（blocking 唤醒，非轮询节拍） ─────────── */
    ArchoeraMediaEngine *e = make_engine(src, sdir, errbuf, sizeof(errbuf));
    CHECK(e != NULL, "A create");
    if (e) {
        char buf[4096];
        long long t0 = now_ms();
        int r = archoera_mediaengine_wait_event(e, buf, sizeof(buf), 8000);
        long long dt = now_ms() - t0;
        CHECK(r > 0, "A ready 事件即时返回 (>0)");
        CHECK(strstr(buf, "\"type\":\"ready\"") != NULL,
              "A 首事件为 ready");
        if (r > 0) fprintf(stderr, "        first event: %s (%.0fms)\n",
                           buf, (double)dt);
        CHECK(dt < 3000, "A ready 到达应即时（<3s，非 50ms 轮询节拍）");

        /* 引擎转码小样 → EOF：等线程退出后排空，制造「无事件」稳态 */
        wait_done(e, 10000);
        drain_events(e);

        /* ── B：超时返 0，且为睡眠等待（CPU 远小于墙钟） ─────── */
        {
            clock_t c0 = clock();
            long long w0 = now_ms();
            int r2 = archoera_mediaengine_wait_event(e, buf, sizeof(buf), 300);
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
            w.e = e;
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
            archoera_mediaengine_destroy(e); /* 应唤醒 + drain + 释放 */
            pthread_join(th, NULL);
            CHECK(w.finished == 1, "C destroy 后等待线程返回");
            CHECK(w.r == -1, "C 等待线程返回 -1（已销毁）");
            e = NULL; /* 已释放 */
        }

        /* ── E：空闲 1.5s 睡眠 CPU 佐证（用全新会话验证长静置） ── */
        if (!e) {
            e = make_engine(src, sdir, errbuf, sizeof(errbuf));
            CHECK(e != NULL, "E re-create");
        }
        if (e) {
            wait_done(e, 10000);
            drain_events(e);
            clock_t c0 = clock();
            long long w0 = now_ms();
            int r3 = archoera_mediaengine_wait_event(e, buf, sizeof(buf), 1500);
            long long dt3 = now_ms() - w0;
            double cpu = (double)(clock() - c0) / CLOCKS_PER_SEC;
            CHECK(r3 == 0, "E 静置 1.5s 超时返 0");
            CHECK(dt3 >= 1300 && dt3 < 5000, "E 约 1.5s 返回");
            CHECK(cpu < 0.3, "E 1.5s 静置 CPU≈0（无明显周期唤醒/自旋）");
            fprintf(stderr, "        idle elapsed=%lldms cpu=%.0fms\n",
                    dt3, cpu * 1000.0);
        }
    }

    /* ── D：create/destroy/再 create 稳定（无泄漏/无悬垂） ────── */
    for (int i = 0; i < 5; i++) {
        ArchoeraMediaEngine *e2 = make_engine(src, sdir, errbuf,
                                              sizeof(errbuf));
        CHECK(e2 != NULL, "D create 循环");
        if (e2) {
            char buf[4096];
            int r = archoera_mediaengine_wait_event(e2, buf, sizeof(buf), 8000);
            CHECK(r > 0, "D 新句柄事件可取");
            archoera_mediaengine_destroy(e2);
        }
    }

    if (e) archoera_mediaengine_destroy(e);
    /* rmdir temp dir (空目录；引擎未写文件因 player_file=NULL) */
    rmdir(sdir);
}

int main(int argc, char **argv)
{
    const char *src = (argc > 1) ? argv[1] : NULL;
    if (!src) {
        fprintf(stderr, "usage: %s <source-audio>\n", argv[0]);
        return 2;
    }
    fprintf(stderr, "source=%s\n", src);

    run_case(src);

    if (g_fail) {
        fprintf(stderr, "test_mediaengine_wait: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_mediaengine_wait: ALL PASS\n");
    return 0;
}

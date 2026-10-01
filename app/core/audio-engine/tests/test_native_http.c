// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_native_http.c — EraAudio 原生 HTTP(S) 解码端到端回归
 *
 * 覆盖 `native_decoder_open_url`（内核自研 HTTP/1.1 请求/响应解析，见
 * kernel/net.zig）：本用例内起一个**最小 Range 服务端**（127.0.0.1 随机端口，
 * 与 kernel 单测同语义），把本地音频文件按 `Range` 提供服务，然后：
 *   - 经 URL 打开解码器（非本地路径），校验流参数与**路径后端一致**；
 *   - 全量解码 PCM 与路径后端**逐字节一致**（同一内核解码器、同字节流）；
 *   - `native_decoder_seek_ms` 后继续解码（Range 重发定位）；
 *   - 断流续传：`/drop` 首次连接中途断开 → 客户端 Range 重连续传；
 *   - 常驻池 seam：显式开池后 URL 走 `zk_engine_open_url`（stream_opens 增长）；
 *   - stop/SIGTERM 中断：`/stall` 停滞读经 `native_decoder_abort` 立即解阻塞；
 *   - 失败契约：不可达地址返回 NULL 并写稳定状态码（供上层回退 AVIO/FFmpeg）。
 *
 * Windows（MSVC）无 POSIX socket：打印 SKIP 并以 ALL PASS 结束（成功路径已由
 * Zig 侧 `zig build test` 的 kernel/net.zig 单测覆盖）。
 */
#if !defined(_WIN32)
/* clock_gettime / CLOCK_MONOTONIC / nanosleep 需 POSIX 2008 特性宏（须在首个
 * 系统头之前定义）。 */
#define _POSIX_C_SOURCE 200809L
#endif
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

#if defined(_WIN32)

int main(void)
{
    printf("SKIP 原生 HTTP 测试（Windows 无 POSIX socket）\n");
    printf("ALL PASS\n");
    return 0;
}

#else /* POSIX */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* ── 最小 Range HTTP 服务端 ─────────────────────────────────────────── */

typedef struct {
    int listen_fd;
    int port;
    const unsigned char *payload;
    size_t len;
    volatile int stop;
    pthread_t thread;
    int started;
    int drop_served; /* /drop 仅首次连接中途断开（重连场景） */
    size_t stall_prefix; /* /stall：发头 + 前 N 字节后停滞（读超时/中断场景） */
    volatile int release_stall; /* 测试释放 /stall 停滞连接 */
} Srv;

static void *srv_thread(void *arg);

/* 完整写尽 n 字节（阻塞 socket）。 */
static int write_all(int fd, const void *buf, size_t n)
{
    const char *p = (const char *)buf;
    while (n > 0) {
        ssize_t w = send(fd, p, n, 0);
        if (w <= 0) {
            if (w < 0 && errno == EINTR) continue;
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* 读尽请求头（至 \r\n\r\n）；返回头长度，0 = 对端关闭/出错。 */
static size_t read_head(int fd, char *buf, size_t cap)
{
    size_t n = 0;
    while (n < cap - 1) {
        ssize_t r = recv(fd, buf + n, cap - 1 - n, 0);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            break;
        }
        n += (size_t)r;
        buf[n] = 0;
        if (strstr(buf, "\r\n\r\n") != NULL) break;
    }
    return n;
}

static void handle_conn(Srv *s, int fd)
{
    char head[8192];
    size_t hn = read_head(fd, head, sizeof(head));
    if (hn == 0) return;

    /* 解析请求行目标（第二段） */
    char target[256] = "/";
    {
        const char *sp1 = strchr(head, ' ');
        if (sp1) {
            const char *sp2 = strchr(sp1 + 1, ' ');
            if (sp2) {
                size_t n = (size_t)(sp2 - (sp1 + 1));
                if (n >= sizeof(target)) n = sizeof(target) - 1;
                memcpy(target, sp1 + 1, n);
                target[n] = 0;
            }
        }
    }

    /* 解析 Range: bytes=S-（逐行大小写不敏感匹配） */
    size_t start = 0;
    for (const char *ln = head; *ln;) {
        const char *eol = strstr(ln, "\r\n");
        if (!eol) break;
        if (strncasecmp(ln, "Range:", 6) == 0) {
            const char *eq = (const char *)memchr(ln, '=', (size_t)(eol - ln));
            if (eq) start = (size_t)strtoull(eq + 1, NULL, 10);
        }
        ln = eol + 2;
    }
    if (start > s->len) start = s->len;

    char hdr[512];
    size_t body = s->len - start;
    /* 半开 end（用于 Content-Range 的闭区间） */
    size_t last = (s->len > 0) ? s->len - 1 : 0;
    int len = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 206 Partial Content\r\n"
        "Content-Range: bytes %zu-%zu/%zu\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        start, last, s->len, body);
    if (len <= 0) return;
    if (write_all(fd, hdr, (size_t)len) != 0) return;

    /* /drop 首次连接：只发 1/3 正文即断开（客户端应自 net_pos 续传）。 */
    if (strcmp(target, "/drop") == 0 && !s->drop_served) {
        s->drop_served = 1;
        size_t part = body / 3;
        if (part > 0 && write_all(fd, s->payload + start, part) != 0) return;
        return;
    }

    /* /stall：发头 + 前 stall_prefix 字节后停滞（客户端读阻塞；测超时/中止）。 */
    if (strcmp(target, "/stall") == 0) {
        size_t pre = body < s->stall_prefix ? body : s->stall_prefix;
        if (pre > 0 && write_all(fd, s->payload + start, pre) != 0) return;
        while (!s->release_stall && !s->stop) {
            struct timespec ts = { .tv_sec = 0, .tv_nsec = 20 * 1000 * 1000 };
            nanosleep(&ts, NULL);
        }
        return;
    }

    if (body > 0 && write_all(fd, s->payload + start, body) != 0) return;
}

static void *srv_thread(void *arg)
{
    Srv *s = (Srv *)arg;
    while (!s->stop) {
        int fd = accept(s->listen_fd, NULL, NULL);
        if (fd < 0) break; /* stop/关闭后返回 */
        handle_conn(s, fd);
        close(fd);
    }
    return NULL;
}

static int srv_start(Srv *s, const unsigned char *payload, size_t len)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    if (listen(fd, 8) != 0) { close(fd); return -1; }
    socklen_t alen = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &alen) != 0) { close(fd); return -1; }

    s->listen_fd = fd;
    s->port = ntohs(addr.sin_port);
    s->payload = payload;
    s->len = len;
    s->stop = 0;
    if (pthread_create(&s->thread, NULL, srv_thread, s) != 0) { close(fd); return -1; }
    s->started = 1;
    return 0;
}

static void srv_stop(Srv *s)
{
    if (!s->started) return;
    s->stop = 1;
    shutdown(s->listen_fd, SHUT_RDWR);
    close(s->listen_fd);
    pthread_join(s->thread, NULL);
    s->started = 0;
}

/* ── 工具 ──────────────────────────────────────────────────────────── */

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
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

typedef struct { float *data; size_t n; size_t cap; } Pcm;

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

/* 全量解码；返回累计帧数，<0 = 解码错误。 */
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

/* 中止线程：短延时后调用 native_decoder_abort（模拟 stop/SIGTERM）。 */
typedef struct { NativeDecoder *d; } AbortArg;
static void *abort_later(void *arg)
{
    AbortArg *a = (AbortArg *)arg;
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 200 * 1000 * 1000 };
    nanosleep(&ts, NULL);
    native_decoder_abort(a->d);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <audio-fixture>\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN); /* 客户端提前关闭时不要被 SIGPIPE 杀死 */

    size_t file_len = 0;
    unsigned char *file = read_all(argv[1], &file_len);
    if (!file) {
        fprintf(stderr, "cannot read fixture: %s\n", argv[1]);
        return 2;
    }

    /* 路径后端参考 */
    NativeInfo pinfo;
    char eb[512];
    int pst = 0;
    NativeDecoder *pd = native_decoder_open(argv[1], &pinfo, &pst, eb, (int)sizeof(eb));
    CHECK(pd != NULL, "路径后端打开成功");
    if (!pd) { free(file); return 1; }

    Srv srv;
    memset(&srv, 0, sizeof(srv));
    CHECK(srv_start(&srv, file, file_len) == 0, "本地 Range 服务端启动");

    char url[256];
    snprintf(url, sizeof(url), "http://127.0.0.1:%d/fixture", srv.port);

    /* 原生 HTTP 打开 */
    NativeInfo uinfo;
    int ust = 0;
    NativeDecoder *ud = native_decoder_open_url(url, &uinfo, &ust, eb, (int)sizeof(eb));
    CHECK(ud != NULL, "native_decoder_open_url 打开成功");
    if (ud) {
        CHECK(uinfo.sample_rate == pinfo.sample_rate, "URL 后端采样率一致");
        CHECK(uinfo.channels == pinfo.channels, "URL 后端声道一致");
        CHECK(uinfo.bits_per_sample == pinfo.bits_per_sample, "URL 后端位深一致");
        CHECK(uinfo.duration_us == pinfo.duration_us, "URL 后端时长一致");

        Pcm pa = {0}, pu = {0};
        long fp = drain(pd, &pa);
        long fu = drain(ud, &pu);
        CHECK(fp > 0, "路径后端全量解码非空");
        CHECK(fu == fp, "URL 后端帧数与路径后端一致");
        CHECK(pa.n == pu.n && pa.n > 0 && memcmp(pa.data, pu.data, pa.n * sizeof(float)) == 0,
              "URL 后端 PCM 与路径后端逐字节一致");
        pcm_free(&pu);

        /* seek：Range 重发定位后继续解码 */
        if (pinfo.sample_rate > 0) {
            long mid_ms = (long)(pinfo.duration_us / 2000); /* 半程 */
            int rc = native_decoder_seek_ms(ud, mid_ms);
            CHECK(rc == 0, "URL 后端 seek 成功");
            static float tmp[4096 * 8];
            int ch = 0;
            int n = native_decoder_read(ud, tmp, 1024, &ch);
            CHECK(n > 0, "seek 后仍能解码出帧");
        }
        native_decoder_close(ud);

        /* 断流续传：/drop 首次连接中途断开，客户端应自 net_pos 以 Range 重连，
         * 仍解出与路径后端一致的全长 PCM。 */
        char urld[256];
        snprintf(urld, sizeof(urld), "http://127.0.0.1:%d/drop", srv.port);
        NativeInfo dinfo;
        int dst = 0;
        NativeDecoder *dd = native_decoder_open_url(urld, &dinfo, &dst, eb, (int)sizeof(eb));
        CHECK(dd != NULL, "断流续传：URL 打开成功");
        if (dd) {
            Pcm pd2 = {0};
            long fd2 = drain(dd, &pd2);
            CHECK(fd2 == fp, "断流续传：帧数与路径后端一致");
            CHECK(pa.n == pd2.n && pa.n > 0 &&
                      memcmp(pa.data, pd2.data, pa.n * sizeof(float)) == 0,
                  "断流续传：PCM 与路径后端逐字节一致");
            pcm_free(&pd2);
            native_decoder_close(dd);
        }

        /* 池化 URL：ARCHOERA_ERA_POOL seam 下 URL 源也走常驻内核池
         * （zk_engine_open_url），与 path/mem/cb 一致；PCM 仍与路径参考逐字节
         * 一致，且进程级 stream_opens 计数增加，证明命中池路径（非直连）。 */
        if (native_decoder_pool_begin(1, 2, 8) == 0) {
            long b2 = native_decoder_stream_opens();
            NativeInfo uinfo2;
            int ust2 = 0;
            NativeDecoder *dp = native_decoder_open_url(url, &uinfo2, &ust2, eb, (int)sizeof(eb));
            CHECK(dp != NULL, "池 URL 打开成功");
            if (dp) {
                CHECK(uinfo2.sample_rate == pinfo.sample_rate, "池 URL 后端采样率一致");
                Pcm pp = {0};
                long fpp = drain(dp, &pp);
                CHECK(fpp == fp, "池 URL 帧数与路径后端一致");
                CHECK(pa.n == pp.n && pa.n > 0 &&
                          memcmp(pa.data, pp.data, pa.n * sizeof(float)) == 0,
                      "池 URL PCM 与路径后端逐字节一致");
                pcm_free(&pp);
                native_decoder_close(dp);
            }
            CHECK(native_decoder_stream_opens() > b2, "池路径命中");
            native_decoder_pool_end();
        } else {
            CHECK(0, "池启动失败");
        }

        pcm_free(&pa);

        /* stop/SIGTERM 中断池化 URL 流：/stall 停滞读应被 abort 立即解阻塞
         * （而非等到 15s 读超时）。验证 native_decoder_abort → zk_engine_abort →
         * HttpStream.abort 在池 worker 的阻塞网络读上生效。
         * 用 FLAC（open 仅读元数据，不扫全文件）：扣留尾部少量字节 + 超大口径读
         * （本文件远不足 200000 帧）以确保 open 成功后**读阶段**才阻塞。 */
        {
            srv.stall_prefix = file_len > 4096 ? (file_len - 4096) : (file_len / 2);
            CHECK(native_decoder_pool_begin(1, 2, 8) == 0, "中断测试池启动");

            char urls[256];
            snprintf(urls, sizeof(urls), "http://127.0.0.1:%d/stall", srv.port);
            NativeInfo ainfo;
            int ast = 0;
            NativeDecoder *ap = native_decoder_open_url(urls, &ainfo, &ast, eb, (int)sizeof(eb));
            CHECK(ap != NULL, "停滞 URL 池打开成功");
            if (!ap) fprintf(stderr, "  stall open status=%d err=%s\n", ast, eb + 4);
            if (ap) {
                AbortArg aa = { ap };
                pthread_t th;
                if (pthread_create(&th, NULL, abort_later, &aa) == 0) {
                    struct timespec t0, t1;
                    clock_gettime(CLOCK_MONOTONIC, &t0);
                    static float aout[200000]; /* 200000 帧 ≫ 本文件总帧数 */
                    int ach = 0;
                    int an = native_decoder_read(ap, aout, 200000, &ach);
                    clock_gettime(CLOCK_MONOTONIC, &t1);
                    long ms = (long)(t1.tv_sec - t0.tv_sec) * 1000 +
                              (long)(t1.tv_nsec - t0.tv_nsec) / 1000000;
                    pthread_join(th, NULL);
                    CHECK(an < 200000, "停滞读在 abort 后返回（未凑满请求帧）");
                    CHECK(ms < 3000, "abort 在读超时前解阻塞（<3s）");
                } else {
                    CHECK(0, "abort 线程创建");
                }
                native_decoder_close(ap);
            }
            srv.release_stall = 1;
            native_decoder_pool_end();
        }
    } else {
        fprintf(stderr, "  URL 打开失败 status=%d err=%s\n", ust, eb + 4);
    }

    /* 失败契约：不可达地址 → NULL + 非 0 状态码（供上层回退） */
    {
        NativeInfo bad;
        int bst = 0;
        NativeDecoder *bd = native_decoder_open_url(
            "http://127.0.0.1:1/none", &bad, &bst, eb, (int)sizeof(eb));
        CHECK(bd == NULL, "不可达地址返回 NULL");
        CHECK(bst != 0, "不可达地址写非 0 状态码");
        if (bd) native_decoder_close(bd);
    }
    /* 非 http(s) 协议 → NULL */
    {
        NativeInfo bad;
        int bst = 0;
        NativeDecoder *bd = native_decoder_open_url(
            "ftp://127.0.0.1/x", &bad, &bst, eb, (int)sizeof(eb));
        CHECK(bd == NULL, "非 http(s) 协议返回 NULL");
        if (bd) native_decoder_close(bd);
    }

    srv_stop(&srv);
    native_decoder_close(pd);
    free(file);

    if (g_fail == 0) {
        printf("ALL PASS\n");
        return 0;
    }
    printf("FAILED (%d)\n", g_fail);
    return 1;
}

#endif /* _WIN32 */

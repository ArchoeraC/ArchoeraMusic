/**
 * pcm_uds.c — PCM 流出 Unix Domain Socket 服务器实现
 *
 * 单连接 AF_UNIX SOCK_STREAM：Flutter 连接后收到原始 float PCM 块；
 * 无连接时数据块丢弃（块头自描述位置，Flutter 重连后仍可对齐进度）。
 */
#define _POSIX_C_SOURCE 200809L
#include "pcm_uds.h"

#ifdef _WIN32
/* Windows 无 AF_UNIX：stub（create 返回 NULL，其余无操作），
 * 保证 audio_engine_static / CLI 可链接；PCM 流出在 Windows 暂不支持。 */
PcmUds* pcm_uds_create(const char *path) { (void)path; return NULL; }
int pcm_uds_wait_conn(PcmUds *u, int timeout_ms) { (void)u; (void)timeout_ms; return -1; }
int pcm_uds_push(PcmUds *u, const struct iovec *iov, int iovcnt) { (void)u; (void)iov; (void)iovcnt; return -1; }
void pcm_uds_destroy(PcmUds *u) { (void)u; }
#else
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>

#define LOG_TAG "[audio-engine:pcm_uds]"

struct PcmUds {
    int listen_fd;
    int conn_fd;
    char path[256];
};

PcmUds* pcm_uds_create(const char *path)
{
    if (!path || !*path) return NULL;

    PcmUds *u = calloc(1, sizeof(*u));
    if (!u) return NULL;
    u->conn_fd = -1;
    u->listen_fd = -1;
    snprintf(u->path, sizeof(u->path), "%s", path);

    unlink(path); /* 清理上次残留的 socket 文件 */

    u->listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (u->listen_fd < 0) {
        fprintf(stderr, "%s socket 创建失败: %s\n", LOG_TAG, strerror(errno));
        free(u);
        return NULL;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);

    if (bind(u->listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "%s bind %s 失败: %s\n", LOG_TAG, path, strerror(errno));
        close(u->listen_fd);
        free(u);
        return NULL;
    }
    if (listen(u->listen_fd, 1) < 0) {
        fprintf(stderr, "%s listen 失败: %s\n", LOG_TAG, strerror(errno));
        close(u->listen_fd);
        unlink(path);
        free(u);
        return NULL;
    }

    /* listen fd 非阻塞（供循环内尝试 accept，不阻塞转码） */
    int flags = fcntl(u->listen_fd, F_GETFL, 0);
    fcntl(u->listen_fd, F_SETFL, flags | O_NONBLOCK);

    fprintf(stderr, "%s 监听 %s\n", LOG_TAG, path);
    return u;
}

static void close_conn(PcmUds *u)
{
    if (u->conn_fd >= 0) {
        close(u->conn_fd);
        u->conn_fd = -1;
    }
}

static void try_accept(PcmUds *u)
{
    if (u->conn_fd >= 0) return;
    int fd = accept(u->listen_fd, NULL, NULL);
    if (fd >= 0) {
        u->conn_fd = fd; /* accept 返回的 socket 为阻塞模式 */
        fprintf(stderr, "%s 客户端已连接\n", LOG_TAG);
    }
}

int pcm_uds_wait_conn(PcmUds *u, int timeout_ms)
{
    if (!u) return -1;
    if (u->conn_fd >= 0) return 0;

    long long deadline_ms = timeout_ms > 0
        ? (long long)((double)clock() * 1000.0 / CLOCKS_PER_SEC) + timeout_ms
        : -1;

    for (;;) {
        try_accept(u);
        if (u->conn_fd >= 0) return 0;

        if (deadline_ms >= 0) {
            long long now_ms = (long long)((double)clock() * 1000.0 / CLOCKS_PER_SEC);
            if (now_ms >= deadline_ms) return -1;
        }
        struct timespec ts = {0, 5 * 1000000L};
        nanosleep(&ts, NULL); /* 5ms 轮询，可被信号/超时中断 */
    }
}

int pcm_uds_push(PcmUds *u, const struct iovec *iov, int iovcnt)
{
    if (!u || !iov || iovcnt <= 0) return -1;

    try_accept(u);
    if (u->conn_fd < 0) return 0; /* 无连接：丢弃本块 */

    size_t len = 0;
    for (int i = 0; i < iovcnt; i++) len += iov[i].iov_len;
    if (len == 0) return 0;

    size_t off = 0;
    while (off < len) {
        /* 构建跳过 off 之后的 iovec 窗口（处理部分写） */
        struct iovec part[8];
        int npart = 0;
        size_t skip = off;
        for (int i = 0; i < iovcnt && npart < 8; i++) {
            if (skip >= iov[i].iov_len) {
                skip -= iov[i].iov_len;
                continue;
            }
            part[npart].iov_base = (char *)iov[i].iov_base + skip;
            part[npart].iov_len = iov[i].iov_len - skip;
            npart++;
            skip = 0;
        }
        ssize_t n = writev(u->conn_fd, part, npart);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EPIPE || errno == ECONNRESET) {
                close_conn(u); /* 客户端断开：等重连 */
            }
            return -1;
        }
        off += (size_t)n;
    }
    return (int)off;
}

void pcm_uds_destroy(PcmUds *u)
{
    if (!u) return;
    close_conn(u);
    if (u->listen_fd >= 0) close(u->listen_fd);
    if (u->path[0]) unlink(u->path);
    free(u);
}
#endif /* _WIN32 */

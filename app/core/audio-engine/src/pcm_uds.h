/**
 * pcm_uds.h — PCM 流出 Unix Domain Socket 服务器
 *
 * 桌面端 Flutter 直连解码引擎收取原始 PCM 自行做频谱分析（FFT 客户端化）。
 * 一个连接；断开后等待重连；无连接时数据块直接丢弃（块自描述，位置可恢复）。
 */
#ifndef PCM_UDS_H
#define PCM_UDS_H

#ifdef _WIN32
/* Windows 无 AF_UNIX：提供 iovec 类型与函数声明（stub 实现），
 * 避免 main.c / static lib 依赖 POSIX 头（sys/uio.h 等）。 */
#include <stddef.h>
typedef struct iovec {
    void *iov_base;
    size_t iov_len;
} iovec;
#else
#include <sys/uio.h>
#endif

typedef struct PcmUds PcmUds;

/**
 * 创建 UDS 服务器
 *
 * @param path socket 文件路径（如 /tmp/archoera-pcm-xxx.sock）
 * @return 实例，失败返回 NULL
 */
PcmUds* pcm_uds_create(const char *path);

/**
 * 等待客户端连接（非阻塞轮询 accept）
 *
 * 连接驱动转码：流式播放时引擎须等 libmpv 连上 stream UDS 后才开始转码，
 * 保证 OGG 流从开头完整（无连接期间的写会被丢弃，导致开头缺失）。
 *
 * @param u          实例
 * @param timeout_ms 超时（ms），<=0 表示无限等待
 * @return 0 已连接；-1 超时
 */
int pcm_uds_wait_conn(PcmUds *u, int timeout_ms);

/**
 * 推送一块数据（阻塞写，背压同 stdout；连接断开自动丢弃并等待重连）
 *
 * @param iov    iovec 数组（如 [header][pcm]）
 * @param iovcnt iovec 数量
 * @return 写入字节数；无连接返回 0；断开/错误返回 -1
 */
int pcm_uds_push(PcmUds *u, const struct iovec *iov, int iovcnt);

/** 销毁实例（关闭 fd + unlink socket 文件） */
void pcm_uds_destroy(PcmUds *u);

#endif /* PCM_UDS_H */

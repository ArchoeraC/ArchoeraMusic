// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * native_decoder.c — 自研 Zig 解码内核（archoera_kernel）的 C 壳封装
 *
 * 经 include/kernel_bridge.h 的 zk_* C ABI 调用静态库 libarchoera_kernel.a
 * （zig-out/lib，由 CMake 在 HAS_ARCHOERA_KERNEL 定义时构建/链接）。
 *
 * 约定（docs/audio-kernel-zig.md §16.1）：
 *   - 未接管格式 → zk_decoder_open 返回 NULL 且 errbuf 状态码为
 *     ZK_UNSUPPORTED(1)，C 壳据此回退 FFmpeg 主后端；
 *   - Zig 侧统一用宿主 CRT malloc/free（c_allocator），与 C 壳同 CRT，
 *     无跨 CRT 所有权问题；C 侧只读 info 字符串、不释放。
 *
 * 已知限制：多数有损/压缩格式解码器当前为「整文件读入内存」实现
 * （decoder.zig 的 read() 对 mp3/wv/ape/m4a 等整读），大文件存在 OOM 风险；
 * 本阶段仅打通功能链路，streaming 分块解码由后续内核侧改造另行跟进。
 */
#include "native_decoder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#define LOG_TAG "[audio-engine:native-decoder]"

#if defined(HAS_ARCHOERA_KERNEL)

#include "../include/kernel_bridge.h"

/* S1 常驻内核池（opt-in）：mediaengine_lib 引擎线程在 ARCHOERA_ERA_POOL 时经
 * native_decoder_pool_begin/end 托管；g_pool 非 NULL 时 native_decoder_open 改走
 * zk_engine_open 流式 seam（同一 ZkInfo/errbuf 契约），否则沿用 zk_decoder_*。 */
static ZkEngine *g_pool;
/* 进程级池可被多个 mediaengine 实例共享（同一 .so 内全局）。用引用计数 + 互斥：
 * 任一实例 pool_end 不得在其它实例仍持有时 shutdown，否则其流读会因 rt 停机失败
 * （概率性「自研内核解码错误」/崩溃）。仅当计数归零才真正 shutdown。 */
static int g_pool_refs;
/* 进程池锁惰性初始化：CRITICAL_SECTION(MSVC compat) 不支持静态初始化，
 * POSIX 亦经 pthread_once 统一一次 init（见 segstore.c 同法）。 */
static pthread_mutex_t g_pool_mu;
static pthread_once_t g_pool_once = PTHREAD_ONCE_INIT;
static void pool_mu_init(void) { pthread_mutex_init(&g_pool_mu, NULL); }
static void pool_lock(void) {
    pthread_once(&g_pool_once, pool_mu_init);
    pthread_mutex_lock(&g_pool_mu);
}
static void pool_unlock(void) { pthread_mutex_unlock(&g_pool_mu); }
static long long g_stream_opens; /* 池路径 open 累计（测试访问器，单调递增） */
/* F5 接管门控统计：attempts = native_decoder_open 调用次数；hits = 成功接管
 * （status==0）；misses = 明确未接管（status==ZK_UNSUPPORTED）。进程级、单调。 */
static long long g_takeover_attempts;
static long long g_takeover_hits;
static long long g_takeover_misses;

int native_decoder_taken_over_by_ext(const char *path)
{
    if (!path) return -1;
    const char *dot = strrchr(path, '.');
    if (!dot) return -1;
    /* 点号后若含路径分隔符/查询串/片段，则不是扩展名（如 URL 目录点、?v=1.2）→ 未知 */
    for (const char *c = dot; *c; c++) {
        if (*c == '/' || *c == '\\' || *c == '?' || *c == '#') return -1;
    }
    return zk_takeover_of_ext(dot);
}

void native_decoder_stats(long long *attempts, long long *hits, long long *unsupported)
{
    if (attempts) *attempts = g_takeover_attempts;
    if (hits) *hits = g_takeover_hits;
    if (unsupported) *unsupported = g_takeover_misses;
}

struct NativeDecoder {
    ZkDecoder *zk;
    ZkInfo info;
    ZkEngineStream *stream; /* 池 stream seam 句柄（is_stream 时使用） */
    int is_stream;
};

int native_decoder_pool_begin(int min_w, int max_w, int cap)
{
    pool_lock();
    if (g_pool) { /* 已存在：共享，仅增引用 */
        g_pool_refs++;
        pool_unlock();
        return 0;
    }
    /* N4：进程级流缓冲策略经宿主 env 注入（与既有 ARCHOERA_* 读取同法；失败不影响打开）。
     * 0/未设 = 默认（预算不限、每路 16 KiB），行为与既往逐字节一致。 */
    const char *sb = getenv("ARCHOERA_STREAM_BUDGET");
    if (sb && sb[0]) zk_stream_mem_set_budget(strtoull(sb, NULL, 10));
    const char *sp = getenv("ARCHOERA_STREAM_PEEK_BYTES");
    if (sp && sp[0]) zk_stream_peek_set_bytes((unsigned)strtoul(sp, NULL, 10));
    g_pool = zk_engine_init(min_w, max_w, cap);
    if (!g_pool) {
        pool_unlock();
        return -1;
    }
    g_pool_refs = 1;
    pool_unlock();
    return 0;
}

void native_decoder_pool_end(void)
{
    pool_lock();
    if (!g_pool || g_pool_refs <= 0) {
        pool_unlock();
        return;
    }
    g_pool_refs--;
    if (g_pool_refs == 0) { /* 最后一个持有者：真正停池 */
        zk_engine_shutdown(g_pool);
        g_pool = NULL;
    }
    pool_unlock();
}

int native_decoder_pool_active(void)
{
    return g_pool ? 1 : 0;
}

long long native_decoder_stream_opens(void)
{
    return g_stream_opens;
}

/* AS2：门控的 worker 亲和（pinned 1:1）。默认关（未设 / != "1"），保持既有全局队列
 * 行为；开启后路径源流式会话优先取专属 worker（无空闲自动回退全局队列）。 */
static int pool_pinned_enabled(void)
{
    const char *v = getenv("ARCHOERA_ERA_POOL_PINNED");
    return v && v[0] == '1' && v[1] == '\0';
}

bool native_decoder_available(void)
{
    return true;
}

/* errbuf[0..4] 为 LE int32 状态码（kernel_bridge.h 契约），读回主机字节序 */
static int read_le32_status(const char *eb)
{
    const unsigned char *b = (const unsigned char *)eb;
    return (int)b[0] | ((int)b[1] << 8) | ((int)b[2] << 16) | ((int)b[3] << 24);
}

NativeDecoder *native_decoder_open(const char *path, NativeInfo *info,
                                   int *status_out,
                                   char *errbuf, int errbuf_size)
{
    if (!path) return NULL;
    g_takeover_attempts++;

    ZkInfo zinfo;
    char eb[512];
    ZkDecoder *zk = NULL;
    ZkEngineStream *st = NULL;
    NativeDecoder *d;
    memset(&zinfo, 0, sizeof(zinfo));
    memset(eb, 0, sizeof(eb));

    if (g_pool) {
        /* S1 池路径：流式 seam（同一 errbuf 契约：errbuf[0..4] LE int32 状态码）。
         * AS2：ARCHOERA_ERA_POOL_PINNED=1 时优先专属 worker（pinned 1:1）。 */
        st = pool_pinned_enabled()
                 ? zk_engine_open_pinned(g_pool, path, &zinfo, eb, sizeof(eb))
                 : zk_engine_open(g_pool, path, &zinfo, eb, sizeof(eb));
        if (!st) {
            int fs = read_le32_status(eb);
            if (fs == 1) g_takeover_misses++; /* ZK_UNSUPPORTED */
            if (status_out) *status_out = fs;
            if (errbuf && errbuf_size > 0) {
                snprintf(errbuf, errbuf_size, "%s", eb + 4);
            }
            return NULL;
        }
        g_stream_opens++;
    } else {
        zk = zk_decoder_open(path, &zinfo, eb, (int)sizeof(eb));
        if (!zk) {
            int fs = read_le32_status(eb);
            if (fs == 1) g_takeover_misses++; /* ZK_UNSUPPORTED */
            if (status_out) *status_out = fs;
            if (errbuf && errbuf_size > 0) {
                snprintf(errbuf, errbuf_size, "%s", eb + 4);
            }
            return NULL;
        }
    }
    g_takeover_hits++; /* 打开成功 = 接管命中 */

    d = (NativeDecoder *)calloc(1, sizeof(*d));
    if (!d) {
        if (zk) zk_decoder_close(zk);
        if (st) zk_engine_close(st);
        if (status_out) *status_out = 7; /* ZK_OUT_OF_MEMORY */
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "out of memory");
        }
        return NULL;
    }
    d->zk = zk;
    d->stream = st;
    d->is_stream = (st != NULL);
    d->info = zinfo;

    if (status_out) *status_out = 0;
    if (info) {
        info->sample_rate = zinfo.sample_rate;
        info->channels = zinfo.channels;
        info->bits_per_sample = zinfo.bits_per_sample;
        info->duration_us = zinfo.duration_us;
        info->duration_known = zinfo.duration_known;
        info->codec_name = zinfo.codec_name;
        info->format_name = zinfo.format_name;
    }
    return d;
}

NativeDecoder *native_decoder_open_mem(const void *data, size_t len, NativeInfo *info,
                                       int *status_out,
                                       char *errbuf, int errbuf_size)
{
    if (!data || len == 0) return NULL;

    ZkInfo zinfo;
    char eb[512];
    NativeDecoder *d;
    ZkDecoder *zk = NULL;
    ZkEngineStream *st = NULL;
    memset(&zinfo, 0, sizeof(zinfo));
    memset(eb, 0, sizeof(eb));

    /* 池启用时走 zk_engine 流式 seam（与路径打开同法）；否则直连 decoder。 */
    if (g_pool) {
        st = zk_engine_open_mem(g_pool, (const unsigned char *)data, len,
                                &zinfo, eb, sizeof(eb));
        if (!st) {
            if (status_out) *status_out = read_le32_status(eb);
            if (errbuf && errbuf_size > 0) {
                snprintf(errbuf, errbuf_size, "%s", eb + 4);
            }
            return NULL;
        }
        g_stream_opens++;
    } else {
        zk = zk_decoder_open_mem((const unsigned char *)data, len,
                                 &zinfo, eb, (int)sizeof(eb));
        if (!zk) {
            if (status_out) *status_out = read_le32_status(eb);
            if (errbuf && errbuf_size > 0) {
                snprintf(errbuf, errbuf_size, "%s", eb + 4);
            }
            return NULL;
        }
    }

    d = (NativeDecoder *)calloc(1, sizeof(*d));
    if (!d) {
        if (zk) zk_decoder_close(zk);
        if (st) zk_engine_close(st);
        if (status_out) *status_out = 7; /* ZK_OUT_OF_MEMORY */
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "out of memory");
        }
        return NULL;
    }
    d->zk = zk;
    d->stream = st;
    d->is_stream = (st != NULL);
    d->info = zinfo;

    if (status_out) *status_out = 0;
    if (info) {
        info->sample_rate = zinfo.sample_rate;
        info->channels = zinfo.channels;
        info->bits_per_sample = zinfo.bits_per_sample;
        info->duration_us = zinfo.duration_us;
        info->duration_known = zinfo.duration_known;
        info->codec_name = zinfo.codec_name;
        info->format_name = zinfo.format_name;
    }
    return d;
}

NativeDecoder *native_decoder_open_cb(void *ctx,
                                      size_t (*on_read)(void *, unsigned char *, size_t),
                                      int (*on_seek)(void *, long long, int, size_t),
                                      unsigned long long size_hint,
                                      NativeInfo *info, int *status_out,
                                      char *errbuf, int errbuf_size)
{
    if (!ctx || !on_read || !on_seek) return NULL;

    ZkInfo zinfo;
    char eb[512];
    NativeDecoder *d;
    ZkDecoder *zk = NULL;
    ZkEngineStream *st = NULL;
    memset(&zinfo, 0, sizeof(zinfo));
    memset(eb, 0, sizeof(eb));

    /* 池启用时走 zk_engine 流式 seam；否则直连 decoder（ctx 归调用方）。 */
    if (g_pool) {
        st = zk_engine_open_cb(g_pool, ctx, on_read, on_seek, size_hint,
                               &zinfo, eb, sizeof(eb));
        if (!st) {
            if (status_out) *status_out = read_le32_status(eb);
            if (errbuf && errbuf_size > 0) {
                snprintf(errbuf, errbuf_size, "%s", eb + 4);
            }
            return NULL;
        }
        g_stream_opens++;
    } else {
        zk = zk_decoder_open_cb(ctx, on_read, on_seek, size_hint,
                                &zinfo, eb, (int)sizeof(eb));
        if (!zk) {
            if (status_out) *status_out = read_le32_status(eb);
            if (errbuf && errbuf_size > 0) {
                snprintf(errbuf, errbuf_size, "%s", eb + 4);
            }
            return NULL;
        }
    }

    d = (NativeDecoder *)calloc(1, sizeof(*d));
    if (!d) {
        if (zk) zk_decoder_close(zk);
        if (st) zk_engine_close(st);
        if (status_out) *status_out = 7; /* ZK_OUT_OF_MEMORY */
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "out of memory");
        }
        return NULL;
    }
    d->zk = zk;
    d->stream = st;
    d->is_stream = (st != NULL);
    d->info = zinfo;

    if (status_out) *status_out = 0;
    if (info) {
        info->sample_rate = zinfo.sample_rate;
        info->channels = zinfo.channels;
        info->bits_per_sample = zinfo.bits_per_sample;
        info->duration_us = zinfo.duration_us;
        info->duration_known = zinfo.duration_known;
        info->codec_name = zinfo.codec_name;
        info->format_name = zinfo.format_name;
    }
    return d;
}

int native_decoder_read(NativeDecoder *d, float *out, int max_frames,
                        int *out_channels)
{
    if (!d || !out || !out_channels || max_frames <= 0) return -1;
    int oc = 0;
    /* zk_*_read：>=0 为帧数（0=EOF），<0 为错误（负 ZkStatus 状态码）。
     * 错误经负值上报（zk 不再把解码错误吞成 0），C 壳据此让 pipeline 报错，
     * 而非把坏帧静默当 EOF 截断。 */
    long long frames;
    if (d->is_stream) {
        frames = zk_engine_read(d->stream, out, (size_t)max_frames, &oc);
    } else {
        frames = zk_decoder_read(d->zk, out, (size_t)max_frames, &oc);
    }
    *out_channels = oc;
    if (frames < 0) return (int)frames; /* <0：解码错误（-ZkStatus），与 EOF 区分 */
    return (int)frames;
}

int native_decoder_seek_ms(NativeDecoder *d, int64_t ms)
{
    if (!d) return -1;
    if (d->is_stream) {
        return zk_engine_seek_ms(d->stream, (long long)ms) == 0 ? 0 : -1;
    }
    return zk_decoder_seek_ms(d->zk, (long long)ms) == 0 ? 0 : -1;
}

int native_decoder_sample_rate(const NativeDecoder *d)
{
    return d ? d->info.sample_rate : 0;
}

int native_decoder_channels(const NativeDecoder *d)
{
    return d ? d->info.channels : 0;
}

int64_t native_decoder_duration_us(const NativeDecoder *d)
{
    return d ? (int64_t)d->info.duration_us : 0;
}

const char *native_decoder_codec_name(const NativeDecoder *d)
{
    if (!d || !d->info.codec_name) return "unknown";
    return d->info.codec_name;
}

void native_decoder_close(NativeDecoder *d)
{
    if (!d) return;
    if (d->is_stream) {
        if (d->stream) zk_engine_close(d->stream);
    } else if (d->zk) {
        zk_decoder_close(d->zk);
    }
    free(d);
}

#else /* !HAS_ARCHOERA_KERNEL：内核未链接，编译期空实现（保持可编过） */

struct NativeDecoder { int _unused; };

int native_decoder_pool_begin(int min_w, int max_w, int cap)
{
    (void)min_w; (void)max_w; (void)cap;
    return -1; /* 无内核：池不可用，调用方沿用旧路径 */
}

void native_decoder_pool_end(void)
{
}

int native_decoder_pool_active(void)
{
    return 0;
}

long long native_decoder_stream_opens(void)
{
    return 0;
}

bool native_decoder_available(void)
{
    return false;
}

int native_decoder_taken_over_by_ext(const char *path)
{
    (void)path;
    return -1; /* 无内核：未知 → 调用方保留 try-then-fallback */
}

void native_decoder_stats(long long *attempts, long long *hits, long long *unsupported)
{
    if (attempts) *attempts = 0;
    if (hits) *hits = 0;
    if (unsupported) *unsupported = 0;
}

NativeDecoder *native_decoder_open(const char *path, NativeInfo *info,
                                   int *status_out,
                                   char *errbuf, int errbuf_size)
{
    (void)path; (void)info;
    if (status_out) *status_out = 1; /* ZK_UNSUPPORTED */
    if (errbuf && errbuf_size > 0) {
        snprintf(errbuf, errbuf_size, "archoera_kernel 未链接（构建时无 zig）");
    }
    return NULL;
}

NativeDecoder *native_decoder_open_mem(const void *data, size_t len, NativeInfo *info,
                                       int *status_out,
                                       char *errbuf, int errbuf_size)
{
    (void)data; (void)len; (void)info;
    if (status_out) *status_out = 1; /* ZK_UNSUPPORTED */
    if (errbuf && errbuf_size > 0) {
        snprintf(errbuf, errbuf_size, "archoera_kernel 未链接（构建时无 zig）");
    }
    return NULL;
}

NativeDecoder *native_decoder_open_cb(void *ctx,
                                      size_t (*on_read)(void *, unsigned char *, size_t),
                                      int (*on_seek)(void *, long long, int, size_t),
                                      unsigned long long size_hint,
                                      NativeInfo *info, int *status_out,
                                      char *errbuf, int errbuf_size)
{
    (void)ctx; (void)on_read; (void)on_seek; (void)size_hint; (void)info;
    if (status_out) *status_out = 1; /* ZK_UNSUPPORTED */
    if (errbuf && errbuf_size > 0) {
        snprintf(errbuf, errbuf_size, "archoera_kernel 未链接（构建时无 zig）");
    }
    return NULL;
}

int native_decoder_read(NativeDecoder *d, float *out, int max_frames,
                        int *out_channels)
{
    (void)d; (void)out; (void)max_frames;
    if (out_channels) *out_channels = 0;
    return 0;
}

int native_decoder_seek_ms(NativeDecoder *d, int64_t ms)
{
    (void)d; (void)ms;
    return -1;
}

int native_decoder_sample_rate(const NativeDecoder *d)
{
    (void)d;
    return 0;
}

int native_decoder_channels(const NativeDecoder *d)
{
    (void)d;
    return 0;
}

int64_t native_decoder_duration_us(const NativeDecoder *d)
{
    (void)d;
    return 0;
}

const char *native_decoder_codec_name(const NativeDecoder *d)
{
    (void)d;
    return "unknown";
}

void native_decoder_close(NativeDecoder *d)
{
    (void)d;
}

#endif /* HAS_ARCHOERA_KERNEL */

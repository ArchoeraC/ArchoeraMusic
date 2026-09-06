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

#define LOG_TAG "[audio-engine:native-decoder]"

#if defined(HAS_ARCHOERA_KERNEL)

#include "../include/kernel_bridge.h"

struct NativeDecoder {
    ZkDecoder *zk;
    ZkInfo info;
};

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

    ZkInfo zinfo;
    memset(&zinfo, 0, sizeof(zinfo));
    char eb[512];
    ZkDecoder *zk = zk_decoder_open(path, &zinfo, eb, (int)sizeof(eb));
    if (!zk) {
        if (status_out) *status_out = read_le32_status(eb);
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "%s", eb + 4);
        }
        return NULL;
    }

    NativeDecoder *d = (NativeDecoder *)calloc(1, sizeof(*d));
    if (!d) {
        zk_decoder_close(zk);
        if (status_out) *status_out = 7; /* ZK_OUT_OF_MEMORY */
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "out of memory");
        }
        return NULL;
    }
    d->zk = zk;
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
    /* zk_decoder_read：>=0 为帧数（0=EOF），<0 为错误（负 ZkStatus 状态码）。
     * 错误经负值上报（zk 不再把解码错误吞成 0），C 壳据此让 pipeline 报错，
     * 而非把坏帧静默当 EOF 截断。 */
    long long frames = zk_decoder_read(d->zk, out, (size_t)max_frames, &oc);
    *out_channels = oc;
    if (frames < 0) return (int)frames; /* <0：解码错误（-ZkStatus），与 EOF 区分 */
    return (int)frames;
}

int native_decoder_seek_ms(NativeDecoder *d, int64_t ms)
{
    if (!d) return -1;
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
    if (d->zk) zk_decoder_close(d->zk);
    free(d);
}

#else /* !HAS_ARCHOERA_KERNEL：内核未链接，编译期空实现（保持可编过） */

struct NativeDecoder { int _unused; };

bool native_decoder_available(void)
{
    return false;
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

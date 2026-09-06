// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * native_decoder.h — 自研 Zig 内核（archoera_kernel）解码器封装
 *
 * engine_mode == EraAudio 时 pipeline 优先尝试 native_decoder_open，
 * 失败（未接管 / 打开错误 / 内核未链接）由调用方回退 FFmpeg decoder_open。
 * 本模块仅封装 include/kernel_bridge.h 的 zk_* C ABI，对齐 decoder.h
 * 的最小公共接口（采样率/声道/时长/codec_name + 读帧），输出 float32 交错。
 */
#ifndef NATIVE_DECODER_H
#define NATIVE_DECODER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NativeDecoder NativeDecoder;

/** 解码源信息（open 成功时填充；字符串生命周期与 NativeDecoder 一致，只读） */
typedef struct NativeInfo {
    int          sample_rate;
    int          channels;
    int          bits_per_sample;
    int64_t      duration_us;
    int          duration_known; /**< 0=exact 1=estimate 2=unknown */
    const char  *codec_name;     /**< 如 "pcm_s16le"（对齐 FFmpeg 命名） */
    const char  *format_name;    /**< 如 "wav" */
} NativeInfo;

/** 内核是否已在构建期链接可用（CMake HAS_ARCHOERA_KERNEL）。 */
bool native_decoder_available(void);

/**
 * 打开自研内核解码器。
 *
 * @param path          输入文件路径
 * @param info          成功时填充解码源信息（可传 NULL）
 * @param status_out    失败时输出稳定状态码（ZkStatus：1=unsupported→应回退
 *                      FFmpeg；2=open_failed 等），成功输出 0；可传 NULL
 * @param errbuf/errbuf_size 失败诊断缓冲（可传 NULL/0）
 * @return 成功返回解码器句柄；失败返回 NULL（未接管/打不开/内核未链接）
 */
NativeDecoder *native_decoder_open(const char *path, NativeInfo *info,
                                   int *status_out,
                                   char *errbuf, int errbuf_size);

/**
 * 解码最多 max_frames 帧 float32 交错 PCM。
 * @return >=0：实际帧数（每声道）；0 = EOF（正常文件尾）；
 *         <0：错误——-1 参数错误，其余为负 ZkStatus 状态码
 *             （如 -3=损坏 / -4=解码失败 / -8=IO 错误），调用方应报错，
 *             不得把 <0 当 EOF 静默截断。
 *         out_channels 输出本帧实际声道数（任何返回值下均有效）。
 */
int native_decoder_read(NativeDecoder *d, float *out, int max_frames,
                        int *out_channels);

/**
 * 跳转到指定毫秒位置（最近可用帧边界）。
 * @return 0 成功，非 0 失败
 */
int native_decoder_seek_ms(NativeDecoder *d, int64_t ms);

/** 获取源音频流参数 */
int native_decoder_sample_rate(const NativeDecoder *d);
int native_decoder_channels(const NativeDecoder *d);
int64_t native_decoder_duration_us(const NativeDecoder *d);
const char *native_decoder_codec_name(const NativeDecoder *d);

/** 关闭并释放（d 为 NULL 时为空操作） */
void native_decoder_close(NativeDecoder *d);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_DECODER_H */

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * kernel_bridge.h — C 壳 → Zig 内核的唯一入口（解码 / DSP 服务）
 *
 * 契约（docs/audio-kernel-zig.md §16.1）：
 *   - 实现位于 kernel/kernel.zig（export fn zk_* callconv(.C)），
 *     内部管线：decoder.zig 工厂 → pcm/convert.zig（原生 → float32 交错）；
 *   - 本头为跨语言唯一契约：结构布局、状态码、返回语义禁止随意改动；
 *   - 线程模型：Zig 内核不持线程，仅被 C 壳（mediaengine_lib.c 引擎线程）调用；
 *   - 内存：Zig 侧统一使用宿主 CRT malloc/free，本层不接管任何所有权。
 *
 * 解码侧（zk_decoder_*）为本阶段已实现符号；DSP 侧（zk_dsp_*）随
 * dsp 模块移植完成加入（Phase A DSP 阶段），届时追加声明。
 */
#ifndef ARCHOERA_KERNEL_BRIDGE_H
#define ARCHOERA_KERNEL_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 稳定状态码（与 kernel/error.zig 的 Status 枚举逐号对齐，禁止重排） */
enum ZkStatus {
    ZK_OK               = 0,
    ZK_UNSUPPORTED      = 1, /**< 未支持 / 未开启的格式 → 回退 FFmpeg 主后端（§8.3） */
    ZK_OPEN_FAILED      = 2,
    ZK_CORRUPT          = 3,
    ZK_DECODE_FAILED    = 4,
    ZK_ABORTED          = 5,
    ZK_SEEK_FAILED      = 6,
    ZK_OUT_OF_MEMORY    = 7,
    ZK_IO_ERROR         = 8
};

/** 解码会话不透明句柄 */
typedef struct ZkDecoder ZkDecoder;

/** 解码源信息（open 时填充；codec_name/format_name 为内核静态字面量，
 *  title…comment 为解码器上下文持有的分配；生命周期均与 ZkDecoder 一致，
 *  C 侧只读不释放） */
typedef struct ZkInfo {
    int         sample_rate;       /**< 采样率（Hz） */
    int         channels;          /**< 声道数（1..8） */
    int         bits_per_sample;   /**< 原生位深（8/16/24/32/64） */
    long long   duration_us;       /**< 时长（微秒），精确度见 duration_known */
    int         duration_known;    /**< 0=exact 1=estimate 2=unknown */
    const char *codec_name;        /**< 如 "pcm_s16le"（对齐 FFmpeg 命名） */
    const char *format_name;       /**< 如 "wav" */
    const char *title;             /**< 标签元数据；缺失为 NULL */
    const char *artist;            /**< 标签元数据；缺失为 NULL */
    const char *album;             /**< 标签元数据；缺失为 NULL */
    const char *date;              /**< 标签元数据；缺失为 NULL */
    const char *genre;             /**< 标签元数据；缺失为 NULL */
    const char *comment;           /**< 标签元数据；缺失为 NULL */
} ZkInfo;

/**
 * 打开解码器（按格式接管开关判定，未接管格式返回 ZK_UNSUPPORTED，
 * C 壳据此回退 FFmpeg 主后端，§8.3）。
 *
 * @param path        输入文件路径（NUL 终止）
 * @param info        成功时填充解码源信息
 * @param errbuf      失败时的诊断缓冲：
 *                      errbuf[0..4] — LE int32 稳定状态码（enum ZkStatus）
 *                      errbuf[4..]  — NUL 终止的人读消息（截断保证终止）
 * @param errbuf_size errbuf 容量（<=0 视为不可写）
 * @return 成功返回 ZkDecoder*；失败返回 NULL
 */
ZkDecoder *zk_decoder_open(const char *path, ZkInfo *info, char *errbuf, int errbuf_size);

/**
 * 解码最多 max_frames 帧 float32 交错 PCM。
 * @return >=0：实际输出帧数（0 = EOF，正常文件尾）；
 *         <0：解码错误，返回值 = -（enum ZkStatus 状态码），
 *             调用方应视为不可恢复解码错误上报，不得按 EOF 静默截断。
 *         out_channels 输出本帧实际声道数（任意返回值下均有效）。
 */
long long zk_decoder_read(ZkDecoder *d, float *out, size_t max_frames, int *out_channels);

/** 跳转到指定毫秒位置（最近可用帧边界）；返回 0 = 成功，非 0 = enum ZkStatus */
int zk_decoder_seek_ms(ZkDecoder *d, long long ms);

/** 当前播放位置（毫秒，自文件开头计） */
long long zk_decoder_position_ms(ZkDecoder *d);

/** 释放解码会话（含底层文件句柄与全部缓冲）；d 为 NULL 时为空操作 */
void zk_decoder_close(ZkDecoder *d);

/* ---- 常驻内核接入 seam（§7 async 主干；加法式，不改动既有路径）---- */

/** 常驻内核句柄（不透明；内核池 + 定容任务槽，见 docs/engine-master-pool-design.md） */
typedef struct ZkEngine ZkEngine;

/**
 * 初始化常驻内核（池 min_workers..max_workers + cap_tasks 任务槽）。
 * @return 句柄；失败（非法参数 / 启动失败）返回 NULL。
 */
ZkEngine *zk_engine_init(int min_workers, int max_workers, int cap_tasks);

/** 停机并释放常驻内核；h 为 NULL 时空操作（停机排空并 join 全部线程）。 */
void zk_engine_shutdown(ZkEngine *h);

/**
 * 池内一次性解码到 out（float32 交错，最多 max_frames 帧）。
 * 表面同步、内里异步：阻塞至完工，内部由内核池并行执行。
 * @return >=0 实际帧数（0=EOF）；<0 = -（enum ZkStatus）。
 *         out_channels 输出实际声道数；info 非空则填充解码源信息（最小字段）。
 *         调用方保证 out 可容纳 max_frames × 最大声道（契约 ≤8）。
 */
long long zk_engine_decode_once(ZkEngine *h, const char *path,
                                float *out, size_t max_frames,
                                int *out_channels, ZkInfo *info);

/** 流式会话句柄（句柄常驻、逐块拉取、池内执行；朝播放迁池 §6.3） */
typedef struct ZkEngineStream ZkEngineStream;

/** 打开流式会话（池 worker 上 probe+open 一次）。失败返回 NULL 并写 errbuf 状态码。 */
ZkEngineStream *zk_engine_open(ZkEngine *h, const char *path,
                               ZkInfo *info, char *errbuf, size_t errbuf_size);

/**
 * 逐步拉块解码到 out（float32 交错，最多 max_frames 帧）。
 * @return >=0 帧数（0=EOF）；<0 = -ZkStatus。out_channels 输出声道数。
 */
long long zk_engine_read(ZkEngineStream *s, float *out,
                         size_t max_frames, int *out_channels);

/** 跳转毫秒；0 = 成功，非 0 = ZkStatus */
int zk_engine_seek_ms(ZkEngineStream *s, long long ms);

/** 当前播放位置（毫秒） */
long long zk_engine_position_ms(ZkEngineStream *s);

/** 关闭会话（池内释放实例）；s 为 NULL 时空操作 */
void zk_engine_close(ZkEngineStream *s);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_KERNEL_BRIDGE_H */

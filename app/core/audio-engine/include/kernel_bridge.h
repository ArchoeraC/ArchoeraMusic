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
 * 解码侧（zk_decoder_*）为本阶段已实现符号；DSP 侧（zk_dsp_eq_* /
 * zk_dsp_limiter_* / zk_dsp_loudness_*）已随 kernel/dsp 落地（方向① 地基），
 * fft / resampler / tempo 仍为内核侧接口占位（未导出，见 kernel/dsp/）。
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
 * 从内存字节切片打开解码器（纯内存源，docs/audio-memory-source.md §7）。
 * 契约与 [zk_decoder_open] 完全一致（info/errbuf/返回语义）；`data` 所有权归调用方，
 * 必须保持有效直至 [zk_decoder_close]。未接管格式同样返回 NULL + ZK_UNSUPPORTED。
 *
 * @param data        内存起始地址（至少 len 字节）
 * @param len         字节数
 */
ZkDecoder *zk_decoder_open_mem(const unsigned char *data, size_t len,
                               ZkInfo *info, char *errbuf, int errbuf_size);

/**
 * 从**宿主回调流**打开解码器（在线流式源，docs/audio-kernel-zig.md §6.1/§7）。
 * 内核保持零网络栈：传输（socket/TLS/Range/重定向）由 C 壳/宿主注入，本层只消费
 * 字节流。契约与 [zk_decoder_open] 完全一致（info/errbuf/返回语义）。
 *
 * `ctx` / `on_read` / `on_seek` 的所有权与生命周期归调用方：须保持有效覆盖整个
 * 解码会话；[zk_decoder_close] 只释放内核内部（peek 缓冲/适配器），**不触碰** ctx。
 *
 * - `on_read(ctx, buf, len)`：填充 buf，返回实际字节数（0 = EOF）；
 * - `on_seek(ctx, off, whence, buffered)`：whence 0=start / 1=current / 2=end；
 *   返回非 0 = 成功。`buffered` = 内核 peek 缓冲中已被丢弃、尚未消费的字节数；
 *   whence=current 时底层流应按 `off - buffered` 相对当前位置前移
 *   （内核逻辑游标在 `pos`，底层流实际领先 `buffered` 字节）。
 * - `size_hint`：已知总字节（0 = 未知，此时 whence=end 不可用）。
 */
typedef size_t (*zk_read_cb)(void *ctx, unsigned char *buf, size_t len);
typedef int (*zk_seek_cb)(void *ctx, long long off, int whence, size_t buffered);

ZkDecoder *zk_decoder_open_cb(void *ctx, zk_read_cb on_read, zk_seek_cb on_seek,
                              unsigned long long size_hint,
                              ZkInfo *info, char *errbuf, int errbuf_size);

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

/* ---- DSP 下沉（kernel/dsp；docs/audio-kernel-zig.md §14，扩张计划方向① 地基）----
 *
 * C 壳 equalizer.c / limiter.c / loudness.c 在 HAS_ARCHOERA_KERNEL 时优先
 * 路由到本组内核实现，create 失败或内核库缺失时回退各自 C 实现——对外
 * 行为与既有 ABI（equalizer_* / limiter_* / loudness_*）不变。
 *
 * 契约（与 C 实现逐函数对应）：
 *   - create：非法参数 / OOM 返回 NULL（调用方回退）；
 *   - process：就地处理**交错 float32**，`samples` 为每声道帧数
 *     （总样本 = samples × channels，由 create 时给定 channels 决定）；
 *   - destroy：NULL 空操作；
 *   - 指针（句柄）生命周期归调用方，错误路径不置全局状态。
 *
 * fft / resampler / tempo 本轮仅内核侧接口占位，导出保持 C 现状（尤其
 * libfft.so 的 Dart ABI 零改动）。
 */

/** 均衡器句柄（内核 10 段 Biquad；不透明） */
typedef struct ZkDspEq ZkDspEq;

/** 创建均衡器（sample_rate>0，channels 1..64）；失败返回 NULL。 */
ZkDspEq *zk_dsp_eq_create(int sample_rate, int channels);

/** 设置 10 段增益（dB，顺序 31.25…16k Hz）；eq/gains 为空时空操作。 */
void zk_dsp_eq_set_gains(ZkDspEq *eq, const float gains[10]);

/** 设置前级增益（dB）。 */
void zk_dsp_eq_set_preamp(ZkDspEq *eq, float preamp_db);

/** 就地处理交错 float32 PCM（samples = 每声道帧数）。 */
void zk_dsp_eq_process(ZkDspEq *eq, float *pcm, int samples);

/** 释放均衡器；NULL 空操作。 */
void zk_dsp_eq_destroy(ZkDspEq *eq);

/** 限幅器句柄（内核软膝压缩；不透明） */
typedef struct ZkDspLimiter ZkDspLimiter;

/** 创建限幅器（默认启用、阈值 −1 dB）；失败返回 NULL。 */
ZkDspLimiter *zk_dsp_limiter_create(int sample_rate, int channels);

/** 启用（enabled != 0）/ 禁用。 */
void zk_dsp_limiter_set_enabled(ZkDspLimiter *lim, int enabled);

/** 设置阈值（dB，默认 −1.0）。 */
void zk_dsp_limiter_set_threshold(ZkDspLimiter *lim, float threshold_db);

/** 当前阈值（dB）；lim 为空时返回默认 −1.0。 */
float zk_dsp_limiter_get_threshold(const ZkDspLimiter *lim);

/** 就地处理交错 float32 PCM（samples = 每声道帧数）。 */
void zk_dsp_limiter_process(ZkDspLimiter *lim, float *pcm, int samples);

/** 释放限幅器；NULL 空操作。 */
void zk_dsp_limiter_destroy(ZkDspLimiter *lim);

/** 响度归一化句柄（内核静态增益补偿；不透明） */
typedef struct ZkDspLoudness ZkDspLoudness;

/** 创建响度实例（默认禁用、目标 −14 LUFS、增益 0 dB）；失败返回 NULL。 */
ZkDspLoudness *zk_dsp_loudness_create(int sample_rate, int channels);

/** 启用（enabled != 0）/ 禁用。 */
void zk_dsp_loudness_set_enabled(ZkDspLoudness *l, int enabled);

/** 设置目标响度（LUFS，默认 −14）。 */
void zk_dsp_loudness_set_target(ZkDspLoudness *l, float target_lufs);

/** 设置预计算增益（dB）。 */
void zk_dsp_loudness_set_gain(ZkDspLoudness *l, float gain_db);

/** 就地处理交错 float32 PCM（samples = 每声道帧数）。 */
void zk_dsp_loudness_process(ZkDspLoudness *l, float *pcm, int samples);

/** 释放响度实例；NULL 空操作。 */
void zk_dsp_loudness_destroy(ZkDspLoudness *l);

/* ---- 常驻内核接入 seam（§7 async 主干；加法式，不改动既有路径）---- */

/** 常驻内核句柄（不透明；内核池 + 定容任务槽，见 docs/engine-master-pool-design.md） */
typedef struct ZkEngine ZkEngine;

/**
 * 初始化常驻内核（池 min_workers..max_workers + cap_tasks 任务槽）。
 * @return 句柄；失败（非法参数 / 启动失败）返回 NULL。
 */
ZkEngine *zk_engine_init(int min_workers, int max_workers, int cap_tasks);

/**
 * 同 zk_engine_init，另指定流式会话并发上限 max_streams（§6.3 硬计数；缺省
 * zk_engine_init 用默认 8）。流计数与 cap_tasks 任务槽分开记账。
 */
ZkEngine *zk_engine_init_streams(int min_workers, int max_workers,
                                 int cap_tasks, int max_streams);

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

/* ---- 结构化任务提交面（§6.1 任务提交面与句柄；加法式，不改动既有路径）---- */

/** 结构化任务句柄（池内异步批次解码；不透明） */
typedef struct ZkTask ZkTask;

/**
 * 提交一次「打开 path → 解码至多 max_frames 帧 float32 交错到 out → 填 info」
 * 的池内任务。**非阻塞**：立即返回句柄，由 [zk_task_wait] 取结果。
 * 语义与 [zk_engine_decode_once] 对齐（>=0 帧数（0=EOF）/ <0 = -（enum ZkStatus））。
 *
 * `out` 所有权归调用方，须存活到 [zk_task_wait] 返回；`path` 同理（worker 异步读取）；
 * `info` 可空，成功打开时填解码源信息（最小字段）。
 * 失败（h/path/out 为空 / max_frames==0 / 池停机 / 任务槽满 InstanceLimit / OOM）
 * 返回 NULL。
 */
ZkTask *zk_submit_decode(ZkEngine *h, const char *path,
                         float *out, size_t max_frames, ZkInfo *info);

/**
 * 等待任务完工（阻塞，无轮询）。返回 >=0 帧数（0=EOF）/ <0 = -（enum ZkStatus）。
 * t 为 NULL 返回 -（ZK_IO_ERROR）。完工事件保持置位 → 可重复调用（幂等）。
 */
long long zk_task_wait(ZkTask *t);

/**
 * 释放任务句柄（t 为 NULL 时空操作）。内部先 wait 收尾（幂等），未显式 wait 直接
 * free 也不悬垂。**同一句柄只可 free 一次**（重复 free 属未定义行为，契约明确）。
 */
void zk_task_free(ZkTask *t);

/** 流式会话句柄（句柄常驻、逐块拉取、池内执行；朝播放迁池 §6.3） */
typedef struct ZkEngineStream ZkEngineStream;

/** 打开流式会话（池 worker 上 probe+open 一次）。失败返回 NULL 并写 errbuf 状态码。 */
ZkEngineStream *zk_engine_open(ZkEngine *h, const char *path,
                               ZkInfo *info, char *errbuf, size_t errbuf_size);

/**
 * AS2：打开**专属 worker（pinned 1:1）**流式会话（契约同 [zk_engine_open]）。
 * 会话所有步骤在该 worker 上串行执行、不进全局队列、不参与回收；无空闲 worker 时
 * 自动回退全局队列模式（行为/可用性不变）。`zk_engine_stream_pinned` 查询是否命中。
 */
ZkEngineStream *zk_engine_open_pinned(ZkEngine *h, const char *path,
                                      ZkInfo *info, char *errbuf, size_t errbuf_size);

/** AS2：该流式会话是否命中专属 worker；1 = 是，0 = 否/NULL。 */
int zk_engine_stream_pinned(ZkEngineStream *s);

/**
 * 同上，但从**内存字节切片**打开（纯内存源，docs/audio-memory-source.md §7）。
 * `data` 所有权归调用方，须覆盖会话生命周期。
 */
ZkEngineStream *zk_engine_open_mem(ZkEngine *h, const unsigned char *data, size_t len,
                                   ZkInfo *info, char *errbuf, size_t errbuf_size);

/**
 * 同上，但从**宿主回调流**打开（在线流式源）。ctx/回调生命周期归调用方；
 * 内核自持 peek 缓冲，close 释放，不触碰 ctx。签名见上方 zk_read_cb/zk_seek_cb。
 */
ZkEngineStream *zk_engine_open_cb(ZkEngine *h, void *ctx,
                                  zk_read_cb on_read, zk_seek_cb on_seek,
                                  unsigned long long size_hint,
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

/* ---- 元数据快路径（§8.4.2①；结构化 ABI，无 JSON，供 scanner 直桥）---- */

/** 标签键值（指针 + 显式长度；生命周期与 metadata 句柄一致，只读不释放） */
typedef struct ZkTag {
    const char *key;   int key_len;
    const char *value; int value_len;
} ZkTag;

/** 元数据信息（标量 + 标准字段 + 全量 tags + 首张封面；指针生命周期同句柄） */
typedef struct ZkMetaInfo {
    int         sample_rate;
    int         channels;
    int         bits_per_sample;
    long long   duration_us;
    int         duration_known;   /**< 0=exact 1=estimate 2=unknown */
    const char *codec_name;
    const char *format_name;
    const char *profile;          /**< 可空 */
    const char *title;            /**< 以下可空 */
    const char *artist;
    const char *album;
    const char *date;
    const char *genre;
    const char *comment;
    const ZkTag *tags;            /**< 全量标签；无则 NULL */
    int         tags_count;
    const char *cover_mime;  int cover_mime_len;
    const unsigned char *cover_data; int cover_size;
} ZkMetaInfo;

/** 元数据句柄（不透明；持有解码器 ctx 与 tags 数组生命周期） */
typedef struct ZkMetaHandle ZkMetaHandle;

/**
 * 打开元数据句柄（probe+open，不解码 PCM）。成功填 *out 并返回句柄；
 * 失败返回 NULL 并写 errbuf[0..4] = LE ZkStatus。
 */
ZkMetaHandle *zk_metadata_open(const char *path, ZkMetaInfo *out,
                               char *errbuf, int errbuf_size);

/** 释放元数据句柄（含 tags 数组与底层 ctx）。NULL 空操作。 */
void zk_metadata_close(ZkMetaHandle *h);

/** scanner 按自身指标协商并发提示（0 = 自动）；内核 metadata 池/限流参考。 */
void zk_metadata_set_concurrency(int n);

/** 回读当前并发提示。 */
int zk_metadata_get_concurrency(void);

/* ---- AS1 结构化任务提交面（kind/source/format/hint + 句柄；wait_event 推模式）----
 *
 * 统一入口：一次调用携带 任务种类（kind）/ 源形态（source）/ 格式提示（format_hint）
 * 与输出缓冲，**非阻塞**返回句柄；由 [zk_task_wait] 阻塞收完工事件（无轮询）。
 * 既有 [zk_submit_decode]（decode/路径专用）保留为便捷包装，语义与之一致；
 * 既有 zk_engine_* / zk_decoder_* **不变**。
 *
 * `format_hint` 当前仅携带与校验（自动探测仍由内核 probe 决定），为 AS4 预计算
 * 免 probe 预留；`flags` 为保留位，须为 0。失败（参数非法 / 池停机 / 任务槽满
 * InstanceLimit / OOM）返回 NULL；若提供 errbuf，失败时写 errbuf[0..4] = LE ZkStatus。
 */
enum ZkSubmitKind {
    ZK_KIND_DECODE   = 0, /**< out/max_frames 解码至多该帧数 */
    ZK_KIND_METADATA = 1  /**< 只 probe+open，填 *meta（仅 source=path） */
};
enum ZkSubmitSource {
    ZK_SOURCE_PATH = 0,
    ZK_SOURCE_MEM  = 1,
    ZK_SOURCE_CB   = 2
};
enum ZkSubmitOutcome {
    ZK_SUBMIT_PENDING = 0,
    ZK_SUBMIT_DONE    = 1,
    ZK_SUBMIT_ERROR   = 2,
    ZK_SUBMIT_FATAL   = 3 /**< 不可预知输入 → 会话级收尾（§5.2 层1） */
};

typedef struct ZkSubmitReq {
    int      kind;         /**< enum ZkSubmitKind */
    int      source;       /**< enum ZkSubmitSource */
    unsigned format_hint;  /**< 格式提示（0=auto；当前仅携带/校验） */
    unsigned flags;        /**< 保留，须为 0 */

    /* source = ZK_SOURCE_PATH */
    const char *path;
    /* source = ZK_SOURCE_MEM（data 所有权归调用方，须覆盖到 wait 返回） */
    const unsigned char *data; size_t len;
    /* source = ZK_SOURCE_CB（ctx/回调生命周期归调用方，须覆盖到 wait 返回） */
    void *ctx; zk_read_cb on_read; zk_seek_cb on_seek; unsigned long long size_hint;

    /* kind = ZK_KIND_DECODE：float32 交错输出（调用方所有，须覆盖到 wait 返回） */
    float *out; size_t max_frames; int *out_channels; /**< out_channels 可空 */
    ZkInfo *info;      /**< 可空；成功时填源信息（decode/metadata） */

    /* kind = ZK_KIND_METADATA：结构化元数据输出（tags/封面指针生命周期同句柄） */
    ZkMetaInfo *meta;

    /* 诊断缓冲（可空）；失败时 errbuf[0..4] = LE ZkStatus，其后 NUL 消息 */
    char *errbuf; int errbuf_size;
} ZkSubmitReq;

/**
 * 结构化提交。立即返回句柄；失败返回 NULL（见上）。语义：
 *   - decode：等价 [zk_submit_decode]（支持 path/mem/cb 三种源）；
 *   - metadata：等价 [zk_metadata_open] 的池内异步版（仅 path），填 *meta。
 * 句柄生命周期：zk_submit → zk_task_wait（可重复，幂等）→ zk_task_free。
 */
ZkTask *zk_submit(ZkEngine *h, const ZkSubmitReq *req);

/** 完工结果（enum ZkSubmitOutcome）；t 为 NULL → PENDING。 */
int zk_task_outcome(ZkTask *t);

/** 负 ZkStatus（失败）/ 0（成功或进行中）；t 为 NULL → -（ZK_IO_ERROR）。 */
int zk_task_status(ZkTask *t);

/** decode 帧数（0=EOF）；非 decode 任务返回 0。 */
long long zk_task_frames(ZkTask *t);

/** 带超时 wait（毫秒）：1=已完工，0=超时；t 为 NULL → 0。 */
int zk_task_wait_timeout(ZkTask *t, long long timeout_ms);

/* ---- 能力扩张 ABI 扩展锚点（并行开发占位；各方向实现时替换本行下方锚点）----
 * 说明：以下四行是并行分支的**互不重叠**插入点，避免同一文件合并冲突。
 * 实现分支只替换属于自己的那一个锚点，禁止改动其他锚点。 */
/* ---- 方向① D1/D2：参数化 EQ + 次声低频管理（kernel/dsp/parametric.zig / lowfreq.zig）----
 *
 * 与既有 10 段 EQ 并列的加法式能力：C 壳 `parametric_eq.c` / `lowfreq.c` 在
 * HAS_ARCHOERA_KERNEL 时优先路由本组内核实现，create 失败或内核库缺失时回退
 * 各自纯 C 实现——对外 C API 行为一致。
 *
 * 契约（与 zk_dsp_eq_* 一致）：
 *   - create：非法参数 / OOM 返回 NULL（调用方回退）；
 *   - process：就地处理**交错 float32**，`samples` 为每声道帧数
 *     （总样本 = samples × channels，由 create 时给定 channels 决定）；
 *   - destroy：NULL 空操作；其余 setter：句柄为 NULL 时空操作。
 *
 * 旁通纪律：整链未启用 / 无有效段 / 全零增益且 preamp=0 时逐位不变。
 */

/** 参数 EQ 段类型（数值与 Zig `EraBandKind` 对齐，禁止重排） */
enum ZkBandKind {
    ZK_BAND_PEAK       = 0, /**< 峰值（peaking） */
    ZK_BAND_LOW_SHELF  = 1, /**< 低架（low-shelf） */
    ZK_BAND_HIGH_SHELF = 2  /**< 高架（high-shelf） */
};

/** 参数化 EQ 句柄（内核 Biquad；不透明） */
typedef struct ZkDspPeq ZkDspPeq;

/**
 * 创建参数化 EQ（sample_rate>0，channels 1..64，max_bands 夹取 [1,16]）；
 * 失败返回 NULL（调用方回退纯 C 实现）。初始无段 = 直通。
 */
ZkDspPeq *zk_dsp_peq_create(int sample_rate, int channels, int max_bands);

/**
 * 设置单段（index < max_bands；kind 见 enum ZkBandKind）。
 * freq 夹取到 (0, Nyquist)，Q 夹取到合理范围，非有限增益按 0 dB；
 * 越界 index 空操作，未知 kind 使该段禁用。活动段数 = max(活动段数, index+1)。
 */
void zk_dsp_peq_set_band(ZkDspPeq *eq, int index, int kind,
                         float freq, float q, float gain_db);

/** 启用（enabled != 0）/ 禁用整链。 */
void zk_dsp_peq_set_enabled(ZkDspPeq *eq, int enabled);

/** 设置前级增益（dB）。 */
void zk_dsp_peq_set_preamp(ZkDspPeq *eq, float preamp_db);

/** 复位段表（活动段数归零）与滤波器状态；preamp 保留。 */
void zk_dsp_peq_clear(ZkDspPeq *eq);

/** 就地处理交错 float32 PCM（samples = 每声道帧数）。 */
void zk_dsp_peq_process(ZkDspPeq *eq, float *pcm, int samples);

/** 释放参数化 EQ；NULL 空操作。 */
void zk_dsp_peq_destroy(ZkDspPeq *eq);

/** 次声/低频管理句柄（HPF + bass shelf；不透明） */
typedef struct ZkDspLowFreq ZkDspLowFreq;

/** 创建次声低频管理块（sample_rate>0，channels 1..64）；失败返回 NULL。 */
ZkDspLowFreq *zk_dsp_lowfreq_create(int sample_rate, int channels);

/** 整块启用（enabled != 0）/ 禁用（默认禁用 = 逐位旁通）。 */
void zk_dsp_lowfreq_set_enabled(ZkDspLowFreq *lf, int enabled);

/**
 * 设置高通（subsonic）：freq<=0 或非有限 → 关闭 HPF；
 * order 夹取到 1 / 2（二阶为 Butterworth Q=0.7071）。
 */
void zk_dsp_lowfreq_set_hpf(ZkDspLowFreq *lf, float freq, int order);

/** 设置 bass shelf（gain_db 为 0 时自然旁通；freq 夹取到 (0, Nyquist)）。 */
void zk_dsp_lowfreq_set_bass(ZkDspLowFreq *lf, float gain_db, float freq);

/** 就地处理交错 float32 PCM（samples = 每声道帧数）。 */
void zk_dsp_lowfreq_process(ZkDspLowFreq *lf, float *pcm, int samples);

/** 释放次声低频管理块；NULL 空操作。 */
void zk_dsp_lowfreq_destroy(ZkDspLowFreq *lf);

/* ---- N4 流式 Reader 缓冲预算（__BRIDGE_STREAM_BUDGET__）----
 *
 * 每路 callback Reader 自持一个 peek 缓冲；内核按进程预算记账。
 * 默认预算 = 0（不限）、每路 16 KiB（与既有行为逐字节一致）。
 */
/** 当前所有 callback Reader peek 缓冲已用字节。 */
unsigned long long zk_stream_mem_used(void);
/** 设置目标内存预算（字节）；0 = 不限（默认）。仅影响之后新分配的缓冲。 */
void zk_stream_mem_set_budget(unsigned long long bytes);
/** 设置每路 callback Reader 缓冲目标大小（夹取到 [16 KiB, 64 KiB]）。 */
void zk_stream_peek_set_bytes(unsigned int bytes);
/** 当前每路 callback Reader 缓冲目标大小（默认 16 KiB）。 */
unsigned int zk_stream_peek_bytes(void);

/* __BRIDGE_TAKEOVER__ */
/* ---- AS6 可观测聚合 + AS5 取消（__BRIDGE_ENGINE_STATS__）---- */
/** 内核池 + 流式会话聚合计数（只读快照）。 */
typedef struct ZkEngineStats {
    unsigned long long active;              /**< 可服役 worker 数 */
    unsigned long long running;             /**< 当前在跑任务数 */
    unsigned long long idle;                /**< 在役空闲 worker 数 */
    unsigned long long pinned;              /**< pinned（长流专属）槽数 */
    unsigned long long inflight;            /**< 排队 + 在途任务数 */
    unsigned long long stall_count;         /**< 停滞放弃累计 */
    unsigned long long spawn_count;         /**< 成功创建 worker 累计 */
    unsigned long long spawn_failed_count;  /**< spawn 失败累计 */
    unsigned long long stream_count;        /**< 当前流式会话数 */
} ZkEngineStats;

/** AS6：聚合 [zk_engine_init] 的池计数写入 out（h/out 为空时空操作）。 */
void zk_engine_stats(const ZkEngine *h, ZkEngineStats *out);

/**
 * AS5：请求取消池内结构化任务（t 为空时空操作）。任务在 chunk 边界协作响应：
 * [zk_task_wait] 返回 -ZK_ABORTED，[zk_task_outcome] 返回 ZK_SUBMIT_ERROR。
 */
void zk_task_cancel(ZkTask *t);

/* ---- AS4 格式提示（稳定数值；0 = unknown/auto）----
 * 与 kernel/probe.zig 的 FormatHint 逐值对齐，一经发布不得重排。
 * [ZkSubmitReq.format_hint] 携带该值：非 0 时内核免 probe 直分派，失败回退 probe。
 */
enum ZkFormatHint {
    ZK_FMT_UNKNOWN    = 0,
    ZK_FMT_WAV        = 1,
    ZK_FMT_FLAC       = 2,
    ZK_FMT_MP3        = 3,
    ZK_FMT_OGG_OPUS   = 4,
    ZK_FMT_OGG_VORBIS = 5,
    ZK_FMT_OGG_FLAC   = 6,
    ZK_FMT_OGG_SPEEX  = 7,
    ZK_FMT_M4A        = 8,
    ZK_FMT_AAC        = 9,
    ZK_FMT_LATM       = 10,
    ZK_FMT_APE        = 11,
    ZK_FMT_WV         = 12,
    ZK_FMT_SHN        = 13,
    ZK_FMT_TAK        = 14,
    ZK_FMT_DSD        = 15,
    ZK_FMT_AMR        = 16,
    ZK_FMT_AMRWB      = 17,
    ZK_FMT_AC3        = 18,
    ZK_FMT_MLP        = 19,
    ZK_FMT_TRUEHD     = 20,
    ZK_FMT_WMA        = 21,
    ZK_FMT_DTS        = 22,
    ZK_FMT_MKA        = 23,
    ZK_FMT_MPC        = 24,
    ZK_FMT_TTA        = 25
};

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_KERNEL_BRIDGE_H */

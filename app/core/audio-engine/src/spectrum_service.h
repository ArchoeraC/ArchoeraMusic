// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_service.h — 频谱 v2 引擎侧推送服务（docs/spectrum-analyzer.md §3/§5）
 *
 * 职责：独立线程按固定间隔读取「已播放位置」的 PCM 窗口 → 调内核
 * `zk_dsp_spectrum_*` 做 VQT 分析 → 通过 emit 回调把 128 带结果交给引擎
 * 事件队列。纯计算在 kernel/dsp/spectrum.zig；本文件只做取窗、线程与节流。
 *
 * 约束：
 *   - 懒初始化：create 只分配服务壳，不建 VQT 核；首次 start 才创建分析器；
 *   - 零每帧分配：输入/输出缓冲在 create 时一次性分配；
 *   - 独立线程：不占用解码 worker 池，不在音频回调做 FFT；
 *   - 可丢：取窗失败 / 消费端慢时直接跳过本帧，绝不反压音频线程；
 *   - stop 每 10ms 检查一次，join 在 ~10ms 内返回。
 *
 * 无 Zig 内核（HAS_ARCHOERA_KERNEL 未定义）时编译为空实现：create 返回 NULL，
 * start 返回 -1；引擎据此禁用频谱，不影响播放。
 */
#ifndef ERA_SPECTRUM_SERVICE_H
#define ERA_SPECTRUM_SERVICE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EraSpectrumService EraSpectrumService;

/**
 * 读取以 [end_pos_ms] 为终点的最近 [frames] 个每声道样本。
 * 返回 0 成功；非 0 表示未命中/未解码/参数错误（本帧跳过）。
 */
typedef int (*EraSpectrumReadFn)(void *ctx, int end_pos_ms, int frames,
                                 float *out_l, float *out_r);

/** 当前绝对播放位置（ms）；返回 < 0 表示暂无有效位置（本帧跳过）。 */
typedef int (*EraSpectrumPositionFn)(void *ctx);

/**
 * 每帧回调：l/r/peak_l/peak_r 长度 [bins]，值域 [0,1]；beat 0..1；
 * seq 单调递增；interval_ms 为目标间隔（50/300/1000）。回调运行在频谱线程，
 * 不得阻塞。
 */
typedef void (*EraSpectrumEmitFn)(void *ctx,
                                  const float *l, const float *r,
                                  const float *peak_l, const float *peak_r,
                                  int bins, float beat, int seq,
                                  int interval_ms);

typedef struct EraSpectrumServiceConfig {
    int sample_rate;      /**< 管线实际输出采样率（>0） */
    int bins;             /**< 输出频段数（128） */
    float min_hz;         /**< 40 */
    float max_hz;         /**< 16000 */
    int interval_ms;      /**< 0 → 50 */
    int frames;           /**< 取窗样本数；0 → 12288（VQT 最长窗） */
    EraSpectrumReadFn read;         /**< 必填 */
    EraSpectrumPositionFn position; /**< 必填 */
    EraSpectrumEmitFn emit;         /**< 必填 */
    void *ctx;                      /**< 透传给三个回调 */
} EraSpectrumServiceConfig;

/** 创建服务壳（不建分析器/线程）；参数非法或 OOM 返回 NULL。 */
EraSpectrumService *era_spectrum_service_create(const EraSpectrumServiceConfig *cfg);

/** 停止线程并释放全部资源；NULL 空操作。 */
void era_spectrum_service_destroy(EraSpectrumService *s);

/** 启动推送线程（幂等）；分析器首次 start 时懒创建。成功 0，失败 -1。 */
int era_spectrum_service_start(EraSpectrumService *s);

/** 停止推送线程（幂等）；join 在 ~10ms 内返回。 */
void era_spectrum_service_stop(EraSpectrumService *s);

/** 清空帧间状态（seek / 切歌 / 会话重建）；不停止线程。 */
void era_spectrum_service_reset(EraSpectrumService *s);

/** 设置峰值保持开关（默认关）；关闭时清空峰值线。 */
void era_spectrum_service_set_peak_hold(EraSpectrumService *s, bool enabled);

/** 是否运行中。 */
bool era_spectrum_service_is_running(const EraSpectrumService *s);

#ifdef __cplusplus
}
#endif

#endif /* ERA_SPECTRUM_SERVICE_H */

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * mediaengine_internal.h — 引擎内部/白盒测试接口（不导出、不承诺 ABI）
 *
 * v1 拉模式删除后，引擎不再向外提供 `pcm_window` / `pcm_epoch` C ABI。
 * 需要按播放位置取 PCM 窗口的只剩引擎自己的频谱线程；测试直接编译
 * `mediaengine_lib.c` 并调用这里的实现，与生产路径共用同一份取窗逻辑。
 *
 * 红线：
 *   - 这些符号不带 `ARCHOERA_MEDIAENGINE_API`、不进 Windows .def，也不承诺
 *     跨版本稳定；Dart/第三方不得链接。
 *   - `era_mediaengine_read_window` 是生产频谱取窗路径（按模式分派）；
 *     `era_mediaengine_mem_window` 是用 blocking lock + 曲尾截断的白盒版本，
 *     仅供确定性测试/诊断。
 */
#ifndef ERA_MEDIAENGINE_INTERNAL_H
#define ERA_MEDIAENGINE_INTERNAL_H

#include "archoera_mediaengine.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 按播放位置取一帧 PCM 窗口（频谱线程同一实现）：
 *   - 内存模式：块列表（`try_lock`；尾部未解码返回 -1，服务层据此退回因果窗）；
 *   - 流式：最近 PCM 环形缓冲；文件：`stream.pcm` 增量索引。
 *
 * @return 0 命中；-1 未命中/未解码/模式不匹配；-2 参数错误（含 e == NULL）。
 */
int era_mediaengine_read_window(ArchoeraMediaEngine *e, int end_pos_ms,
                                int frames, float *out_l, float *out_r);

/**
 * 内存块窗口（白盒，blocking lock）：以 [end_pos_ms] 为终点取最近 [frames]
 * 样本；end 超过末尾时按「最后一块末尾」截断（与旧 pcm_window 语义一致）。
 * 仅供测试与诊断，不参与生产路径。
 *
 * @return 0 命中；-1 越出保留窗 / 尚未解码；-2 参数错误或非内存模式。
 */
int era_mediaengine_mem_window(ArchoeraMediaEngine *e, int end_pos_ms,
                               int frames, float *out_l, float *out_r);

/** 内存会话重建计数（seek 重建 +1）；NULL 返回 -1。 */
int era_mediaengine_mem_epoch(ArchoeraMediaEngine *e);

/**
 * stage[0] 的媒体时间：PCM 回调的 `position_ms` 是**本块起始**（见
 * `pipeline.c::process_dsp_chain`），stage 缓冲也从本块首样本开始，故直接
 * 返回块起点。白盒回归：旧实现再减一个块时长，commit 时多丢一块暂存数据，
 * 切档后声音相对进度条前跳约一个解码块（MP3/AAC ≈ 20~26ms，FLAC 更大）。
 */
double era_mediaengine_stage_block_origin_ms(double block_start_ms);

#ifdef __cplusplus
}
#endif

#endif /* ERA_MEDIAENGINE_INTERNAL_H */

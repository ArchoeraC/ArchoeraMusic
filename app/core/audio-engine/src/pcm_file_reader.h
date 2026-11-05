// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * pcm_file_reader.h — 文件模式 stream.pcm 的按位置取窗读取器（频谱线程用）
 *
 * 文件模式（ARCHOERA_ENGINE_FILE_MODE=1）下引擎把解码 PCM 直写会话目录
 * stream.pcm。块格式（小端）：
 *   [int32 pos_ms][int32 samples][int32 channels] + samples*channels 个 float32
 *
 * 本读取器只维护块索引（pos_ms / 文件偏移 / 每块样本数 / 全局样本起点），
 * 不缓存全量 PCM；每次读取按需从独立 FILE* 定位读窗口并下混为 L/R：
 *   - 增量扫描：每次 read 先按当前文件长度补索引，块未写完即停止；
 *   - 文件变短 / 块头非法 / pos_ms 回退 → 视为 seek 截断重建，清空重扫；
 *   - 以 end_pos_ms 为终点向前取最近 frames 个样本，窗口可跨块；
 *   - 前缀不足（早于文件首样本）补零；尾部未解码（终点越过最后一个完整块）
 *     返回 -1，不做半截窗口。
 *
 * pos_ms 语义：按块头原样建索引，当前引擎写的是块起始时间。
 * 读取方不假设块头/块尾，只信任块头。
 *
 * 线程模型：仅由频谱线程调用；内部使用独立 FILE*，不与写线程共享文件位置。
 */

#ifndef ERA_PCM_FILE_READER_H
#define ERA_PCM_FILE_READER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EraPcmFileReader EraPcmFileReader;

/** 打开 stream.pcm（可正在增长）；sample_rate 为输出采样率。失败返回 NULL。 */
EraPcmFileReader *era_pcm_file_reader_open(const char *path, int sample_rate);

/** 关闭并释放（NULL 安全）。 */
void era_pcm_file_reader_close(EraPcmFileReader *r);

/** 清空索引（seek 截断重建 / 会话重建）；下次 read 从文件头重扫。 */
void era_pcm_file_reader_reset(EraPcmFileReader *r);

/** 以 end_pos_ms 为终点取最近 frames 个样本，下混为 L/R。
 *  0 成功；-1 未命中/未解码/被淘汰；-2 参数错误。 */
int era_pcm_file_reader_read(EraPcmFileReader *r, int end_pos_ms, int frames,
                             float *out_l, float *out_r);

#ifdef __cplusplus
}
#endif

#endif /* ERA_PCM_FILE_READER_H */

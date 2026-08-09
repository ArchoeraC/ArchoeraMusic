/**
 * loudness.h — EBU R128 响度归一化
 *
 * 支持两种模式：
 *   1. 扫描模式：测量整曲的集成响度（用于预计算增益）
 *   2. 应用模式：使用预计算的增益进行实时归一化
 */
#ifndef LOUDNESS_H
#define LOUDNESS_H

#include <stdbool.h>

typedef struct Loudness Loudness;

/**
 * 创建响度归一化实例
 *
 * @param sample_rate  采样率（Hz）
 * @param channels     声道数
 * @return 实例，失败返回 NULL
 */
Loudness* loudness_create(int sample_rate, int channels);

/**
 * 启用/禁用响度归一化
 *
 * @param loud    实例
 * @param enabled 是否启用
 */
void loudness_set_enabled(Loudness *loud, bool enabled);

/**
 * 设置目标响度
 *
 * @param loud       实例
 * @param target_lufs 目标响度（LUFS），默认 -14
 */
void loudness_set_target(Loudness *loud, float target_lufs);

/**
 * 设置预计算的增益（跳过扫描直接使用）
 *
 * @param loud      实例
 * @param gain_db   增益值（dB）
 */
void loudness_set_gain(Loudness *loud, float gain_db);

/**
 * 处理 PCM 数据（就地修改）
 *
 * @param loud    实例
 * @param pcm     交错 float PCM 数据
 * @param samples 样本数（每声道）
 */
void loudness_process(Loudness *loud, float *pcm, int samples);

/** 销毁实例 */
void loudness_destroy(Loudness *loud);

#endif /* LOUDNESS_H */

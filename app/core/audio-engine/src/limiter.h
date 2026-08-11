/**
 * limiter.h — 输出限幅器
 *
 * 防止 EQ/前级增益导致的削波
 */
#ifndef LIMITER_H
#define LIMITER_H

#include <stdbool.h>

typedef struct Limiter Limiter;

/**
 * 创建限幅器实例
 *
 * @param sample_rate  采样率（Hz）
 * @param channels     声道数
 * @return 实例，失败返回 NULL
 */
Limiter* limiter_create(int sample_rate, int channels);

/**
 * 启用/禁用限幅器
 *
 * @param lim     实例
 * @param enabled 是否启用
 */
void limiter_set_enabled(Limiter *lim, bool enabled);

/**
 * 设置阈值
 *
 * @param lim       实例
 * @param threshold_db 阈值（dB），默认 -1.0
 */
void limiter_set_threshold(Limiter *lim, float threshold_db);

/**
 * 处理 PCM 数据（就地修改）
 *
 * @param lim     实例
 * @param pcm     交错 float PCM 数据
 * @param samples 样本数（每声道）
 */
void limiter_process(Limiter *lim, float *pcm, int samples);

/** 获取当前阈值（dB） */
float limiter_get_threshold(const Limiter *lim);

/** 销毁实例 */
void limiter_destroy(Limiter *lim);

#endif /* LIMITER_H */

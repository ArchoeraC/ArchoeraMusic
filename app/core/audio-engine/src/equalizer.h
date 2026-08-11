/**
 * equalizer.h — 10 段 Biquad IIR 均衡器
 *
 * 频段（ISO 标准）：31.25, 62.5, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz
 * 每段支持 -12dB ~ +12dB 增益
 */
#ifndef EQUALIZER_H
#define EQUALIZER_H

#include <stdbool.h>

#define EQ_BANDS 10

typedef struct Equalizer Equalizer;

/**
 * 创建均衡器实例
 *
 * @param sample_rate  采样率（Hz）
 * @param channels     声道数
 * @return 均衡器实例，失败返回 NULL
 */
Equalizer* equalizer_create(int sample_rate, int channels);

/**
 * 设置各频段增益
 *
 * @param eq     均衡器实例
 * @param gains  10 个频段的增益值（dB），范围 -12 ~ +12
 */
void equalizer_set_gains(Equalizer *eq, const float gains[EQ_BANDS]);

/**
 * 设置前级增益
 *
 * @param eq       均衡器实例
 * @param preamp_db 前级增益（dB），范围 -12 ~ +12
 */
void equalizer_set_preamp(Equalizer *eq, float preamp_db);

/**
 * 处理 PCM 数据（就地修改）
 *
 * @param eq        均衡器实例
 * @param pcm       交错 float PCM 数据
 * @param samples   样本数（每声道）
 */
void equalizer_process(Equalizer *eq, float *pcm, int samples);

/** 销毁均衡器 */
void equalizer_destroy(Equalizer *eq);

#endif /* EQUALIZER_H */

/**
 * resampler.h — 音频重采样器（基于 FFmpeg libswresample）
 *
 * 将解码器输出的任意采样率/声道/格式的 PCM 转换为目标格式。
 */
#ifndef RESAMPLER_H
#define RESAMPLER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Resampler Resampler;

/**
 * 创建重采样器
 *
 * @param in_rate     输入采样率
 * @param in_channels 输入声道数
 * @param in_format   输入 AVSampleFormat
 * @param out_rate    输出采样率（Opus 需要 48000）
 * @param out_channels 输出声道数
 * @return 实例指针，失败返回 NULL
 */
Resampler* resampler_create(int in_rate, int in_channels, int in_format,
                             int out_rate, int out_channels);

/**
 * 设置输入格式（解码第一帧后才知道实际格式，可延迟设置）
 * @return 0 成功，<0 失败
 */
int resampler_set_input_format(Resampler *r, int in_rate, int in_channels, int in_format);

/**
 * 将输入 PCM 转换为目标格式
 *
 * @param in_data      输入数据（各声道交错或平面，取决于 in_format）
 * @param in_samples   输入帧数（每声道）
 * @param out_buf      输出缓冲区（float 交错，out_channels * out_samples * sizeof(float)）
 * @param out_capacity 输出缓冲区能容纳的最大帧数（每声道）
 * @return 输出帧数（每声道），<0 表示错误
 */
int resampler_process(Resampler *r,
                      const uint8_t **in_data, int in_samples,
                      float *out_buf, int out_capacity);

/**
 * flush 残留样本
 * @return flush 出的帧数
 */
int resampler_flush(Resampler *r, float *out_buf, int out_capacity);

/** 查询是否已初始化（输入格式确定后才会真正创建 swr） */
bool resampler_is_initialized(const Resampler *r);

/** 获取已输出的采样数（用于计算播放位置） */
long long resampler_get_output_samples(const Resampler *r);

/** 销毁 */
void resampler_destroy(Resampler *r);

#ifdef __cplusplus
}
#endif

#endif /* RESAMPLER_H */

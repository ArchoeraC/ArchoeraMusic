/**
 * encoder.h — OGG/Opus 编码器
 *
 * 将 PCM float 数据编码为 Opus 包，并封装为 OGG 容器流。
 * 通过 OutputCallback 输出封装后的字节流。
 */
#ifndef ENCODER_H
#define ENCODER_H

#include <stddef.h>
#include <stdint.h>
#include "../include/audio_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Encoder Encoder;

/**
 * 创建编码器
 *
 * @param sample_rate 输出采样率（Opus 固定 48000）
 * @param channels    输出声道数
 * @param bitrate     Opus 比特率（bps）
 * @param frame_size_ms 帧时长（毫秒，通常 20）
 * @param output      输出回调
 * @param user        回调 user_data
 */
Encoder* encoder_create(int sample_rate, int channels, int bitrate,
                         int frame_size_ms,
                         OutputCallback output, void *user);

/**
 * 写入 PCM float 数据（交错格式）
 *
 * 内部累积到 frame_size 后编码并封装输出。
 * 可多次调用，不足一帧的数据会暂存。
 *
 * @param pcm     PCM float 交错数据
 * @param samples 帧数（每声道）
 * @return 0 成功，<0 错误
 */
int encoder_write_pcm(Encoder *e, const float *pcm, int samples);

/** flush 编码器并写完 OGG 尾页 */
int encoder_flush(Encoder *e);

/** 销毁 */
void encoder_destroy(Encoder *e);

#ifdef __cplusplus
}
#endif

#endif /* ENCODER_H */

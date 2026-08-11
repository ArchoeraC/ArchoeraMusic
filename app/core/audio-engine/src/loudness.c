/**
 * loudness.c — EBU R128 响度归一化
 *
 * 简化实现：使用静态增益补偿（不对实时流做动态归一化，避免延迟）
 * 完整 EBU R128 需要测量集成响度，这里提供预计算增益模式
 */
#include "loudness.h"
#include <stdlib.h>
#include <math.h>

#define LOG_TAG "[audio-engine:loudness]"
#include <stdio.h>

struct Loudness {
    int sample_rate;
    int channels;
    bool enabled;
    float target_lufs;
    float gain_db;
    float gain_linear;
};

Loudness* loudness_create(int sample_rate, int channels)
{
    Loudness *loud = calloc(1, sizeof(*loud));
    if (!loud) return NULL;

    loud->sample_rate = sample_rate;
    loud->channels = channels;
    loud->enabled = false;
    loud->target_lufs = -14.0f;  /* EBU R128 标准 */
    loud->gain_db = 0.0f;
    loud->gain_linear = 1.0f;

    fprintf(stderr, "%s 创建: %dHz / %dch / 目标 %.1f LUFS\n",
            LOG_TAG, sample_rate, channels, loud->target_lufs);
    return loud;
}

void loudness_set_enabled(Loudness *loud, bool enabled)
{
    if (!loud) return;
    loud->enabled = enabled;
    fprintf(stderr, "%s %s\n", LOG_TAG, enabled ? "启用" : "禁用");
}

void loudness_set_target(Loudness *loud, float target_lufs)
{
    if (!loud) return;
    loud->target_lufs = target_lufs;
}

void loudness_set_gain(Loudness *loud, float gain_db)
{
    if (!loud) return;
    loud->gain_db = gain_db;
    loud->gain_linear = powf(10.0f, gain_db / 20.0f);
    fprintf(stderr, "%s 设置增益: %.2f dB (%.3fx)\n",
            LOG_TAG, gain_db, loud->gain_linear);
}

void loudness_process(Loudness *loud, float *pcm, int samples)
{
    if (!loud || !pcm || samples <= 0) return;
    if (!loud->enabled) return;
    if (loud->gain_linear == 1.0f) return;

    int total = samples * loud->channels;
    for (int i = 0; i < total; i++) {
        pcm[i] *= loud->gain_linear;
    }
}

void loudness_destroy(Loudness *loud)
{
    if (loud) free(loud);
}

/**
 * equalizer.c — 10 段 Biquad IIR 均衡器
 *
 * 使用 Audio EQ Cookbook 公式实现 Biquad 滤波器
 */
#include "equalizer.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define LOG_TAG "[audio-engine:equalizer]"
#include <stdio.h>

/* ISO 标准频段 */
static const float EQ_FREQUENCIES[EQ_BANDS] = {
    31.25f, 62.5f, 125.0f, 250.0f, 500.0f,
    1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f
};

/* Biquad 滤波器状态（每个频段每个声道一个） */
typedef struct {
    float b0, b1, b2, a1, a2;  /* 系数 */
    float x1, x2, y1, y2;      /* 状态 */
} BiquadFilter;

struct Equalizer {
    int sample_rate;
    int channels;
    float gains[EQ_BANDS];
    float preamp_db;
    BiquadFilter *filters;  /* [bands * channels] */
};

/* 计算 Biquad peaking EQ 系数 */
static void biquad_calc_peaking(BiquadFilter *f, float freq, float gain_db, float Q, int sample_rate)
{
    float A = powf(10.0f, gain_db / 40.0f);
    float w0 = 2.0f * M_PI * freq / sample_rate;
    float alpha = sinf(w0) / (2.0f * Q);

    float b0 = 1.0f + alpha * A;
    float b1 = -2.0f * cosf(w0);
    float b2 = 1.0f - alpha * A;
    float a0 = 1.0f + alpha / A;
    float a1 = -2.0f * cosf(w0);
    float a2 = 1.0f - alpha / A;

    /* 归一化 */
    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = a1 / a0;
    f->a2 = a2 / a0;
}

Equalizer* equalizer_create(int sample_rate, int channels)
{
    Equalizer *eq = calloc(1, sizeof(*eq));
    if (!eq) return NULL;

    eq->sample_rate = sample_rate;
    eq->channels = channels;
    eq->preamp_db = 0.0f;

    /* 分配滤波器状态：每个频段每个声道一个 */
    eq->filters = calloc(EQ_BANDS * channels, sizeof(BiquadFilter));
    if (!eq->filters) {
        free(eq);
        return NULL;
    }

    /* 初始增益为 0dB（直通） */
    for (int i = 0; i < EQ_BANDS; i++) {
        eq->gains[i] = 0.0f;
    }

    fprintf(stderr, "%s 创建: %dHz / %dch / %d 频段\n",
            LOG_TAG, sample_rate, channels, EQ_BANDS);
    return eq;
}

void equalizer_set_gains(Equalizer *eq, const float gains[EQ_BANDS])
{
    if (!eq || !gains) return;

    memcpy(eq->gains, gains, sizeof(eq->gains));

    /* 重新计算所有滤波器系数 */
    float Q = 1.414f;  /* sqrt(2)，标准带宽 */
    for (int band = 0; band < EQ_BANDS; band++) {
        float freq = EQ_FREQUENCIES[band];
        float gain = gains[band];

        for (int ch = 0; ch < eq->channels; ch++) {
            BiquadFilter *f = &eq->filters[band * eq->channels + ch];
            biquad_calc_peaking(f, freq, gain, Q, eq->sample_rate);
        }
    }
}

void equalizer_set_preamp(Equalizer *eq, float preamp_db)
{
    if (!eq) return;
    eq->preamp_db = preamp_db;
}

void equalizer_process(Equalizer *eq, float *pcm, int samples)
{
    if (!eq || !pcm || samples <= 0) return;

    /* 检查是否所有频段都是 0dB（直通模式） */
    bool passthrough = true;
    for (int i = 0; i < EQ_BANDS; i++) {
        if (eq->gains[i] != 0.0f) {
            passthrough = false;
            break;
        }
    }

    if (passthrough && eq->preamp_db == 0.0f) {
        return;  /* 直通模式，不处理 */
    }

    /* 前级增益 */
    float preamp = powf(10.0f, eq->preamp_db / 20.0f);

    /* 对每个频段应用滤波 */
    for (int band = 0; band < EQ_BANDS; band++) {
        if (eq->gains[band] == 0.0f) continue;

        for (int ch = 0; ch < eq->channels; ch++) {
            BiquadFilter *f = &eq->filters[band * eq->channels + ch];

            for (int i = 0; i < samples; i++) {
                float x = pcm[i * eq->channels + ch];
                float y = f->b0 * x + f->b1 * f->x1 + f->b2 * f->x2
                        - f->a1 * f->y1 - f->a2 * f->y2;

                f->x2 = f->x1;
                f->x1 = x;
                f->y2 = f->y1;
                f->y1 = y;

                pcm[i * eq->channels + ch] = y;
            }
        }
    }

    /* 应用前级增益 */
    if (preamp != 1.0f) {
        int total = samples * eq->channels;
        for (int i = 0; i < total; i++) {
            pcm[i] *= preamp;
        }
    }
}

void equalizer_destroy(Equalizer *eq)
{
    if (!eq) return;
    if (eq->filters) free(eq->filters);
    free(eq);
}

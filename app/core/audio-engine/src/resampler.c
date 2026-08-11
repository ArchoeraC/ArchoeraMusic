/**
 * resampler.c — 基于 FFmpeg libswresample 的音频重采样器
 *
 * 将解码器输出的任意格式 PCM 转换为 48kHz float 交错格式。
 */
#include "resampler.h"

#include <libswresample/swresample.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <stdlib.h>
#include <string.h>

#define LOG_TAG "[audio-engine:resampler]"
#include <stdio.h>

struct Resampler {
    SwrContext *swr;

    int in_rate;
    int in_channels;
    int in_format;   /* AVSampleFormat */
    int out_rate;
    int out_channels;

    bool initialized;          /* 输入格式确定后才真正创建 swr */
    long long output_sample_count; /* 累计输出采样数 */
};

Resampler* resampler_create(int in_rate, int in_channels, int in_format,
                             int out_rate, int out_channels)
{
    Resampler *r = calloc(1, sizeof(*r));
    if (!r) return NULL;

    r->in_rate = in_rate;
    r->in_channels = in_channels;
    r->in_format = in_format;
    r->out_rate = out_rate;
    r->out_channels = out_channels;

    /* 如果输入参数已知，立即初始化 */
    if (in_rate > 0 && in_channels > 0 && in_format >= 0) {
        if (resampler_set_input_format(r, in_rate, in_channels, in_format) != 0) {
            free(r);
            return NULL;
        }
    }

    return r;
}

/* 内部：实际创建 SwrContext */
static int swr_init_real(Resampler *r)
{
    if (r->swr) return 0; /* 已初始化 */

#if LIBAVUTIL_VERSION_MAJOR >= 57
    /* FFmpeg 5.1+：使用 ch_layout API，按实际声道数构造默认布局
     * （输入 5.1 源正确下混到输出声道，输出声道数由 cfg->output_channels 决定） */
    AVChannelLayout in_layout;
    AVChannelLayout out_layout;
    av_channel_layout_default(&in_layout, r->in_channels);
    av_channel_layout_default(&out_layout, r->out_channels);
    int ret = swr_alloc_set_opts2(&r->swr,
        &out_layout, AV_SAMPLE_FMT_FLT, r->out_rate,
        &in_layout, r->in_format, r->in_rate,
        0, NULL);
    av_channel_layout_uninit(&in_layout);
    av_channel_layout_uninit(&out_layout);
#else
    /* 旧 API */
    r->swr = swr_alloc_set_opts(NULL,
        av_get_default_channel_layout(r->out_channels), AV_SAMPLE_FMT_FLT, r->out_rate,
        av_get_default_channel_layout(r->in_channels), r->in_format, r->in_rate,
        0, NULL);
    int ret = r->swr ? 0 : -1;
#endif
    if (ret < 0 || !r->swr) {
        fprintf(stderr, "%s swr_alloc_set_opts2 失败\n", LOG_TAG);
        return -1;
    }

    ret = swr_init(r->swr);
    if (ret < 0) {
        fprintf(stderr, "%s swr_init 失败: %s\n", LOG_TAG, av_err2str(ret));
        swr_free(&r->swr);
        return -1;
    }

    r->initialized = true;
    return 0;
}

int resampler_set_input_format(Resampler *r, int in_rate, int in_channels, int in_format)
{
    if (!r) return -1;

    /* 如果已经初始化且参数没变，跳过 */
    if (r->initialized && r->in_rate == in_rate &&
        r->in_channels == in_channels && r->in_format == in_format) {
        return 0;
    }

    /* 参数变化，需要重建 */
    if (r->swr) {
        swr_free(&r->swr);
        r->initialized = false;
    }

    r->in_rate = in_rate;
    r->in_channels = in_channels;
    r->in_format = in_format;
    return swr_init_real(r);
}

int resampler_process(Resampler *r,
                      const uint8_t **in_data, int in_samples,
                      float *out_buf, int out_capacity)
{
    if (!r || !r->initialized) return -1;

    /* 计算输出帧数上限 */
    int max_out = (int)av_rescale_rnd(in_samples, r->out_rate, r->in_rate,
                                       AV_ROUND_UP);
    if (max_out > out_capacity) max_out = out_capacity;
    if (max_out <= 0) return 0;

    int out_samples = swr_convert(r->swr,
        (uint8_t **)&out_buf, max_out,
        in_data, in_samples);
    if (out_samples < 0) {
        fprintf(stderr, "%s swr_convert 失败\n", LOG_TAG);
        return -1;
    }
    r->output_sample_count += out_samples;
    return out_samples;
}

int resampler_flush(Resampler *r, float *out_buf, int out_capacity)
{
    if (!r || !r->initialized) return 0;

    int total = 0;
    for (;;) {
        int n = swr_convert(r->swr,
            (uint8_t **)&out_buf, out_capacity - total,
            NULL, 0);
        if (n <= 0) break;
        total += n;
        out_buf += n * r->out_channels;
        if (total >= out_capacity) break;
    }
    r->output_sample_count += total;
    return total;
}

void resampler_destroy(Resampler *r)
{
    if (!r) return;
    if (r->swr) swr_free(&r->swr);
    free(r);
}

bool resampler_is_initialized(const Resampler *r)
{
    return r && r->initialized;
}

long long resampler_get_output_samples(const Resampler *r)
{
    return r ? r->output_sample_count : 0;
}

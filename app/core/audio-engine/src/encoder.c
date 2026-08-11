/**
 * encoder.c — OGG/Opus 编码器实现
 *
 * 使用 FFmpeg 的 avformat muxer + libopus 编码器。
 * 输出通过自定义 AVIO 回调写入用户提供的 OutputCallback。
 *
 * 设计：
 *   1. 创建 OGG/Opus 输出格式上下文
 *   2. 用 avio_alloc_context 将输出重定向到内存 buffer
 *   3. PCM float 累积到 frame_size 后送入编码器
 *   4. 编码后的包通过 av_interleaved_write_frame 封装为 OGG
 *   5. flush 时写完尾页
 */
#include "encoder.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <stdlib.h>
#include <string.h>

#define LOG_TAG "[audio-engine:encoder]"
#include <stdio.h>

#define AVIO_BUFFER_SIZE 8192

struct Encoder {
    /* FFmpeg 输出 */
    AVFormatContext *fmt_ctx;
    AVCodecContext  *enc_ctx;
    AVStream        *stream;
    AVIOContext     *avio;
    uint8_t         *avio_buffer;

    /* 输出回调 */
    OutputCallback   output_cb;
    void            *output_user;

    /* PCM 累积缓冲 */
    float           *pcm_buffer;     /* 交错 float */
    int              pcm_capacity;   /* 缓冲容量（帧数） */
    int              pcm_fill;       /* 已填充帧数 */
    int              frame_size;     /* Opus 帧大小（每声道样本数） */

    AVFrame         *enc_frame;
    AVPacket        *enc_pkt;
    bool             header_written;
    bool             trailer_written;
    int64_t         total_samples;  /* 已编码的样本数（用于 PTS） */
};

/* AVIO 写回调：将数据推给用户回调。
 * FFmpeg 7.1（libavformat 61）起 avio_alloc_context 的 write_packet 的 buf
 * 参数改为 const；旧版（libavformat 60 及以前）是非 const。按版本宏适配，
 * 避免 -Wincompatible-pointer-types 警告。 */
#if LIBAVFORMAT_VERSION_MAJOR >= 61
static int avio_write_callback(void *opaque, const uint8_t *buf, int buf_size)
#else
static int avio_write_callback(void *opaque, uint8_t *buf, int buf_size)
#endif
{
    Encoder *e = (Encoder *)opaque;
    if (!e->output_cb) return 0;
    int written = e->output_cb(buf, (size_t)buf_size, e->output_user);
    return (written >= 0) ? buf_size : -1;
}

Encoder* encoder_create(int sample_rate, int channels, int bitrate,
                         int frame_size_ms,
                         OutputCallback output, void *user)
{
    Encoder *e = calloc(1, sizeof(*e));
    if (!e) return NULL;

    e->output_cb = output;
    e->output_user = user;
    e->frame_size = sample_rate * frame_size_ms / 1000; /* 如 48000*20/1000 = 960 */

    /* 1. 创建 OGG 输出格式上下文 */
    int ret = avformat_alloc_output_context2(&e->fmt_ctx, NULL, "ogg", NULL);
    if (ret < 0 || !e->fmt_ctx) {
        fprintf(stderr, "%s avformat_alloc_output_context2 失败\n", LOG_TAG);
        goto fail;
    }

    /* 2. 设置自定义 AVIO（输出到内存回调） */
    e->avio_buffer = av_malloc(AVIO_BUFFER_SIZE);
    if (!e->avio_buffer) goto fail;

    e->avio = avio_alloc_context(e->avio_buffer, AVIO_BUFFER_SIZE,
                                  1, e,  /* write flag = 1, opaque = encoder */
                                  NULL, avio_write_callback, NULL);
    if (!e->avio) goto fail;
    e->fmt_ctx->pb = e->avio;
    e->fmt_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;

    /* 3. 查找 Opus 编码器 */
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_OPUS);
    if (!codec) {
        fprintf(stderr, "%s 未找到 Opus 编码器\n", LOG_TAG);
        goto fail;
    }

    /* 4. 创建输出流 */
    e->stream = avformat_new_stream(e->fmt_ctx, codec);
    if (!e->stream) goto fail;

    e->enc_ctx = avcodec_alloc_context3(codec);
    if (!e->enc_ctx) goto fail;

    /* 5. 配置编码参数 */
#if LIBAVUTIL_VERSION_MAJOR >= 57
    av_channel_layout_default(&e->enc_ctx->ch_layout, channels);
#else
    e->enc_ctx->channels = channels;
    e->enc_ctx->channel_layout = av_get_default_channel_layout(channels);
#endif
    e->enc_ctx->sample_rate = sample_rate;
    e->enc_ctx->sample_fmt = AV_SAMPLE_FMT_FLT; /* Opus 支持 float */
    e->enc_ctx->bit_rate = bitrate;
    e->enc_ctx->time_base = (AVRational){1, sample_rate};

    /* Opus 特定选项 */
    av_opt_set(e->enc_ctx->priv_data, "application", "audio", 0);
    av_opt_set(e->enc_ctx->priv_data, "frame_size", NULL, 0); /* 用编码器默认 */

    ret = avcodec_open2(e->enc_ctx, codec, NULL);
    if (ret < 0) {
        fprintf(stderr, "%s avcodec_open2 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }

    ret = avcodec_parameters_from_context(e->stream->codecpar, e->enc_ctx);
    if (ret < 0) {
        fprintf(stderr, "%s avcodec_parameters_from_context 失败\n", LOG_TAG);
        goto fail;
    }
    e->stream->time_base = e->enc_ctx->time_base;

    /* 6. 写 OGG 头 */
    ret = avformat_write_header(e->fmt_ctx, NULL);
    if (ret < 0) {
        fprintf(stderr, "%s avformat_write_header 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }
    e->header_written = true;

    /* 7. 分配 PCM 累积缓冲（容纳 2 个 Opus 帧） */
    e->pcm_capacity = e->frame_size * 2;
    e->pcm_buffer = malloc(e->pcm_capacity * channels * sizeof(float));
    if (!e->pcm_buffer) goto fail;

    e->enc_frame = av_frame_alloc();
    e->enc_pkt = av_packet_alloc();
    if (!e->enc_frame || !e->enc_pkt) goto fail;

    e->enc_frame->format = AV_SAMPLE_FMT_FLT;
    e->enc_frame->nb_samples = e->frame_size;
#if LIBAVUTIL_VERSION_MAJOR >= 57
    av_channel_layout_copy(&e->enc_frame->ch_layout, &e->enc_ctx->ch_layout);
#else
    e->enc_frame->channel_layout = e->enc_ctx->channel_layout;
    e->enc_frame->channels = e->enc_ctx->channels;
#endif
    e->enc_frame->sample_rate = sample_rate;
    ret = av_frame_get_buffer(e->enc_frame, 0);
    if (ret < 0) {
        fprintf(stderr, "%s av_frame_get_buffer 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }

    return e;

fail:
    encoder_destroy(e);
    return NULL;
}

/* 将已编码的 packet 写入 OGG 容器 */
static int write_packet(Encoder *e)
{
    av_packet_rescale_ts(e->enc_pkt, e->enc_ctx->time_base, e->stream->time_base);
    e->enc_pkt->stream_index = e->stream->index;
    int ret = av_interleaved_write_frame(e->fmt_ctx, e->enc_pkt);
    av_packet_unref(e->enc_pkt);
    if (ret < 0) {
        fprintf(stderr, "%s av_interleaved_write_frame 失败: %s\n", LOG_TAG, av_err2str(ret));
    }
    return ret;
}

/* 从编码器 drain 所有可用 packet */
static int drain_packets(Encoder *e)
{
    for (;;) {
        int ret = avcodec_receive_packet(e->enc_ctx, e->enc_pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return 0;
        if (ret < 0) {
            fprintf(stderr, "%s avcodec_receive_packet 失败: %s\n", LOG_TAG, av_err2str(ret));
            return ret;
        }
        ret = write_packet(e);
        if (ret < 0) return ret;
    }
}

/* 编码一帧 PCM 并写入 OGG 容器 */
static int encode_frame(Encoder *e, const float *pcm, int samples)
{
    /* 将 PCM 拷入 AVFrame */
    memcpy(e->enc_frame->data[0], pcm, samples * e->enc_ctx->ch_layout.nb_channels * sizeof(float));

    e->enc_frame->pts = e->total_samples;
    e->total_samples += samples;

    /* 循环：尝试 send_frame，如果 EAGAIN 则 drain 后再试 */
    for (;;) {
        int ret = avcodec_send_frame(e->enc_ctx, e->enc_frame);
        if (ret == 0) break;             /* 成功送入 */
        if (ret == AVERROR(EAGAIN)) {
            ret = drain_packets(e);       /* 编码器满，清空后重试 */
            if (ret < 0) return ret;
            continue;
        }
        /* 真正的错误 */
        fprintf(stderr, "%s avcodec_send_frame 失败: %s\n", LOG_TAG, av_err2str(ret));
        return ret;
    }

    return drain_packets(e);
}

int encoder_write_pcm(Encoder *e, const float *pcm, int samples)
{
    if (!e || !pcm || samples <= 0) return 0;

    int channels = e->enc_ctx->ch_layout.nb_channels;

    while (samples > 0) {
        int space = e->frame_size - e->pcm_fill;
        int to_copy = samples < space ? samples : space;

        memcpy(e->pcm_buffer + e->pcm_fill * channels,
               pcm,
               to_copy * channels * sizeof(float));

        e->pcm_fill += to_copy;
        pcm += to_copy * channels;
        samples -= to_copy;

        /* 凑够一帧，编码 */
        if (e->pcm_fill >= e->frame_size) {
            int ret = encode_frame(e, e->pcm_buffer, e->frame_size);
            if (ret < 0) return ret;
            e->pcm_fill = 0;
        }
    }
    return 0;
}

int encoder_flush(Encoder *e)
{
    if (!e) return -1;

    /* flush 残留 PCM（不足一帧用静音填充） */
    if (e->pcm_fill > 0) {
        int channels = e->enc_ctx->ch_layout.nb_channels;
        memset(e->pcm_buffer + e->pcm_fill * channels, 0,
               (e->frame_size - e->pcm_fill) * channels * sizeof(float));
        encode_frame(e, e->pcm_buffer, e->frame_size);
        e->pcm_fill = 0;
    }

    /* flush 编码器 */
    avcodec_send_frame(e->enc_ctx, NULL);
    int ret = drain_packets(e);
    if (ret < 0) return ret;

    /* 写 OGG 尾页 */
    if (e->header_written && !e->trailer_written) {
        av_write_trailer(e->fmt_ctx);
        e->trailer_written = true;
    }

    /* flush AVIO buffer */
    if (e->avio) {
        avio_flush(e->avio);
    }
    return 0;
}

void encoder_destroy(Encoder *e)
{
    if (!e) return;
    if (e->enc_frame) av_frame_free(&e->enc_frame);
    if (e->enc_pkt) av_packet_free(&e->enc_pkt);
    if (e->enc_ctx) avcodec_free_context(&e->enc_ctx);
    if (e->fmt_ctx) {
        if (e->header_written && !e->trailer_written) {
            av_write_trailer(e->fmt_ctx);
            e->trailer_written = true;
        }
        if (e->fmt_ctx->pb) avio_context_free(&e->fmt_ctx->pb);
        avformat_free_context(e->fmt_ctx);
    }
    /* avio_buffer 由 avio_context_free 释放，无需手动 free */
    if (e->pcm_buffer) free(e->pcm_buffer);
    free(e);
}

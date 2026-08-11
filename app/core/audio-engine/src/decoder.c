/**
 * decoder.c — FFmpeg 音频解码器实现
 *
 * 使用 FFmpeg 新版 API（avcodec_send_packet / avcodec_receive_frame）。
 * 兼容 FFmpeg 5.x/6.x/7.x（Fedora 42 提供 7.x）。
 */
#include "decoder.h"

#include <libavutil/opt.h>
#include <libavutil/log.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#define LOG_TAG "[audio-engine:decoder]"
#include <stdio.h>

/* SIGTERM 中断标志：volatile sig_atomic_t 保证信号处理器写入可见性。
 * handle_sigterm → decoder_interrupt() 置 1 → FFmpeg 的
 * AVIOInterruptCB 回调在阻塞 I/O 期间周期性检查此标志，
 * 一旦为 1 则 av_read_frame() 立即返回 AVERROR_EXIT。 */
static volatile sig_atomic_t g_decoder_interrupted = 0;

void decoder_interrupt(void)
{
    g_decoder_interrupted = 1;
}

/* AVIOInterruptCB 回调：FFmpeg 在阻塞 I/O 期间周期性调用。
 * 返回 1 表示中断请求，FFmpeg 中止当前操作。 */
static int interrupt_callback(void *opaque)
{
    (void)opaque;
    return g_decoder_interrupted;
}

/* FFmpeg 日志过滤：抑制已知的无害警告 */
static void decoder_log_callback(void *ptr, int level, const char *fmt, va_list vl)
{
    /* flac: 帧级同步码错误，解码器会跳过该帧继续解码下一帧 */
    if (strstr(fmt, "invalid sync code") != NULL) return;
    if (strstr(fmt, "invalid frame header") != NULL) return;
    if (strstr(fmt, "decode_frame() failed") != NULL) return;
    if (strstr(fmt, "dropping low score") != NULL) return;
    /* mp3float: 品质 >= 源品质时的时间戳跟踪警告，完全无害 */
    if (strstr(fmt, "Could not update timestamps") != NULL) return;
    av_log_default_callback(ptr, level, fmt, vl);
}

struct Decoder {
    AVFormatContext *fmt_ctx;
    AVCodecContext  *dec_ctx;
    int              stream_index;
    int64_t          duration_us;

    /* 解码缓冲：send_packet 后可能产生多帧 */
    bool             packet_sent;

    AVPacket        *pkt;
    AVFrame         *frame;
};

Decoder* decoder_open(const char *url)
{
    Decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;

    d->stream_index = -1;
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->pkt || !d->frame) goto fail;

    /* 安装 FFmpeg 日志过滤，抑制已知无害警告 */
    av_log_set_callback(decoder_log_callback);

    /* 1. 打开输入 — 限制探测大小以加速首帧产出（对 192kHz 大 FLAC 尤为重要） */
    AVDictionary *fmt_opts = NULL;
    /* 探测 1MB 足够识别格式和流信息（默认 ~5MB，对大文件浪费） */
    av_dict_set(&fmt_opts, "probesize", "1048576", 0);
    /* 分析时长 0.5 秒足够（默认 5 秒，对大文件导致首帧延迟数秒） */
    av_dict_set(&fmt_opts, "analyzeduration", "500000", 0);
    int ret = avformat_open_input(&d->fmt_ctx, url, NULL, &fmt_opts);
    av_dict_free(&fmt_opts);
    if (ret < 0) {
        fprintf(stderr, "%s avformat_open_input 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }

    /* 注册中断回调：SIGTERM 后 FFmpeg 在阻塞 I/O 中检查此标志并立即返回 */
    d->fmt_ctx->interrupt_callback.callback = interrupt_callback;
    d->fmt_ctx->interrupt_callback.opaque = NULL;

    /* 2. 获取流信息 */
    ret = avformat_find_stream_info(d->fmt_ctx, NULL);
    if (ret < 0) {
        fprintf(stderr, "%s avformat_find_stream_info 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }

    /* 3. 找到最佳音频流 */
    ret = av_find_best_stream(d->fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (ret < 0) {
        fprintf(stderr, "%s 未找到音频流: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }
    d->stream_index = ret;

    /* 4. 创建解码器上下文 */
    const AVCodec *codec = avcodec_find_decoder(
        d->fmt_ctx->streams[d->stream_index]->codecpar->codec_id);
    if (!codec) {
        fprintf(stderr, "%s 未找到解码器\n", LOG_TAG);
        goto fail;
    }

    d->dec_ctx = avcodec_alloc_context3(codec);
    if (!d->dec_ctx) goto fail;

    ret = avcodec_parameters_to_context(d->dec_ctx,
            d->fmt_ctx->streams[d->stream_index]->codecpar);
    if (ret < 0) {
        fprintf(stderr, "%s avcodec_parameters_to_context 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }

    /* 宽松模式：部分 FLAC 编码器产生的帧头/CRC 不完全符合严格规范，
     * 设置 strict_std_compliance=-2 让解码器接受它们 */
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "strict_std_compliance", "-2", 0);
    ret = avcodec_open2(d->dec_ctx, codec, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        fprintf(stderr, "%s avcodec_open2 失败: %s\n", LOG_TAG, av_err2str(ret));
        goto fail;
    }

    /* 5. 获取时长 */
    d->duration_us = d->fmt_ctx->duration; /* AV_TIME_BASE 单位 */
    if (d->duration_us <= 0 && d->fmt_ctx->streams[d->stream_index]->duration > 0) {
        d->duration_us = av_rescale_q(
            d->fmt_ctx->streams[d->stream_index]->duration,
            d->fmt_ctx->streams[d->stream_index]->time_base,
            (AVRational){1, AV_TIME_BASE});
    }

    return d;

fail:
    decoder_close(d);
    return NULL;
}

int decoder_read_frame(Decoder *d, AVFrame **out_frame)
{
    if (!d || !out_frame) return -1;

    /* 连续解码错误计数器：防止坏文件导致无限循环（无任何帧输出） */
    int consecutive_errors = 0;
    const int MAX_CONSECUTIVE_ERRORS = 256;

    for (;;) {
        /* 先尝试从解码器取出已缓存的帧 */
        int ret = avcodec_receive_frame(d->dec_ctx, d->frame);
        if (ret == 0) {
            *out_frame = d->frame;
            consecutive_errors = 0;  /* 成功解码，重置计数器 */
            return 1;
        }
        if (ret == AVERROR(EAGAIN)) {
            /* 需要送入更多 packet */
            d->packet_sent = false;
        } else if (ret == AVERROR_EOF) {
            /* 解码器已 flush，无更多帧 */
            return 0;
        } else {
            /* 坏帧/数据错误 — 标记需要新 packet，fall through 到读取逻辑
             * 注意：不能 continue，否则会无限循环调用 avcodec_receive_frame
             * （解码器内部状态未改变，仍返回相同错误） */
            if (consecutive_errors == 0) {
                fprintf(stderr, "%s avcodec_receive_frame 错误: %s — 跳过\n",
                        LOG_TAG, av_err2str(ret));
            }
            consecutive_errors++;
            if (consecutive_errors >= MAX_CONSECUTIVE_ERRORS) {
                fprintf(stderr, "%s 连续 %d 次解码失败，放弃\n",
                        LOG_TAG, consecutive_errors);
                return ret;
            }
            d->packet_sent = false;
            /* 不 continue，fall through 到读取新 packet */
        }

        /* 读取下一个 packet */
        if (!d->packet_sent) {
            ret = av_read_frame(d->fmt_ctx, d->pkt);
            if (ret < 0) {
                if (ret == AVERROR_EOF) {
                    /* 文件读完，flush 解码器 */
                    avcodec_send_packet(d->dec_ctx, NULL);
                    d->packet_sent = true;
                    continue;
                }
                /* SIGTERM → AVIOInterruptCB 返回 1 → FFmpeg 返回 AVERROR_EXIT */
                if (ret == AVERROR_EXIT) {
                    return 0;
                }
                fprintf(stderr, "%s av_read_frame 错误: %s\n", LOG_TAG, av_err2str(ret));
                return ret;
            }

            /* 只处理目标流 */
            if (d->pkt->stream_index != d->stream_index) {
                av_packet_unref(d->pkt);
                continue;
            }

            ret = avcodec_send_packet(d->dec_ctx, d->pkt);
            av_packet_unref(d->pkt);
            if (ret < 0 && ret != AVERROR(EAGAIN)) {
                /* 坏包 — 跳过继续 */
                fprintf(stderr, "%s avcodec_send_packet 错误: %s — 跳过该包\n", LOG_TAG, av_err2str(ret));
                d->packet_sent = false;
                continue;
            }
            d->packet_sent = true;
        }
    }
}

int decoder_seek_ms(Decoder *d, int64_t offset_ms)
{
    if (!d || !d->fmt_ctx) return -1;

    /* 跳到目标偏移（毫秒 → AV_TIME_BASE） */
    int64_t ts = offset_ms * 1000; /* AV_TIME_BASE 微秒 */
    /* 用 AVSEEK_FLAG_BACKWARD 保证跳到 offset_ms 之前的关键帧 */
    int ret = av_seek_frame(d->fmt_ctx, -1, ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        fprintf(stderr, "%s av_seek_frame 失败 (offset=%ldms): %s\n",
                LOG_TAG, (long)offset_ms, av_err2str(ret));
        return ret;
    }

    /* flush 解码器 */
    avcodec_flush_buffers(d->dec_ctx);
    d->packet_sent = false;

    fprintf(stderr, "%s 跳过 %ldms\n", LOG_TAG, (long)offset_ms);
    return 0;
}

int decoder_sample_rate(const Decoder *d)
{
    return d && d->dec_ctx ? d->dec_ctx->sample_rate : 0;
}

int decoder_channels(const Decoder *d)
{
    return d && d->dec_ctx ? d->dec_ctx->ch_layout.nb_channels : 0;
}

int64_t decoder_duration_us(const Decoder *d)
{
    return d ? d->duration_us : 0;
}

const char* decoder_codec_name(const Decoder *d)
{
    if (!d || !d->dec_ctx || !d->dec_ctx->codec) return "unknown";
    return d->dec_ctx->codec->name;
}

void decoder_close(Decoder *d)
{
    if (!d) return;
    if (d->frame) av_frame_free(&d->frame);
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->dec_ctx) avcodec_free_context(&d->dec_ctx);
    if (d->fmt_ctx) avformat_close_input(&d->fmt_ctx);
    free(d);
}

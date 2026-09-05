/**
 * pipeline.c — 音频处理管线编排
 *
 * Phase 4：
 *   decoder → resampler → equalizer → loudness → limiter → tempo → fft → encoder
 *
 * 数据流：
 *   FFmpeg 解码 → AVFrame(PCM)
 *   → swresample 重采样为 48kHz float 交错
 *   → equalizer 10 段 Biquad EQ
 *   → loudness EBU R128 响度归一化
 *   → limiter 输出限幅
 *   → tempo 变速变调（Rust signalsmith-stretch）
 *   → fft 频谱分析（并行提取）
 *   → libopus 编码 + OGG 封装
 *   → OutputCallback 输出
 */
#include "../include/audio_engine.h"
#include "decoder.h"
#include "native_decoder.h"
#include "resampler.h"
#include "encoder.h"
#include "equalizer.h"
#include "loudness.h"
#include "limiter.h"
#include "fft.h"
#include "tempo.h"

#include <libavutil/samplefmt.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define LOG_TAG "[audio-engine:pipeline]"
#include <stdio.h>

/* 重采样后 PCM 的临时缓冲（足够容纳一个 Opus 帧的扩展） */
#define PCM_TEMP_CAPACITY 4096

/* engine_mode 取值（audio_engine.h EngineConfig.engine_mode） */
#define ENGINE_MODE_STABLE   0 /* FFmpeg（默认，现状行为） */
#define ENGINE_MODE_ERAUDIO  1 /* 自研内核优先，失败回退 FFmpeg（实验性） */

/* 原生路径单次读取帧数（读入 float 交错 chunk 后整体重采样） */
#define NATIVE_CHUNK_FRAMES 2048

struct AudioPipeline {
    Decoder     *dec;           /* FFmpeg 后端（native_active == false 时使用） */
    NativeDecoder *native;      /* 自研 Zig 内核（engine_mode==EraAudio 且接管成功）；
                                  非 NULL 时为本解码源（FFmpeg 不再打开） */
    bool         native_active; /* 解码源是否为自研内核 */
    int          native_status; /* native open 失败状态码（ZkStatus；成功=0） */
    char         native_err[256]; /* native open 失败诊断（仅日志） */
    float       *native_buf;    /* native 读缓冲（float 交错） */
    int          native_buf_frames; /* native_buf 帧容量 */
    Resampler   *resampler;
    Encoder     *encoder;

    /* 音频处理模块 */
    Equalizer   *equalizer;
    Loudness    *loudness;
    Limiter     *limiter;
    Tempo       *tempo;
    FFTAnalyzer *fft;

    EngineConfig cfg;

    /* 临时缓冲：存放重采样后的 float PCM */
    float       *pcm_temp;
    int          pcm_temp_capacity;

    /* tempo 处理后的中间缓冲（tempo 会改变样本数） */
    float       *tempo_buf;
    int          tempo_buf_capacity;

    /* PCM 流出（FFT 客户端化：桌面端 Flutter 直连收取原始 PCM） */
    PcmOutCallback pcm_out_cb;
    void          *pcm_out_user;

    /* 单次 pipeline_process 处理帧上限（batch=64；播放流式=小块便于命令轮询） */
    int            max_frames_per_call;

    bool         eof;        /* 解码器已到 EOF */
    bool         flushed;    /* 编码器已 flush */
};

AudioPipeline* pipeline_create(const char *source,
                                const EngineConfig *cfg,
                                OutputCallback output,
                                void *user)
{
    if (!source || !cfg || !output) return NULL;

    AudioPipeline *p = calloc(1, sizeof(*p));
    if (!p) return NULL;

    p->cfg = *cfg;
    p->max_frames_per_call = 64;

    /* 1. 打开解码器：engine_mode==EraAudio 优先自研内核（原生优先），
     *    未接管 / 打不开 / 内核未链接 → 回退 FFmpeg（Stable 行为零回退） */
    if (cfg->engine_mode == ENGINE_MODE_ERAUDIO) {
        NativeInfo ninfo;
        int st = 1; /* 默认 unsupported */
        p->native = native_decoder_open(source, &ninfo, &st,
                                        p->native_err, sizeof(p->native_err));
        p->native_status = st;
        if (p->native) {
            p->native_active = true;
            fprintf(stderr, "%s EraAudio: 自研内核接管 — codec=%s / fmt=%s\n",
                    LOG_TAG, ninfo.codec_name ? ninfo.codec_name : "?",
                    ninfo.format_name ? ninfo.format_name : "?");
        } else {
            fprintf(stderr, "%s EraAudio: 自研内核不可用/未接管 (status=%d %s)"
                            " → 回退 FFmpeg\n",
                    LOG_TAG, st, p->native_err[0] ? p->native_err : "");
        }
    } else {
        fprintf(stderr, "%s engine_mode=%d（Stable=FFmpeg 默认路径）\n",
                LOG_TAG, cfg->engine_mode);
    }

    if (p->native_active) {
        /* 原生路径：分配读缓冲（float 交错，按源声道数，每帧 1 个 float/ch） */
        int src_ch = native_decoder_channels(p->native);
        if (src_ch <= 0 || src_ch > 16) {
            fprintf(stderr, "%s 自研内核源声道数异常: %d\n", LOG_TAG, src_ch);
            goto fail;
        }
        p->native_buf_frames = NATIVE_CHUNK_FRAMES;
        p->native_buf = malloc((size_t)p->native_buf_frames *
                               (size_t)src_ch * sizeof(float));
        if (!p->native_buf) goto fail;
    } else {
        p->dec = decoder_open(source);
        if (!p->dec) {
            fprintf(stderr, "%s 无法打开源: %s\n", LOG_TAG, source);
            goto fail;
        }
    }

    int src_rate = p->native_active ? native_decoder_sample_rate(p->native)
                                    : decoder_sample_rate(p->dec);
    int src_channels = p->native_active ? native_decoder_channels(p->native)
                                        : decoder_channels(p->dec);
    const char *src_codec = p->native_active
                            ? native_decoder_codec_name(p->native)
                            : decoder_codec_name(p->dec);
    int64_t src_dur_us = p->native_active
                         ? native_decoder_duration_us(p->native)
                         : decoder_duration_us(p->dec);
    fprintf(stderr, "%s 源: %dHz / %dch / %s / 时长 %.1fs\n",
            LOG_TAG, src_rate, src_channels,
            src_codec, src_dur_us / 1e6);

    /* 输出采样率：0 = 跟随源（player 模式原生直通，miniaudio 设备端 SRC）；
     * 非 0 = 用户指定（Opus/批量路径由 main 强制 48000） */
    if (p->cfg.output_sample_rate <= 0) {
        p->cfg.output_sample_rate = src_rate;
    }
    int out_rate = p->cfg.output_sample_rate;
    int out_channels = p->cfg.output_channels;

    /* 2. 创建重采样器 */
    p->resampler = resampler_create(src_rate, src_channels, AV_SAMPLE_FMT_NONE,
                                     out_rate, out_channels);
    if (!p->resampler) {
        fprintf(stderr, "%s 重采样器创建失败\n", LOG_TAG);
        goto fail;
    }

    /* 3. 音频处理模块 */

    /* 3.1 均衡器 */
    p->equalizer = equalizer_create(out_rate, out_channels);
    if (!p->equalizer) {
        fprintf(stderr, "%s 均衡器创建失败\n", LOG_TAG);
        goto fail;
    }
    bool has_eq = false;
    for (int i = 0; i < EQ_BANDS; i++) {
        if (cfg->eq_gains[i] != 0.0f) { has_eq = true; break; }
    }
    if (has_eq || cfg->eq_preamp_db != 0.0f) {
        equalizer_set_gains(p->equalizer, cfg->eq_gains);
        equalizer_set_preamp(p->equalizer, cfg->eq_preamp_db);
        fprintf(stderr, "%s EQ 启用: preamp=%.1fdB\n", LOG_TAG, cfg->eq_preamp_db);
    }

    /* 3.2 响度归一化 */
    p->loudness = loudness_create(out_rate, out_channels);
    if (!p->loudness) {
        fprintf(stderr, "%s 响度归一化创建失败\n", LOG_TAG);
        goto fail;
    }
    if (cfg->normalization && cfg->normalization_gain != 0.0f) {
        loudness_set_enabled(p->loudness, true);
        loudness_set_gain(p->loudness, cfg->normalization_gain);
    }

    /* 3.3 限幅器 */
    p->limiter = limiter_create(out_rate, out_channels);
    if (!p->limiter) {
        fprintf(stderr, "%s 限幅器创建失败\n", LOG_TAG);
        goto fail;
    }
    limiter_set_enabled(p->limiter, cfg->limiter_enabled);
    limiter_set_threshold(p->limiter, cfg->limiter_threshold_db);

    /* 3.4 变速变调 */
    p->tempo = tempo_create(out_rate, out_channels);
    if (!p->tempo) {
        fprintf(stderr, "%s 变速变调创建失败\n", LOG_TAG);
        goto fail;
    }
    if (cfg->tempo_enabled) {
        tempo_set_enabled(p->tempo, true);
        tempo_set_speed(p->tempo, cfg->tempo_speed);
        tempo_set_pitch(p->tempo, cfg->tempo_pitch);
        tempo_set_pitch_sync(p->tempo, cfg->tempo_pitch_sync);
    } else {
        tempo_set_enabled(p->tempo, false);
    }

    /* 3.5 FFT 分析器 */
    p->fft = fft_create(out_rate, cfg->fft_size);
    if (!p->fft) {
        fprintf(stderr, "%s FFT 分析器创建失败\n", LOG_TAG);
        goto fail;
    }
    fft_set_enabled(p->fft, cfg->fft_enabled);

    /* 4. 创建编码器（player 模式 skip_encoder：仅 PCM 落盘 WAV/UDS，无 OGG 输出） */
    if (!p->cfg.skip_encoder) {
        p->encoder = encoder_create(out_rate, out_channels,
                                     cfg->bitrate, cfg->frame_size_ms,
                                     output, user);
        if (!p->encoder) {
            fprintf(stderr, "%s 编码器创建失败\n", LOG_TAG);
            goto fail;
        }
    }

    /* 5. 如果指定了偏移量，seek 到目标位置 */
    if (cfg->start_offset_ms > 0) {
        if (p->native_active) {
            if (native_decoder_seek_ms(p->native, cfg->start_offset_ms) != 0) {
                fprintf(stderr, "%s native seek 到 %ldms 失败\n",
                        LOG_TAG, (long)cfg->start_offset_ms);
                goto fail;
            }
        } else {
            int ret = decoder_seek_ms(p->dec, cfg->start_offset_ms);
            if (ret < 0) {
                fprintf(stderr, "%s seek 到 %ldms 失败\n",
                        LOG_TAG, (long)cfg->start_offset_ms);
                goto fail;
            }
        }
    }

    /* 6. 分配临时缓冲 */
    p->pcm_temp_capacity = PCM_TEMP_CAPACITY;
    p->pcm_temp = malloc(p->pcm_temp_capacity * cfg->output_channels * sizeof(float));
    if (!p->pcm_temp) goto fail;

    /* tempo 输出缓冲 */
    p->tempo_buf_capacity = PCM_TEMP_CAPACITY * 2; /* tempo 可能输出最多 2 倍 */
    p->tempo_buf = malloc(p->tempo_buf_capacity * cfg->output_channels * sizeof(float));
    if (!p->tempo_buf) goto fail;

    fprintf(stderr, "%s 管线就绪: → %dHz / %dch / %s\n",
            LOG_TAG, out_rate, out_channels,
            p->cfg.skip_encoder ? "PCM(无编码)" : "Opus 编码");
    return p;

fail:
    pipeline_destroy(p);
    return NULL;
}

/* DSP 处理链：重采样后的 float 交错 PCM → eq → loudness → limiter → tempo → fft
 * → PCM 流出回调 → 编码器。返回编码器写入帧数或 out_samples（skip_encoder 时）。
 * pcm 为 out_rate/out_channels 的重采样输出；samples 为其帧数。 */
static int process_dsp_chain(AudioPipeline *p, float *pcm, int samples)
{
    equalizer_process(p->equalizer, pcm, samples);
    loudness_process(p->loudness, pcm, samples);
    limiter_process(p->limiter, pcm, samples);

    /* tempo: 变速变调（改变样本数，就地写回 pcm） */
    if (!tempo_is_bypass(p->tempo)) {
        /* 确保输出缓冲足够 */
        int need = (int)((float)samples / 0.5f) + 256;
        if (need > p->tempo_buf_capacity) {
            p->tempo_buf_capacity = need * 2;
            p->tempo_buf = realloc(p->tempo_buf,
                p->tempo_buf_capacity * p->cfg.output_channels * sizeof(float));
            if (!p->tempo_buf) return -1;
        }

        int t_samples = samples;
        int ret = tempo_process(p->tempo, pcm, &t_samples);
        if (ret < 0) return -1;
        samples = t_samples;
    }

    /* FFT 分析（自适应声道数，含 5.1，内部下混为左右声道） */
    fft_process_multi(p->fft, pcm, samples, p->cfg.output_channels);

    /* PCM 流出：位置 = 原速音频时间（resampler 输出样本 / 采样率，含起始偏移） */
    if (p->pcm_out_cb) {
        double pos_ms = (double)resampler_get_output_samples(p->resampler)
                        / (double)p->cfg.output_sample_rate * 1000.0
                        + (double)p->cfg.start_offset_ms;
        p->pcm_out_cb(pcm, samples, p->cfg.output_channels, pos_ms, p->pcm_out_user);
    }

    /* 送入编码器（player 模式跳过：PCM 已落盘 WAV/UDS） */
    if (p->encoder) {
        return encoder_write_pcm(p->encoder, pcm, samples);
    }
    return samples;
}

/* 处理单帧 PCM 数据（FFmpeg 后端：AVFrame → swr 重采样 → DSP 链） */
static int process_frame(AudioPipeline *p, AVFrame *frame)
{
    /* 延迟初始化重采样器 */
    if (!resampler_is_initialized(p->resampler)) {
        int ret = resampler_set_input_format(p->resampler,
            frame->sample_rate,
            frame->ch_layout.nb_channels,
            frame->format);
        if (ret < 0) return ret;
    }

    int in_samples = frame->nb_samples;

    /* 估算输出样本数 */
    int max_out = (int)((int64_t)in_samples * p->cfg.output_sample_rate /
                        frame->sample_rate) + 256;
    if (max_out > p->pcm_temp_capacity) {
        p->pcm_temp_capacity = max_out * 2;
        p->pcm_temp = realloc(p->pcm_temp,
            p->pcm_temp_capacity * p->cfg.output_channels * sizeof(float));
        if (!p->pcm_temp) return -1;
    }

    /* swresample */
    int out_samples = resampler_process(p->resampler,
        (const uint8_t **)frame->data, in_samples,
        p->pcm_temp, p->pcm_temp_capacity);
    if (out_samples < 0) return -1;
    if (out_samples == 0) return 0;

    /* 处理链：eq → loudness → limiter → tempo → fft → encoder */
    return process_dsp_chain(p, p->pcm_temp, out_samples);
}

/* 原生路径：读一段 float 交错 PCM（自研内核已输出 f32 交错，native_buf），
 * 以 AV_SAMPLE_FMT_FLT 输入重采样器（复用现有 swr/采样链路，播放语义不变）。
 * @return 1 处理了数据，0 EOF，<0 错误 */
static int native_process_chunk(AudioPipeline *p)
{
    int src_ch = native_decoder_channels(p->native);
    if (src_ch <= 0) return -1;

    int ch = 0;
    int frames = native_decoder_read(p->native, p->native_buf,
                                     p->native_buf_frames, &ch);
    if (frames < 0) return -1;
    if (frames == 0) return 0; /* EOF */
    if (ch <= 0 || ch > src_ch) ch = src_ch; /* 容错：首帧声道缺失用源声道数 */

    /* 重采样器输入为 float32 交错（native 输出即此格式） */
    if (!resampler_is_initialized(p->resampler)) {
        int ret = resampler_set_input_format(p->resampler,
            native_decoder_sample_rate(p->native), ch, AV_SAMPLE_FMT_FLT);
        if (ret < 0) return ret;
    }

    /* 估算输出样本数并保证缓冲足够（同 FFmpeg 路径） */
    int native_sr = native_decoder_sample_rate(p->native);
    int max_out = (int)((int64_t)frames * p->cfg.output_sample_rate / native_sr) + 256;
    if (max_out > p->pcm_temp_capacity) {
        p->pcm_temp_capacity = max_out * 2;
        p->pcm_temp = realloc(p->pcm_temp,
            p->pcm_temp_capacity * p->cfg.output_channels * sizeof(float));
        if (!p->pcm_temp) return -1;
    }

    int out_samples = resampler_process(p->resampler,
        (const uint8_t **)&p->native_buf, frames,
        p->pcm_temp, p->pcm_temp_capacity);
    if (out_samples < 0) return -1;
    if (out_samples == 0) return 1; /* swr 缓冲中，无输出；继续读 */

    int r = process_dsp_chain(p, p->pcm_temp, out_samples);
    /* encoder_write_pcm 成功返回 0/正整数；0 不代表 EOF（EOF 仅由
     * native_decoder_read 返回 0 判定），这里统一收敛为“已处理=1”。 */
    return r < 0 ? r : 1;
}

ssize_t pipeline_process(AudioPipeline *p)
{
    if (!p || p->eof) return 0;

    int frames_this_call = 0;
    const int MAX_FRAMES_PER_CALL = p->max_frames_per_call > 0
                                    ? p->max_frames_per_call : 64;

    while (frames_this_call < MAX_FRAMES_PER_CALL) {
        if (p->native_active) {
            /* 自研内核后端：整段 float 交错读入 → 重采样 → DSP 链 */
            int ret = native_process_chunk(p);
            if (ret <= 0) {
                if (ret < 0) {
                    fprintf(stderr, "%s 自研内核解码错误: %d\n", LOG_TAG, ret);
                    return ret;
                }
                p->eof = true; /* 0 = EOF */
                break;
            }
            frames_this_call++;
            continue;
        }

        AVFrame *frame = NULL;
        int ret = decoder_read_frame(p->dec, &frame);
        if (ret <= 0) {
            p->eof = true;
            if (ret < 0) {
                fprintf(stderr, "%s 解码错误: %d\n", LOG_TAG, ret);
                return ret;
            }
            break;
        }

        ret = process_frame(p, frame);
        av_frame_unref(frame);
        if (ret < 0) return ret;

        frames_this_call++;
    }

    return frames_this_call;
}

int pipeline_run(AudioPipeline *p)
{
    if (!p) return -1;

    for (;;) {
        ssize_t n = pipeline_process(p);
        if (n <= 0) {
            if (n < 0) return (int)n;
            break;
        }
    }

    /* flush */
    if (!p->flushed) {
        int out = resampler_flush(p->resampler, p->pcm_temp, p->pcm_temp_capacity);
        if (out > 0) {
            equalizer_process(p->equalizer, p->pcm_temp, out);
            loudness_process(p->loudness, p->pcm_temp, out);
            limiter_process(p->limiter, p->pcm_temp, out);

            if (!tempo_is_bypass(p->tempo)) {
                int t_samples = out;
                tempo_process(p->tempo, p->pcm_temp, &t_samples);
                out = t_samples;
            }

            fft_process_multi(p->fft, p->pcm_temp, out, p->cfg.output_channels);
            if (p->pcm_out_cb) {
                double pos_ms = (double)resampler_get_output_samples(p->resampler)
                                / (double)p->cfg.output_sample_rate * 1000.0
                                + (double)p->cfg.start_offset_ms;
                p->pcm_out_cb(p->pcm_temp, out, p->cfg.output_channels, pos_ms, p->pcm_out_user);
            }
            if (p->encoder) {
                encoder_write_pcm(p->encoder, p->pcm_temp, out);
            }
        }
        if (p->encoder) {
            encoder_flush(p->encoder);
        }
        p->flushed = true;
    }
    return 0;
}

double pipeline_get_position(const AudioPipeline *p)
{
    if (!p || !p->resampler) return 0.0;
    long long processed = resampler_get_output_samples(p->resampler);
    return (double)processed / (double)p->cfg.output_sample_rate;
}

void pipeline_set_eq_gains(AudioPipeline *p, const float gains[EQ_BANDS])
{
    if (!p || !p->equalizer) return;
    equalizer_set_gains(p->equalizer, gains);
}

void pipeline_set_preamp(AudioPipeline *p, float preamp_db)
{
    if (!p || !p->equalizer) return;
    equalizer_set_preamp(p->equalizer, preamp_db);
}

void pipeline_set_volume(AudioPipeline *p, float volume)
{
    if (!p || !p->limiter) return;
    /* 音量作为绝对增益叠加在限幅器基准阈值上（非累加当前阈值）：
       此前累加式在 volume=0 时 log10(0) → -inf 会永久污染阈值状态，
       恢复音量后 limiter 阈值仍为 -inf，转码输出持续静音（表现为
       「引擎暂停/无声音」）。volume<=0 用有限值 -120dB 表示静音。 */
    float gain_db = (volume > 0.0f) ? 20.0f * log10f(volume) : -120.0f;
    limiter_set_threshold(p->limiter, p->cfg.limiter_threshold_db + gain_db);
}

void pipeline_set_pcm_out_cb(AudioPipeline *p, PcmOutCallback cb, void *user_data)
{
    if (!p) return;
    p->pcm_out_cb = cb;
    p->pcm_out_user = user_data;
}

void pipeline_set_normalization_enabled(AudioPipeline *p, bool enabled)
{
    if (!p || !p->loudness) return;
    loudness_set_enabled(p->loudness, enabled);
}

void pipeline_set_limiter_enabled(AudioPipeline *p, bool enabled)
{
    if (!p || !p->limiter) return;
    limiter_set_enabled(p->limiter, enabled);
}

void pipeline_set_fft_enabled(AudioPipeline *p, bool enabled)
{
    if (!p || !p->fft) return;
    fft_set_enabled(p->fft, enabled);
}

int pipeline_get_fft_spectrum(AudioPipeline *p, float *out_db, int bins, float min_db)
{
    if (!p || !p->fft || !out_db || bins <= 0) return -1;
    fft_get_spectrum_db(p->fft, out_db, bins, min_db);
    return 0;
}

int pipeline_get_fft_spectrum_stereo(AudioPipeline *p,
                                     float *out_db_l, float *out_db_r,
                                     int bins, float min_db)
{
    if (!p || !p->fft || !out_db_l || !out_db_r || bins <= 0) return -1;
    fft_get_spectrum_db_stereo(p->fft, out_db_l, out_db_r, bins, min_db);
    return 0;
}

int pipeline_get_fft_spectrum_norm_stereo(AudioPipeline *p,
                                          float *out_l, float *out_r,
                                          int bins)
{
    if (!p || !p->fft || !out_l || !out_r || bins <= 0) return -1;
    fft_get_spectrum_norm_stereo(p->fft, out_l, out_r, bins);
    return 0;
}

int pipeline_get_fft_size(const AudioPipeline *p)
{
    return p && p->fft ? fft_get_size(p->fft) : 0;
}

void pipeline_set_fft_frame_cb(AudioPipeline *p, AudioFftFrameCb cb, void *user_data)
{
    if (!p || !p->fft) return;
    /* AudioFftFrameCb 与 fft_frame_cb 签名一致，直接透传 */
    fft_set_frame_cb(p->fft, (fft_frame_cb)cb, user_data);
}

/** FFT 已处理音频时间（秒，样本级粒度，供频谱推送驱动） */
double pipeline_get_fft_processed_seconds(const AudioPipeline *p)
{
    return p && p->fft ? fft_get_processed_seconds(p->fft) : 0.0;
}

/* Phase 4: 变速变调 */
void pipeline_set_tempo_speed(AudioPipeline *p, float speed)
{
    if (!p || !p->tempo) return;
    tempo_set_speed(p->tempo, speed);
}

void pipeline_set_tempo_pitch(AudioPipeline *p, float semitones)
{
    if (!p || !p->tempo) return;
    tempo_set_pitch(p->tempo, semitones);
}

void pipeline_set_tempo_pitch_sync(AudioPipeline *p, bool sync)
{
    if (!p || !p->tempo) return;
    tempo_set_pitch_sync(p->tempo, sync);
}

void pipeline_set_tempo_enabled(AudioPipeline *p, bool enabled)
{
    if (!p || !p->tempo) return;
    tempo_set_enabled(p->tempo, enabled);
}

void pipeline_signal_shutdown(AudioPipeline *p)
{
    if (!p) return;
    p->eof = true;
}

double pipeline_get_duration(const AudioPipeline *p)
{
    if (!p) return 0.0;
    if (p->native_active) {
        return native_decoder_duration_us(p->native) / 1000000.0;
    }
    return p->dec ? decoder_duration_us(p->dec) / 1000000.0 : 0.0;
}

void pipeline_set_playback_streaming(AudioPipeline *p, bool streaming)
{
    if (!p) return;
    /* 流式播放：每次 pipeline_process 处理小块（命令轮询及时）；
       批量/转码路径保持 64 块/次（全速）。 */
    p->max_frames_per_call = streaming ? 2 : 64;
}

int pipeline_get_source_sample_rate(const AudioPipeline *p)
{
    if (!p) return 0;
    if (p->native_active) return native_decoder_sample_rate(p->native);
    return p->dec ? decoder_sample_rate(p->dec) : 0;
}

int pipeline_get_output_sample_rate(const AudioPipeline *p)
{
    return p ? p->cfg.output_sample_rate : 0;
}

int pipeline_get_output_channels(const AudioPipeline *p)
{
    return p ? p->cfg.output_channels : 0;
}

int pipeline_get_source_channels(const AudioPipeline *p)
{
    if (!p) return 0;
    if (p->native_active) return native_decoder_channels(p->native);
    return p->dec ? decoder_channels(p->dec) : 0;
}

void pipeline_destroy(AudioPipeline *p)
{
    if (!p) return;
    if (!p->flushed && p->encoder) {
        encoder_flush(p->encoder);
        p->flushed = true;
    }
    if (p->dec) decoder_close(p->dec);
    if (p->native) native_decoder_close(p->native);
    if (p->resampler) resampler_destroy(p->resampler);
    if (p->encoder) encoder_destroy(p->encoder);

    if (p->equalizer) equalizer_destroy(p->equalizer);
    if (p->loudness) loudness_destroy(p->loudness);
    if (p->limiter) limiter_destroy(p->limiter);
    if (p->tempo) tempo_destroy(p->tempo);
    if (p->fft) fft_destroy(p->fft);

    if (p->native_buf) free(p->native_buf);
    if (p->pcm_temp) free(p->pcm_temp);
    if (p->tempo_buf) free(p->tempo_buf);
    free(p);
}

const char* audio_engine_version(void)
{
    return "audio-engine-server 0.3.0 (Phase 4: decode→resample→eq→loudness→limiter→tempo→fft→encode)";
}

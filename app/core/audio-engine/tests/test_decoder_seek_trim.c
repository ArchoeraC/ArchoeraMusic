// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_decoder_seek_trim.c — FFmpeg 解码器 seek 样本级对齐回归
 *
 * 背景：`av_seek_frame(..., AVSEEK_FLAG_BACKWARD)` 只回退到目标前的关键帧，
 * 不同容器帧长差异巨大（FLAC 4096 / MP3 1152 / AAC 1024）。若不裁剪目标前的
 * 样本，跨档无缝切换（如 MP3→无损）会在拼接处回退近一帧内容 → 音量大时可闻
 * 「顿挫」。本测试用含真实 FLAC 帧的 fixture 验证 seek 后输出**严格从目标样本
 * 起**。
 *
 * 方法：
 *   1. 从 0 整曲解码 → 参考 float PCM（FLAC 无损，逐位可复现）；
 *   2. 对若干目标 ms：开新解码器 seek，取首个解码帧；
 *   3. 把首帧逐位对照参考在「目标样本」处的 PCM：裁剪正确时逐位一致；
 *      未裁剪时会整体前移（最多一帧，FLAC 可达 4096 样本）→ 差异明显。
 *
 * 用法：test_decoder_seek_trim <fixture.flac>
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavutil/samplefmt.h>

#include "decoder.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail = 1;                                                      \
        } else {                                                             \
            fprintf(stderr, "ok   %s\n", msg);                               \
        }                                                                    \
    } while (0)

/* 帧 → 交错 float（支持 U8/S16/S32/FLT 及平面/打包）。返回写入样本数。 */
static long long frame_to_f32(const AVFrame *f, float *dst, long long cap)
{
    int ch = f->ch_layout.nb_channels;
    enum AVSampleFormat fmt = (enum AVSampleFormat)f->format;
    int bps = av_get_bytes_per_sample(fmt);
    int planar = av_sample_fmt_is_planar(fmt);
    int n = f->nb_samples, i, c;
    if (ch <= 0 || n <= 0 || bps <= 0 || !f->data[0]) return 0;
    if ((long long)n * ch > cap) n = (int)(cap / ch);
    for (i = 0; i < n; i++) {
        for (c = 0; c < ch; c++) {
            const uint8_t *p = planar ? f->data[c] + (size_t)i * (size_t)bps
                                      : f->data[0] + (size_t)(i * ch + c) * (size_t)bps;
            float v = 0.0f;
            switch (fmt) {
            case AV_SAMPLE_FMT_U8:  v = (((const uint8_t *)p)[0] - 128) / 128.0f; break;
            case AV_SAMPLE_FMT_S16: v = ((const int16_t *)p)[0] / 32768.0f; break;
            case AV_SAMPLE_FMT_S32: v = (float)(((const int32_t *)p)[0] / 2147483648.0); break;
            case AV_SAMPLE_FMT_FLT: v = ((const float *)p)[0]; break;
            default: break;
            }
            dst[(long long)i * ch + c] = v;
        }
    }
    return (long long)n * ch;
}

/* 从当前解码位置把帧转 float 追加到 buf，直到累计 >= first_need 个样本
   （first_need<=0 = 解到 EOF）。返回总样本数（-1 错误）。 */
static long long drain_f32(Decoder *d, float *buf, long long cap, int ch,
                           long long first_need, int64_t *first_pts)
{
    AVFrame *f = NULL;
    long long total = 0;
    int got_first = 0;
    if (first_pts) *first_pts = AV_NOPTS_VALUE;
    for (;;) {
        int r = decoder_read_frame(d, &f);
        if (r == 0) break;
        if (r < 0) return -1;
        if (f->nb_samples <= 0) continue;
        if (!got_first) {
            if (first_pts) *first_pts = f->pts;
            got_first = 1;
        }
        {
            long long room_frames = (cap - total) / ch;
            if (room_frames <= 0) break;
            if (f->nb_samples > room_frames) {
                AVFrame tmp = *f;
                tmp.nb_samples = (int)room_frames;
                total += frame_to_f32(&tmp, buf + total, room_frames * ch);
                break;
            }
            total += frame_to_f32(f, buf + total, cap - total);
        }
        if (first_need > 0 && total >= first_need) break;
    }
    return total;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "native_seek_fixture.flac";
    const int64_t targets_ms[] = {120, 300, 480};
    Decoder *d;
    int sr, ch;
    int64_t dur_us;
    float *ref = NULL;
    long long ref_cap, ref_len;
    int i;

    d = decoder_open(path);
    CHECK(d != NULL, "打开 fixture");
    if (!d) return 2;
    sr = decoder_sample_rate(d);
    ch = decoder_channels(d);
    dur_us = decoder_duration_us(d);
    fprintf(stderr, "        codec=%s sr=%d ch=%d dur=%.1fms\n",
            decoder_codec_name(d), sr, ch, dur_us / 1000.0);
    CHECK(sr > 0 && ch > 0 && dur_us > 0, "源参数有效");
    if (sr <= 0 || ch <= 0) { decoder_close(d); return 2; }

    ref_cap = (long long)((double)dur_us * sr / 1000000.0 + sr) * ch;
    ref = (float *)malloc((size_t)ref_cap * sizeof(float));
    if (!ref) { decoder_close(d); return 2; }
    ref_len = drain_f32(d, ref, ref_cap, ch, 0, NULL);
    decoder_close(d);
    CHECK(ref_len > 0, "整曲参考解码产出 PCM");
    /* 参考必须从媒体 0 起（帧数≈容器时长），否则对齐断言无意义 */
    {
        long long dur_frames = (long long)((double)dur_us * sr / 1000000.0);
        long long diff = ref_len / ch - dur_frames;
        if (diff < 0) diff = -diff;
        CHECK(diff <= sr / 4, "参考从媒体 0 起（帧数≈时长）");
    }

    for (i = 0; i < (int)(sizeof(targets_ms) / sizeof(targets_ms[0])); i++) {
        long long target_sample = (long long)targets_ms[i] * sr / 1000;
        long long probe_frames = 512;
        long long got;
        float *buf;
        int64_t first_pts;
        double md = 0.0;
        long long k;
        char msg[192];

        if (target_sample + probe_frames >= ref_len / ch) continue; /* 越界跳过 */

        d = decoder_open(path);
        if (!d) { CHECK(0, "seek 用例：打开 fixture"); continue; }
        buf = (float *)malloc((size_t)(probe_frames + 8) * ch * sizeof(float));
        if (!buf) { decoder_close(d); continue; }
        CHECK(decoder_seek_ms(d, targets_ms[i]) == 0, "decoder_seek_ms 返回 0");
        got = drain_f32(d, buf, (probe_frames + 8) * ch, ch, probe_frames, &first_pts);
        decoder_close(d);
        CHECK(got >= probe_frames * ch, "seek 后取到足够探测样本");

        /* 首帧起点 PTS 必须已在目标处（FLAC 时间基=样本）。 */
        if (first_pts != AV_NOPTS_VALUE) {
            snprintf(msg, sizeof(msg),
                     "seek %lldms：首帧 PTS=%lld（目标样本 %lld）",
                     (long long)targets_ms[i], (long long)first_pts, target_sample);
            CHECK(llabs((long long)first_pts - target_sample) <= 1, msg);
        }

        /* 逐位对照参考在目标样本处：裁剪正确 → 完全一致。 */
        for (k = 0; k < probe_frames; k++) {
            double dl = fabs((double)buf[k * ch] - (double)ref[(target_sample + k) * ch]);
            double dr = (ch >= 2)
                ? fabs((double)buf[k * ch + 1]
                       - (double)ref[(target_sample + k) * ch + 1])
                : 0.0;
            if (dl > md) md = dl;
            if (dr > md) md = dr;
        }
        snprintf(msg, sizeof(msg),
                 "seek %lldms：首帧与参考目标样本逐位一致（maxdiff=%.2e）",
                 (long long)targets_ms[i], md);
        CHECK(md <= 1e-4, msg);
    }

    free(ref);
    if (g_fail) {
        fprintf(stderr, "test_decoder_seek_trim: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_decoder_seek_trim: ALL PASS\n");
    return 0;
}

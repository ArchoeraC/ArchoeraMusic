// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_decoder_start_time.c — FFmpeg seek 的「媒体相对时间 vs 文件绝对时间线」
 * 回归。
 *
 * fixture 是 `-output_ts_offset 2` 生成的 Matroska（format/stream start_time =
 * 2.0s，媒体内容只有 0~1s）。`offset_ms` 是媒体相对时间，因此
 * `av_seek_frame(-1, offset_ms*1000)` 必须加 start_time 才能落到媒体 0.4s；
 * 旧实现只传 0.4s（绝对时间线 < start_time）→ 永远落在曲首，seek 与进度条
 * 错位、跨档 stage origin 也会跟着错。
 *
 * 断言：seek 400ms 后的 PCM 与整曲参考在 400ms 处一致（允许容器 ms 时间基
 * 带来的 ≤1ms 取整误差）。
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

static long long drain_f32(Decoder *d, float *buf, long long cap, int ch,
                           long long need)
{
    AVFrame *f = NULL;
    long long total = 0;
    for (;;) {
        int r = decoder_read_frame(d, &f);
        if (r == 0) break;
        if (r < 0) return -1;
        if (f->nb_samples <= 0) continue;
        long long room = (cap - total) / ch;
        if (room <= 0) break;
        if (f->nb_samples > room) {
            AVFrame tmp = *f;
            tmp.nb_samples = (int)room;
            total += frame_to_f32(&tmp, buf + total, room * ch);
            break;
        }
        total += frame_to_f32(f, buf + total, cap - total);
        if (need > 0 && total >= need) break;
    }
    return total;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "start_time_fixture.mkv";
    const int target_ms = 400;
    const long long probe_frames = 256;
    Decoder *d;
    int sr, ch;
    long long ref_cap, ref_len;
    float *ref = NULL;
    float *got = NULL;
    long long target_sample;
    long long lag, best_lag = 0;
    double best = 1e9;
    char msg[192];

    d = decoder_open(path);
    CHECK(d != NULL, "打开 start_time fixture");
    if (!d) return 2;
    sr = decoder_sample_rate(d);
    ch = decoder_channels(d);
    fprintf(stderr, "        codec=%s sr=%d ch=%d\n",
            decoder_codec_name(d), sr, ch);
    CHECK(sr > 0 && ch > 0, "源参数有效");
    if (sr <= 0 || ch <= 0) { decoder_close(d); return 2; }

    ref_cap = (long long)(sr * 2.0 + sr) * ch; /* fixture 媒体时长 1s，留余量 */
    ref = (float *)malloc((size_t)ref_cap * sizeof(float));
    got = (float *)malloc((size_t)(probe_frames + 16) * ch * sizeof(float));
    if (!ref || !got) { decoder_close(d); free(ref); free(got); return 2; }
    ref_len = drain_f32(d, ref, ref_cap, ch, 0);
    decoder_close(d);
    CHECK(ref_len > 0, "整曲参考解码产出 PCM");
    /* 参考必须从媒体 0 起：约 1s，而不是容器 start_time + 1s。 */
    CHECK(ref_len / ch >= sr / 2 && ref_len / ch <= (long long)(sr * 1.5),
          "参考从媒体 0 起（约 1s）");

    target_sample = (long long)target_ms * sr / 1000;
    if (target_sample + probe_frames >= ref_len / ch) {
        CHECK(0, "目标样本落在参考范围内");
        free(ref); free(got); return 1;
    }

    d = decoder_open(path);
    CHECK(d != NULL, "seek 用例打开 fixture");
    if (!d) { free(ref); free(got); return 2; }
    CHECK(decoder_seek_ms(d, target_ms) == 0, "decoder_seek_ms 返回 0");
    {
        long long n = drain_f32(d, got, (probe_frames + 16) * ch, ch,
                                probe_frames);
        decoder_close(d);
        CHECK(n >= probe_frames * ch, "seek 后取到足够探测样本");
        if (n < probe_frames * ch) { free(ref); free(got); return 1; }
    }

    /* 容器时间基可能是 1ms，trim 落点允许 <1ms 的取整误差：在 ±1ms 内找
       最佳对齐；旧实现整段提前 2s（落在媒体 0），任何 lag 都对不上。 */
    {
        long long max_lag = (sr + 999) / 1000 + 2;
        for (lag = -max_lag; lag <= max_lag; lag++) {
            long long base = target_sample + lag;
            long long i;
            double md = 0.0;
            if (base < 0 || base + probe_frames > ref_len / ch) continue;
            for (i = 0; i < probe_frames; i++) {
                double dl = fabs((double)got[i * ch] - (double)ref[(base + i) * ch]);
                double dr = (ch >= 2)
                    ? fabs((double)got[i * ch + 1] - (double)ref[(base + i) * ch + 1])
                    : 0.0;
                if (dl > md) md = dl;
                if (dr > md) md = dr;
                if (md > best) break;
            }
            if (md < best) { best = md; best_lag = lag; }
        }
    }
    snprintf(msg, sizeof(msg),
             "seek %dms 后内容对齐媒体目标（lag=%lld 样本，maxdiff=%.2e）",
             target_ms, best_lag, best);
    CHECK(best <= 1e-4, msg);

    free(ref);
    free(got);
    if (g_fail) {
        fprintf(stderr, "test_decoder_start_time: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_decoder_start_time: ALL PASS\n");
    return 0;
}

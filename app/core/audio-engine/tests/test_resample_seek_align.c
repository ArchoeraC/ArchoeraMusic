// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_resample_seek_align.c — 跨采样率切档的「seek + 重采样」对齐回归
 *
 * 背景：Hi-Res（96k/24bit）与 LQ（44.1k/128k）热切时，暂存管线按活动管线的
 * 输出采样率锁定输出（例如 96k→44.1k 下采样 / 44.1k→96k 上采样）。如果
 * `position_ms`（stage 首样本媒体时间）把重采样器延迟/块长度算错，commit 的
 * 交叠裁剪会多丢或少丢样本 → 拼接处可闻「顿挫」。
 *
 * 方法：
 *   1. 用同一连续时间函数生成 44.1k 与 96k 两个 WAV（同一信号）；
 *   2. 参考 = 直接以目标输出率整曲解码（从 0 起）；
 *   3. 新源以目标输出率 + start_offset_ms=X 打开（模拟 prepare_source 的
 *      seek），断言：
 *        - 首个 PCM 回调的 position_ms == X（块起点语义）；
 *        - 首个回调的前 N 帧与参考在 X 处的波形一致（≤1e-3）；
 *   4. 双向覆盖：44.1k→96k（上采样）与 96k→44.1k（下采样），
 *      FFmpeg 与 EraAudio 两条解码后端。
 *
 * 用法：test_resample_seek_align <workdir>
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_engine.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

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

/* 确定性立体声 PCM16 WAV：信号是**连续时间的函数**，所以任意采样率生成的
   内容在带宽内一致（用于跨采样率对照）。 */
static int write_sig_wav(const char *path, double seconds, int sr, int bits)
{
    const int ch = 2;
    long total = (long)(seconds * sr);
    FILE *f;
    unsigned char *buf;
    long i;
    int c;
    unsigned int data_size;
    unsigned int riff, fmt = 16;
    unsigned short pcm = 1, wch = (unsigned short)ch;
    unsigned short align;
    unsigned int rate, brate;

    if (total <= 0 || sr <= 0 || (bits != 16 && bits != 24)) return -1;
    data_size = (unsigned int)(total * ch * (bits / 8));
    riff = 36 + data_size;
    align = (unsigned short)(ch * (bits / 8));
    rate = (unsigned int)sr;
    brate = rate * ch * (bits / 8);

    f = fopen(path, "wb");
    if (!f) return -1;
    buf = (unsigned char *)malloc((size_t)data_size);
    if (!buf) { fclose(f); return -1; }
    for (i = 0; i < total; i++) {
        double t = (double)i / (double)sr;
        double v[2];
        v[0] = 0.25 * sin(2.0 * M_PI * 440.0 * t)
             + 0.15 * sin(2.0 * M_PI * 1500.0 * t);
        v[1] = 0.25 * sin(2.0 * M_PI * 500.0 * t + 0.7)
             + 0.15 * sin(2.0 * M_PI * 2100.0 * t);
        for (c = 0; c < ch; c++) {
            unsigned char *pb = buf + ((size_t)i * ch + c) * (bits / 8);
            if (bits == 16) {
                int32_t s = (int32_t)lrint(v[c] * 30000.0);
                pb[0] = (unsigned char)(s & 0xff);
                pb[1] = (unsigned char)((s >> 8) & 0xff);
            } else {
                int32_t s = (int32_t)lrint(v[c] * 30000.0 * 256.0);
                pb[0] = (unsigned char)(s & 0xff);
                pb[1] = (unsigned char)((s >> 8) & 0xff);
                pb[2] = (unsigned char)((s >> 16) & 0xff);
            }
        }
    }
    fwrite("RIFF", 1, 4, f);
    fwrite(&riff, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt, 4, 1, f);
    fwrite(&pcm, 2, 1, f);
    fwrite(&wch, 2, 1, f);
    fwrite(&rate, 4, 1, f);
    fwrite(&brate, 4, 1, f);
    fwrite(&align, 2, 1, f);
    fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f);
    fwrite(&data_size, 4, 1, f);
    fwrite(buf, 1, data_size, f);
    free(buf);
    fclose(f);
    return sr;
}

typedef struct {
    float *data;
    long long frames;       /* 已捕获帧数 */
    long long cap_frames;
    int ch;
    double first_pos_ms;    /* 首个非空回调的块起点 */
    int have_first;
} Capture;

static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

static void capture_cb(const float *pcm, int samples, int channels,
                       double pos_ms, void *user)
{
    Capture *c = (Capture *)user;
    if (!c || !pcm || samples <= 0 || channels <= 0) return;
    if (!c->have_first) {
        c->first_pos_ms = pos_ms;
        c->have_first = 1;
        c->ch = channels;
    }
    if (!c->data || c->frames >= c->cap_frames) return;
    {
        long long want = c->cap_frames - c->frames;
        int take = (samples < want) ? samples : (int)want;
        memcpy(c->data + c->frames * c->ch, pcm,
               (size_t)take * (size_t)c->ch * sizeof(float));
        c->frames += take;
    }
}

/* 以指定输出采样率、从 start_ms 起解码，捕获前 cap_frames 帧。 */
static int capture_seek(const char *src, int out_rate, int engine_mode,
                        int64_t start_ms, Capture *c, int cap_frames)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    AudioPipeline *p;
    int guard = 0;

    memset(c, 0, sizeof(*c));
    c->cap_frames = cap_frames;
    c->data = (float *)calloc((size_t)cap_frames * 2, sizeof(float));
    if (!c->data) return -1;

    cfg.skip_encoder = true;
    cfg.engine_mode = engine_mode;
    cfg.output_sample_rate = out_rate;
    cfg.output_channels = 2;
    cfg.start_offset_ms = start_ms;

    p = pipeline_create(src, &cfg, dummy_output, NULL);
    if (!p) {
        fprintf(stderr, "        pipeline_create 失败: %s (out=%d mode=%d start=%lld)\n",
                src, out_rate, engine_mode, (long long)start_ms);
        free(c->data);
        c->data = NULL;
        return -1;
    }
    pipeline_set_pcm_out_cb(p, capture_cb, c);
    while (c->frames < c->cap_frames && guard++ < 100000) {
        long long n = (long long)pipeline_process(p);
        if (n <= 0) {
            fprintf(stderr, "        pipeline_process=%ld frames=%lld src=%s out=%d\n",
                    (long)n, c->frames, src, out_rate);
            break;
        }
    }
    pipeline_destroy(p);
    return c->frames > 0 ? 0 : -1;
}

static int check_pair(const char *src, int src_rate, const char *ref_src,
                      int out_rate, int engine_mode, int64_t start_ms,
                      int frames)
{
    Capture ref, got;
    char msg[256];
    long long ref_index;
    double maxdiff = 0.0;
    int k;
    int ok = 1;

    if (capture_seek(ref_src, out_rate, engine_mode, 0, &ref,
                     (int)((double)out_rate * 4.0)) != 0) {
        snprintf(msg, sizeof(msg), "参考解码（%s, %dHz, mode=%d）",
                 ref_src, out_rate, engine_mode);
        CHECK(0, msg);
        free(ref.data);
        return 0;
    }
    if (capture_seek(src, out_rate, engine_mode, start_ms, &got, frames) != 0) {
        snprintf(msg, sizeof(msg), "seek 解码（%s %dHz→%dHz, mode=%d, %lldms）",
                 src, src_rate, out_rate, engine_mode, (long long)start_ms);
        CHECK(0, msg);
        free(ref.data);
        free(got.data);
        return 0;
    }

    /* 块起点必须是请求的媒体时间（stage[0] 对齐的依据）。 */
    snprintf(msg, sizeof(msg),
             "%s %d→%d mode=%d seek=%lldms：首块 position_ms=%.3f",
             src, src_rate, out_rate, engine_mode, (long long)start_ms,
             got.first_pos_ms);
    CHECK(fabs(got.first_pos_ms - (double)start_ms) <= 0.51, msg);

    ref_index = (long long)llround((double)start_ms * (double)out_rate / 1000.0);
    if (ref_index < 0 || ref_index + frames > ref.frames) {
        snprintf(msg, sizeof(msg),
                 "参考窗口越界（start=%lld, frames=%d, ref=%lld）",
                 (long long)ref_index, frames, ref.frames);
        CHECK(0, msg);
        free(ref.data);
        free(got.data);
        return 0;
    }
    /* 跳过重采样器冷启动（有限滤波器前导，约数十样本）：stage 在 commit 前
       已预解码 ≥1.5s，接缝远在冷启动之后；这里只校验稳态波形是否严格对齐。 */
    for (k = 64; k < frames; k++) {
        double dl = fabs((double)got.data[k * 2] - (double)ref.data[(ref_index + k) * 2]);
        double dr = fabs((double)got.data[k * 2 + 1]
                         - (double)ref.data[(ref_index + k) * 2 + 1]);
        if (dl > maxdiff) maxdiff = dl;
        if (dr > maxdiff) maxdiff = dr;
    }
    snprintf(msg, sizeof(msg),
             "%s %d→%d mode=%d seek=%lldms：波形与参考一致（maxdiff=%.2e）",
             src, src_rate, out_rate, engine_mode, (long long)start_ms, maxdiff);
    CHECK(maxdiff <= 1e-3, msg);
    if (maxdiff > 1e-3) ok = 0;

    free(ref.data);
    free(got.data);
    return ok;
}

int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1] : ".";
    char wav44[1024], wav96[1024], wav96_24[1024];
    static const int64_t targets[] = {120, 300, 480, 1000, 2000, 2500};
    const int frames = 1024;
    int i, mode;

    snprintf(wav44, sizeof(wav44), "%s/cross_rate_44.wav", dir);
    snprintf(wav96, sizeof(wav96), "%s/cross_rate_96.wav", dir);
    snprintf(wav96_24, sizeof(wav96_24), "%s/cross_rate_96_24.wav", dir);
    if (write_sig_wav(wav44, 6.0, 44100, 16) < 0 ||
        write_sig_wav(wav96, 6.0, 96000, 16) < 0 ||
        write_sig_wav(wav96_24, 6.0, 96000, 24) < 0) {
        fprintf(stderr, "无法生成测试 WAV（dir=%s）\n", dir);
        return 2;
    }

    for (mode = 0; mode <= 1; mode++) {
        fprintf(stderr, "── engine_mode=%d（%s）──\n", mode,
                mode == 0 ? "FFmpeg" : "EraAudio");
        for (i = 0; i < (int)(sizeof(targets) / sizeof(targets[0])); i++) {
            /* 同采样率（对照组：验证 seek 本身对齐） */
            check_pair(wav44, 44100, wav44, 44100, mode, targets[i], frames);
            /* 下采样：96k 新源 → 44.1k 输出（Hi-Res → LQ 活动管线） */
            check_pair(wav96, 96000, wav44, 44100, mode, targets[i], frames);
            /* 24bit/96k（Hi-Res 典型）→ 44.1k */
            check_pair(wav96_24, 96000, wav44, 44100, mode, targets[i], frames);
            /* 上采样：44.1k 新源 → 96k 输出（LQ → Hi-Res 活动管线） */
            check_pair(wav44, 44100, wav96, 96000, mode, targets[i], frames);
        }
    }

    if (g_fail) {
        fprintf(stderr, "test_resample_seek_align: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_resample_seek_align: ALL PASS\n");
    return 0;
}

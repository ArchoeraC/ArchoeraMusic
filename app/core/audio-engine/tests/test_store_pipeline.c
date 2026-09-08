// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* store→pipeline 接线冒烟（M1.5，docs/audio-memory-source.md §7）：读入单个音频
 * fixture 全部字节预填 SegStore，然后同 cfg（skip_encoder、output_channels=2、
 * engine_mode 取 0=Stable 使两路同为 FFmpeg）分别用 pipeline_create(磁盘路径) 与
 * pipeline_create_store(store) 跑完整 DSP 链：断言两路都能打开、pcm 流出帧数 > 0
 * 且相等、输出采样率/声道一致。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_engine.h"
#include "segstore.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                             \
    do {                                                             \
        if (!(cond)) {                                               \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg); \
            g_fail++;                                                \
        } else {                                                     \
            fprintf(stderr, "ok   %s\n", msg);                       \
        }                                                            \
    } while (0)

typedef struct {
    long frames;   /* 累计 pcm 流出帧数（每声道） */
    int  channels; /* 最后一次回调报告的声道数 */
} PcmStat;

static void pcm_counter(const float *pcm, int samples, int channels,
                        double position_ms, void *user)
{
    (void)pcm;
    (void)position_ms;
    PcmStat *s = (PcmStat *)user;
    s->frames += samples;
    s->channels = channels;
}

/* skip_encoder 模式不会调用；API 要求非 NULL，占位即可 */
static int dummy_output(const uint8_t *data, size_t size, void *user_data)
{
    (void)data;
    (void)size;
    (void)user_data;
    return 0;
}

/* 跑一路管线到 EOF，返回 pcm 流出帧数；p 为 NULL 视为打开失败 */
static long run_pipeline(AudioPipeline *p)
{
    if (!p) return -1;
    PcmStat st = {0, 0};
    pipeline_set_pcm_out_cb(p, pcm_counter, &st);
    int rc = pipeline_run(p);
    if (rc < 0) return -1;
    return st.frames;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <audio>\n", argv[0]);
        return 2;
    }
    const char *file = argv[1];

    FILE *f = fopen(file, "rb");
    CHECK(f != NULL, "fopen（可读）");
    if (!f) return 1;

    fseek(f, 0, SEEK_END);
    long flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    CHECK(flen > 0, "文件非空");
    if (flen <= 0) { fclose(f); return 1; }

    unsigned char *bytes = (unsigned char *)malloc((size_t)flen);
    if (!bytes || fread(bytes, 1, (size_t)flen, f) != (size_t)flen) {
        CHECK(bytes && 0, "fread 读入完整");
        fclose(f);
        free(bytes);
        return 1;
    }
    fclose(f);

    SegStore *st = segstore_new((uint64_t)flen, 0, 0);
    CHECK(st != NULL, "segstore_new");
    if (!st || segstore_fill(st, 0, bytes, (size_t)flen) != 0) {
        CHECK(0, "segstore_fill（整曲预填）");
        free(bytes);
        if (st) segstore_destroy(st);
        return 1;
    }
    free(bytes);

    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    cfg.skip_encoder = true;   /* PCM 直出，不建 Opus 编码器 */
    cfg.output_channels = 2;
    cfg.engine_mode = 0;       /* Stable=FFmpeg：磁盘/Store 两路同为 FFmpeg 对拍 */

    AudioPipeline *pd = pipeline_create(file, &cfg, dummy_output, NULL);
    CHECK(pd != NULL, "pipeline_create（磁盘路径）打开");
    AudioPipeline *ps = pipeline_create_store(st, &cfg, dummy_output, NULL);
    CHECK(ps != NULL, "pipeline_create_store（SegStore 源）打开");

    if (pd && ps) {
        CHECK(pipeline_get_source_sample_rate(pd) > 0, "磁盘源采样率可读");
        CHECK(pipeline_get_source_sample_rate(pd) ==
              pipeline_get_source_sample_rate(ps), "两路源采样率一致");
        CHECK(pipeline_get_source_channels(pd) ==
              pipeline_get_source_channels(ps), "两路源声道一致");
        CHECK(pipeline_get_output_sample_rate(pd) > 0 &&
              pipeline_get_output_sample_rate(pd) ==
              pipeline_get_output_sample_rate(ps), "两路输出采样率一致");
        CHECK(pipeline_get_output_channels(pd) == 2 &&
              pipeline_get_output_channels(pd) ==
              pipeline_get_output_channels(ps), "两路输出声道一致(2)");

        long disk = run_pipeline(pd);
        long mem  = run_pipeline(ps);
        fprintf(stderr, "      disk pcm frames=%ld / store pcm frames=%ld\n",
                disk, mem);
        CHECK(disk > 0, "磁盘路径 pcm 流出帧数 > 0");
        CHECK(mem > 0,  "store 内存源 pcm 流出帧数 > 0");
        CHECK(disk == mem, "磁盘与 store 两路 pcm 帧数一致");
    }

    if (pd) pipeline_destroy(pd);
    if (ps) pipeline_destroy(ps);
    segstore_destroy(st);

    if (g_fail) {
        fprintf(stderr, "test_store_pipeline: FAILED（累计失败 %d）\n", g_fail);
        return 1;
    }
    fprintf(stderr, "test_store_pipeline: ALL PASS\n");
    return 0;
}

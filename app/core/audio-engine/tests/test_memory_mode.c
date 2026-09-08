// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_memory_mode.c — 内存播放（不落盘）模式回归测试（headless，不碰音频设备）
 *
 * 规格：docs/audio-memory-playback.md §8
 *  1. 内存模式会话（headless 全速解码到 EOF）会话目录**不产生** stream.wav/.pcm；
 *  2. pcm_window 与参考解码（测试内另建 pipeline + 同构捕获）窗口一致（≤1e-4）；
 *  3. cap 语义：-1（无上限）整曲可回访；>0 达 cap 滚动淘汰（旧视窗 -1、近尾仍 0，
 *     且近尾窗口与无上限会话一致——记账淘汰未篡改保留数据）；
 *  4. 参数错误返回 -2（NULL 句柄 / frames<=0）；
 *  5. store 内存源会话（M2：整曲预填 SegStore → archoera_mediaengine_create_store
 *     → AVIO-mem 解码）产出与参考一致且不落盘；引擎 destroy 不释放 store。
 *
 * 驱动方式：引擎会话以 ARCHOERA_MEMORY_HEADLESS=1 走「无设备解码到内存」分支
 * （mediaengine_lib.c engine_thread），不初始化音频设备，可在无声 CI 上运行。
 * 与 test_mediaengine_wait 同法：直接编译 mediaengine_lib.c + tempo.c stub。
 */
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#include "audio_engine.h"
#include "archoera_mediaengine.h"
#include "segstore.h"

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

/* ── 参考块列表（镜像引擎内存块 / stream.pcm 同构）──────────────── */
typedef struct RefBlock {
    int32_t pos_ms;
    int32_t frames;
    int32_t channels;
    int64_t start;
    float  *data;
} RefBlock;

static RefBlock *g_blocks;
static int g_block_cap;
static int g_block_count;

static void ref_reset(void)
{
    int i;
    for (i = 0; i < g_block_count; i++) free(g_blocks[i].data);
    g_block_count = 0;
}

static void ref_capture(const float *pcm, int samples, int channels,
                        double pos_ms, void *user)
{
    RefBlock *b;
    (void)user;
    if (samples <= 0 || channels <= 0) return;
    if (g_block_count == g_block_cap) {
        int ncap = g_block_cap ? g_block_cap * 2 : 64;
        RefBlock *nb = (RefBlock *)realloc(g_blocks, (size_t)ncap * sizeof(*nb));
        if (!nb) return;
        g_blocks = nb;
        g_block_cap = ncap;
    }
    b = &g_blocks[g_block_count];
    b->data = (float *)malloc((size_t)samples * (size_t)channels * sizeof(float));
    if (!b->data) return;
    memcpy(b->data, pcm, (size_t)samples * (size_t)channels * sizeof(float));
    b->pos_ms = (int32_t)pos_ms;
    b->frames = samples;
    b->channels = channels;
    b->start = (g_block_count > 0)
        ? g_blocks[g_block_count - 1].start + g_blocks[g_block_count - 1].frames
        : 0;
    g_block_count++;
}

static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

/* 参考窗口：与引擎 mem_window 同语义（终点块内取整、前缀补零、跨块、L/R）。
   返回 0 命中；-1 无数据。仅 2ch 直通（测试源 2ch，引擎输出恒 2ch）。 */
static int ref_window(int sr, int end_pos_ms, int frames,
                      float *out_l, float *out_r)
{
    int bi = -1;
    int i;
    if (g_block_count <= 0) return -1;
    for (i = g_block_count - 1; i >= 0; i--) {
        if (g_blocks[i].pos_ms <= end_pos_ms) { bi = i; break; }
    }
    if (bi < 0) return -1;
    {
        int64_t off_ms = (int64_t)end_pos_ms - g_blocks[bi].pos_ms;
        int in_block;
        int64_t end_sample, start_sample;
        int fill, si;
        if (off_ms < 0) off_ms = 0;
        in_block = (int)((off_ms * (int64_t)sr + 500) / 1000);
        if (in_block >= g_blocks[bi].frames) in_block = g_blocks[bi].frames - 1;
        end_sample = g_blocks[bi].start + in_block;
        start_sample = end_sample - (int64_t)frames + 1;
        if (start_sample < 0 && g_blocks[0].start != 0) return -1;
        memset(out_l, 0, (size_t)frames * sizeof(float));
        memset(out_r, 0, (size_t)frames * sizeof(float));
        fill = 0;
        si = (int)start_sample;
        if (si < 0) { fill = -si; si = 0; }
        while (fill < frames) {
            int b2 = -1;
            for (i = 0; i < g_block_count; i++) {
                if (g_blocks[i].start <= si &&
                    si < g_blocks[i].start + g_blocks[i].frames) { b2 = i; break; }
            }
            if (b2 < 0) break;
            {
                RefBlock *bb = &g_blocks[b2];
                int64_t bStart = si - bb->start;
                int avail = (int)(bb->frames - bStart);
                int take = frames - fill;
                int c;
                if (take > avail) take = avail;
                for (c = 0; c < take; c++) {
                    const float *d = bb->data + (size_t)(bStart + c) * bb->channels;
                    out_l[fill + c] = d[0];
                    out_r[fill + c] = (bb->channels >= 2) ? d[1] : d[0];
                }
                fill += take;
                si += take;
            }
        }
        if (fill <= 0) return -1;
    }
    return 0;
}

/* 生成确定性立体声 PCM16 WAV（44.1k/2ch），返回采样率 */
static int write_sine_wav(const char *path, double seconds)
{
    const int sr = 44100;
    const int ch = 2;
    long total = (long)(seconds * sr);
    FILE *f;
    short *buf;
    long i;
    unsigned int data_size = (unsigned int)(total * ch * 2);
    unsigned int riff = 36 + data_size;
    unsigned int fmt = 16;
    unsigned short pcm = 1, wch = (unsigned short)ch, align = (unsigned short)(ch * 2);
    unsigned short bits = 16;
    unsigned int rate = sr, brate = rate * wch * 2;
    if (!path) return -1;
    f = fopen(path, "wb");
    if (!f) return -1;
    buf = (short *)malloc((size_t)total * ch * sizeof(short));
    if (!buf) { fclose(f); return -1; }
    for (i = 0; i < total; i++) {
        double t = (double)i / sr;
        double l = 0.25 * sin(2.0 * M_PI * 440.0 * t)
                 + 0.15 * sin(2.0 * M_PI * 1500.0 * t);
        double r = 0.25 * sin(2.0 * M_PI * 500.0 * t + 0.7)
                 + 0.15 * sin(2.0 * M_PI * 2100.0 * t);
        buf[i * ch] = (short)(l * 30000.0);
        buf[i * ch + 1] = (short)(r * 30000.0);
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
    fwrite(buf, 2, (size_t)total * ch, f);
    free(buf);
    fclose(f);
    return sr;
}

static int file_exists(const char *p)
{
    struct stat st;
    return p && stat(p, &st) == 0;
}

static int dir_has_stream_files(const char *sdir)
{
    char p[512];
    snprintf(p, sizeof(p), "%s/stream.wav", sdir);
    if (file_exists(p)) return 1;
    snprintf(p, sizeof(p), "%s/stream.pcm", sdir);
    if (file_exists(p)) return 1;
    return 0;
}

/* 跑一个引擎内存模式会话（headless）并等其线程退出 */
static ArchoeraMediaEngine *run_mem_session(const char *src, const char *sdir,
                                            long long cap_kb,
                                            char *errbuf, int errcap)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    ArchoeraMediaEngine *e;
    char wav[512];
    int waited = 0;
    snprintf(wav, sizeof(wav), "%s/stream.wav", sdir);
    cfg.no_disk_cache = 1;
    cfg.pcm_mem_cap_kb = cap_kb;
    e = archoera_mediaengine_create(src, &cfg, wav, sdir, errbuf, errcap);
    if (!e) {
        fprintf(stderr, "create failed: %s\n", errbuf);
        return NULL;
    }
    while (!archoera_mediaengine_is_done(e) && waited < 20000) {
        struct timespec ts = {0, 5 * 1000000L};
        nanosleep(&ts, NULL);
        waited += 5;
    }
    if (waited >= 20000) {
        fprintf(stderr, "engine not done within 20s\n");
        g_fail = 1;
    }
    return e;
}

/* 跑一个「store 内存源」引擎会话（M2 链路：Dart 整曲预填 → SegStore →
 * archoera_mediaengine_create_store → 引擎 AVIO-mem 解码，headless 无设备）。
 * store 指针经 store_out 归还：所有权归调用方，须在 archoera_mediaengine_destroy
 * 之后 segstore_destroy。 */
static ArchoeraMediaEngine *run_store_session(const char *path, const char *sdir,
                                              long long cap_kb, SegStore **store_out,
                                              char *errbuf, int errcap)
{
    FILE *f;
    long flen;
    unsigned char *bytes;
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    ArchoeraMediaEngine *e;
    SegStore *st;
    char wav[1024];
    int waited = 0;

    if (store_out) *store_out = NULL;
    f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (flen <= 0) { fclose(f); return NULL; }
    bytes = (unsigned char *)malloc((size_t)flen);
    if (!bytes || fread(bytes, 1, (size_t)flen, f) != (size_t)flen) {
        free(bytes);
        fclose(f);
        return NULL;
    }
    fclose(f);

    st = segstore_new((uint64_t)flen, 0, 0);
    if (!st || segstore_fill(st, 0, bytes, (size_t)flen) != 0) {
        fprintf(stderr, "store 整曲预填失败\n");
        if (st) segstore_destroy(st);
        free(bytes);
        return NULL;
    }
    free(bytes);

    snprintf(wav, sizeof(wav), "%s/stream.wav", sdir);
    cfg.no_disk_cache = 1;
    cfg.pcm_mem_cap_kb = cap_kb;
    e = archoera_mediaengine_create_store(st, &cfg, wav, sdir, errbuf, errcap);
    if (!e) {
        fprintf(stderr, "create_store failed: %s\n", errbuf);
        segstore_destroy(st);
        return NULL;
    }
    if (store_out) *store_out = st; /* destroy 引擎后由调用方释放 */

    while (!archoera_mediaengine_is_done(e) && waited < 20000) {
        struct timespec ts = {0, 5 * 1000000L};
        nanosleep(&ts, NULL);
        waited += 5;
    }
    if (waited >= 20000) {
        fprintf(stderr, "store 引擎 not done within 20s\n");
        g_fail = 1;
    }
    return e;
}

static int max_diff(const float *a, const float *b, int n, double *out)
{
    double m = 0.0;
    int i;
    for (i = 0; i < n; i++) {
        double d = fabs((double)a[i] - (double)b[i]);
        if (d > m) m = d;
    }
    *out = m;
    return 0;
}

int main(void)
{
    const int frames = 1024;
    const double dur_sec = 8.0;
    char base[] = "/tmp/archoera-mem-test-XXXXXX";
    char wav_path[512], dir_full[512], dir_ev[512], dir_st[512];
    char errbuf[256];
    EngineConfig rcfg = ENGINE_CONFIG_DEFAULT;
    AudioPipeline *rp;
    ArchoeraMediaEngine *efull = NULL, *eev = NULL, *est = NULL;
    SegStore *st = NULL;
    float *l, *r, *l2, *r2;
    int sr;
    long total_ms;
    int ok;

    if (!mkdtemp(base)) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(wav_path, sizeof(wav_path), "%s/src.wav", base);
    snprintf(dir_full, sizeof(dir_full), "%s/full", base);
    snprintf(dir_ev, sizeof(dir_ev), "%s/ev", base);
    snprintf(dir_st, sizeof(dir_st), "%s/store", base);
    mkdir(dir_full, 0700);
    mkdir(dir_ev, 0700);
    mkdir(dir_st, 0700);

    sr = write_sine_wav(wav_path, dur_sec);
    CHECK(sr == 44100, "生成确定性 44.1k 立体声测试源");
    if (sr != 44100) return 2;
    total_ms = (long)(dur_sec * 1000.0);

    l = (float *)calloc((size_t)frames, sizeof(float));
    r = (float *)calloc((size_t)frames, sizeof(float));
    l2 = (float *)calloc((size_t)frames, sizeof(float));
    r2 = (float *)calloc((size_t)frames, sizeof(float));
    if (!l || !r || !l2 || !r2) return 2;

    setenv("ARCHOERA_MEMORY_HEADLESS", "1", 1);

    /* 0) 参考解码：同一 pipeline + 同构捕获（窗口真值） */
    rcfg.skip_encoder = true;
    rp = pipeline_create(wav_path, &rcfg, dummy_output, NULL);
    CHECK(rp != NULL, "参考 pipeline_create");
    if (rp) {
        ssize_t n;
        pipeline_set_pcm_out_cb(rp, ref_capture, NULL);
        while ((n = pipeline_process(rp)) > 0) {}
        pipeline_run(rp);
        pipeline_destroy(rp);
    }
    CHECK(g_block_count > 0, "参考解码产出 PCM 块");
    fprintf(stderr, "        参考块数=%d\n", g_block_count);

    /* 1) 无上限会话：整曲可回访 + 窗口与参考一致 + 不落盘 */
    efull = run_mem_session(wav_path, dir_full, -1, errbuf, sizeof(errbuf));
    CHECK(efull != NULL, "内存模式（无上限）会话可创建");
    if (efull) {
        const long probes[4] = { 200, 1500, 5000, total_ms - 60 };
        ok = 1;
        CHECK(archoera_mediaengine_pcm_epoch(efull) >= 0, "pcm_epoch 可用（>=0）");
        for (int i = 0; i < 4; i++) {
            double md;
            if (archoera_mediaengine_pcm_window(efull, (int)probes[i], frames,
                                                l, r) != 0 ||
                ref_window(sr, (int)probes[i], frames, l2, r2) != 0) {
                ok = 0;
                break;
            }
            max_diff(l, l2, frames, &md);
            if (md > 1e-4) ok = 0;
            max_diff(r, r2, frames, &md);
            if (md > 1e-4) ok = 0;
        }
        CHECK(ok, "无上限会话 pcm_window 与参考一致（4 处，≤1e-4）");
        CHECK(!dir_has_stream_files(dir_full),
              "无上限会话不落盘（无 stream.wav/.pcm）");
        CHECK(archoera_mediaengine_pcm_window(efull, 1500, 0, l, r) == -2,
              "frames<=0 → -2");
        CHECK(archoera_mediaengine_pcm_window(NULL, 1500, frames, l, r) == -2,
              "NULL 句柄 → -2");
        /* 保存尾部窗口，供小 cap 会话对比（淘汰后近尾仍一致） */
        archoera_mediaengine_pcm_window(efull, (int)(total_ms - 60), frames,
                                        l2, r2);
    }

    /* 2) 用户上限会话（1 MiB，远小于整曲 ~2.8MB f32）：滚动淘汰生效 */
    eev = run_mem_session(wav_path, dir_ev, 1024, errbuf, sizeof(errbuf));
    CHECK(eev != NULL, "内存模式（cap=1MiB）会话可创建");
    if (eev) {
        CHECK(!dir_has_stream_files(dir_ev),
              "cap 会话同样不落盘（无 stream.wav/.pcm）");
        CHECK(archoera_mediaengine_pcm_window(eev, (int)(total_ms - 60), frames,
                                              l, r) == 0,
              "cap 会话近尾窗口可命中（保留尾部）");
        CHECK(archoera_mediaengine_pcm_window(eev, 200, frames, l, r) == -1,
              "cap 会话早期窗口 -1（已滚动淘汰）");
        if (efull) {
            double md;
            max_diff(l, l2, frames, &md);
            CHECK(md <= 1e-4,
                  "cap 会话近尾窗口与无上限会话一致（淘汰不篡改数据）");
        }
    }

    /* 3) store 内存源会话（M2 最小链路：Dart 整曲预填 → SegStore → create_store
       → AVIO-mem 解码，headless）：ready/done 解码产出与参考一致 + 不落盘；
       destroy 引擎后再 segstore_destroy（store 归调用方，引擎不释放）。 */
    est = run_store_session(wav_path, dir_st, -1, &st, errbuf, sizeof(errbuf));
    CHECK(est != NULL, "store 内存源会话可创建");
    if (est) {
        ok = 1;
        const long probes[4] = { 200, 1500, 5000, total_ms - 60 };
        CHECK(!dir_has_stream_files(dir_st),
              "store 会话不落盘（无 stream.wav/.pcm）");
        for (int i = 0; i < 4; i++) {
            double md;
            if (archoera_mediaengine_pcm_window(est, (int)probes[i], frames,
                                                l, r) != 0 ||
                ref_window(sr, (int)probes[i], frames, l2, r2) != 0) {
                ok = 0;
                break;
            }
            max_diff(l, l2, frames, &md);
            if (md > 1e-4) ok = 0;
            max_diff(r, r2, frames, &md);
            if (md > 1e-4) ok = 0;
        }
        CHECK(ok, "store 会话 pcm_window 与参考一致（4 处，≤1e-4）");
        CHECK(archoera_mediaengine_pcm_epoch(est) >= 0, "store 会话 pcm_epoch 可用");
    }

    if (efull) archoera_mediaengine_destroy(efull);
    if (eev) archoera_mediaengine_destroy(eev);
    if (est) archoera_mediaengine_destroy(est);
    if (st) segstore_destroy(st); /* 引擎 destroy 后由调用方释放 */
    ref_reset();

    unlink(wav_path);
    rmdir(dir_full);
    rmdir(dir_ev);
    rmdir(dir_st);
    rmdir(base);
    free(l); free(r); free(l2); free(r2);

    if (g_fail) {
        fprintf(stderr, "test_memory_mode: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_memory_mode: ALL PASS\n");
    return 0;
}

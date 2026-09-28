// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_source_switch.c — 单会话「暂存源」无缝切换（prepare_source/commit_source）回归
 *
 * 覆盖：
 *   A. 交叠丢弃公式（archoera_mediaengine_stage_drop_samples）纯函数：
 *      无交叠/负交叠/NaN → 0；按 rate/1000 四舍五入到帧再乘声道；超过暂存量
 *      则全丢；staged/ch/rate 任一非法 → 0；半帧余量边界正确。
 *   B. 引擎无设备会话（player_file=NULL，headless）真链路：
 *      同一本地 WAV 既作旧源又作新源；建会话后立即发 prepare_source +
 *      commit_source，引擎应：
 *        - 产出 source_ready 与 source_switched 事件（位置在曲中，非退化）；
 *        - 继续解码到 EOF 并正常 done（不崩溃、不挂起）；
 *        - stream.pcm 总帧数 ≈ 单次整曲解码帧数（无缺口、无整段重复；仅允许
 *          next_start 毫秒截断带来的 <1ms 交叠上界）；
 *        - 切换后若干位置窗口内容与参考整曲解码一致（接缝无错位）。
 *
 * 说明：commit 的「预解码暂存续喂同一 ring」依赖真实音频设备（流式 player）；
 * 无设备 CI 下走 headless 解码路径，因此本测试对**丢弃公式**做确定性单测，
 * 对**引擎命令/接管/续解码**做端到端断言；ring 背压顺序由流式路径保证。
 *
 * 直接编译 mediaengine_lib.c + tempo.c stub（与 test_memory_mode 同法）。
 */
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE 1 /* macOS：_XOPEN_SOURCE 700 会抑制 BSD 扩展声明 */
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

/* ── A. 丢弃公式 ─────────────────────────────────────────────── */
static void check_drop_math(void)
{
    /* 无交叠 / 负交叠 / NaN → 0 */
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 48000, 10.0, 10.0) == 0,
          "old==next → 0");
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 48000, 5.0, 10.0) == 0,
          "old<next（clamp）→ 0");
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 48000, NAN, 0.0) == 0,
          "NaN → 0");

    /* 正常交叠：drop 10ms @48k = 480 帧 × 2ch = 960 样本 */
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 48000, 10.0, 0.0) == 960,
          "10ms@48k/2ch → 960");
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 48000, 20.0, 10.0) == 960,
          "相对交叠 10ms → 960");

    /* 四舍五入：1.5ms@1000Hz → 2 帧 × 2ch = 4 */
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 1000, 1.5, 0.0) == 4,
          "1.5ms@1000Hz 四舍五入 → 4");
    /* 0.4ms@1000Hz → 0 帧 → 0 */
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 1000, 0.4, 0.0) == 0,
          "0.4ms@1000Hz → 0");

    /* 超过暂存量 → 全丢 */
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 48000, 100.0, 0.0) == 1000,
          "交叠 > 暂存 → 全丢");
    /* 正好等于暂存量 */
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 1000, 500.0, 0.0) == 1000,
          "交叠 == 暂存 → 全丢（1000）");
    /* 半帧余量：staged=1001 只需丢 1000，剩 1 样本 */
    CHECK(archoera_mediaengine_stage_drop_samples(1001, 2, 1000, 500.0, 0.0) == 1000,
          "staged=1001 交叠 1000 → 丢 1000（留 1 样本）");
    /* staged=999 交叠 1000 → 不足 → 全丢 */
    CHECK(archoera_mediaengine_stage_drop_samples(999, 2, 1000, 500.0, 0.0) == 999,
          "staged=999 不足 → 全丢");

    /* 参数非法 */
    CHECK(archoera_mediaengine_stage_drop_samples(0, 2, 48000, 100.0, 0.0) == 0,
          "staged==0 → 0");
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 0, 48000, 100.0, 0.0) == 0,
          "ch<=0 → 0");
    CHECK(archoera_mediaengine_stage_drop_samples(1000, 2, 0, 100.0, 0.0) == 0,
          "rate<=0 → 0");
    CHECK(archoera_mediaengine_stage_drop_samples(1000, -1, 48000, 100.0, 0.0) == 0,
          "ch<0 → 0");
}

/* ── B. 引擎端到端（headless，无设备）────────────────────────── */

/* 生成确定性立体声 PCM16 WAV（指定采样率），返回采样率 */
static int write_sine_wav(const char *path, double seconds, int sr)
{
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

/* 块列表（参考捕获 / stream.pcm 解析共用；pos_ms + 帧数 + 声道 + 交织数据） */
typedef struct {
    int32_t pos_ms;
    int32_t frames;
    int32_t ch;
    int64_t start;
    float  *data;
} Block;

typedef struct {
    Block *b;
    int    n;
    int    cap;
} BlockList;

static void bl_free(BlockList *L)
{
    for (int i = 0; i < L->n; i++) free(L->b[i].data);
    free(L->b);
    L->b = NULL;
    L->n = L->cap = 0;
}

static int bl_append(BlockList *L, const float *pcm, int frames, int ch,
                     double pos_ms)
{
    Block *b;
    if (frames <= 0 || ch <= 0 || !pcm) return 0;
    if (L->n == L->cap) {
        int ncap = L->cap ? L->cap * 2 : 128;
        Block *nb = (Block *)realloc(L->b, (size_t)ncap * sizeof(*nb));
        if (!nb) return -1;
        L->b = nb;
        L->cap = ncap;
    }
    b = &L->b[L->n];
    b->data = (float *)malloc((size_t)frames * (size_t)ch * sizeof(float));
    if (!b->data) return -1;
    memcpy(b->data, pcm, (size_t)frames * (size_t)ch * sizeof(float));
    b->frames = frames;
    b->ch = ch;
    b->pos_ms = (int32_t)pos_ms;
    b->start = (L->n > 0) ? L->b[L->n - 1].start + L->b[L->n - 1].frames : 0;
    L->n++;
    return 0;
}

static void ref_capture(const float *pcm, int samples, int channels,
                        double pos_ms, void *user)
{
    bl_append((BlockList *)user, pcm, samples, channels, pos_ms);
}

static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

/* 参考解码：同一引擎配置（engine_mode 决定 FFmpeg / 自研内核），从 start_ms 起
   整曲连续解码到内存块列表（窗口真值）。两种引擎解码输出可能不同，必须用同一
   引擎的参考对照。 */
static int build_ref(const char *wav, int64_t start_ms, BlockList *out,
                     int engine_mode)
{
    EngineConfig c = ENGINE_CONFIG_DEFAULT;
    AudioPipeline *p;
    c.skip_encoder = true;
    c.start_offset_ms = start_ms;
    c.engine_mode = engine_mode;
    p = pipeline_create(wav, &c, dummy_output, NULL);
    if (!p) return -1;
    pipeline_set_pcm_out_cb(p, ref_capture, out);
    while (pipeline_process(p) > 0) { }
    pipeline_run(p);
    pipeline_destroy(p);
    return 0;
}

/* 解析引擎 stream.pcm：块 = [int32 pos_ms, int32 frames, int32 ch] + 交织 float。
   返回 0 成功；-1 读取/格式错误。 */
static int parse_stream_pcm(const char *path, BlockList *L)
{
    FILE *f = fopen(path, "rb");
    int32_t hdr[3];
    if (!f) return -1;
    for (;;) {
        size_t got = fread(hdr, sizeof(hdr), 1, f);
        if (got != 1) break; /* 正常 EOF */
        if (hdr[1] < 0 || hdr[2] <= 0 || hdr[2] > 64) { fclose(f); return -1; }
        {
            size_t nfl = (size_t)hdr[1] * (size_t)hdr[2];
            float *tmp = (float *)malloc(nfl * sizeof(float));
            if (!tmp) { fclose(f); return -1; }
            if (fread(tmp, sizeof(float), nfl, f) != nfl) {
                free(tmp); fclose(f); return -1;
            }
            if (bl_append(L, tmp, hdr[1], hdr[2], (double)hdr[0]) != 0) {
                free(tmp); fclose(f); return -1;
            }
            free(tmp);
        }
    }
    fclose(f);
    return 0;
}

static int64_t bl_total_frames(const BlockList *L)
{
    int64_t t = 0;
    for (int i = 0; i < L->n; i++) t += L->b[i].frames;
    return t;
}

/* 以 end_pos_ms 为终点取最近 frames 样本（L/R）——与引擎 mem_window 同语义：
   定位最后一个 pos_ms <= end 的块，块内取偏移，跨块回放，头部越界前缀补零。 */
static int bl_window(const BlockList *L, int sr, int end_pos_ms, int frames,
                     float *out_l, float *out_r)
{
    int bi = -1, i;
    int64_t start_sample, end_sample;
    int fill, si;
    if (L->n <= 0) return -1;
    for (i = L->n - 1; i >= 0; i--) {
        if (L->b[i].pos_ms <= end_pos_ms) { bi = i; break; }
    }
    if (bi < 0) return -1;
    {
        int64_t off_ms = (int64_t)end_pos_ms - L->b[bi].pos_ms;
        int in_block;
        if (off_ms < 0) off_ms = 0;
        in_block = (int)((off_ms * (int64_t)sr + 500) / 1000);
        if (in_block >= L->b[bi].frames) in_block = L->b[bi].frames - 1;
        end_sample = L->b[bi].start + in_block;
        start_sample = end_sample - (int64_t)frames + 1;
        if (start_sample < 0 && L->b[0].start != 0) return -1;
        memset(out_l, 0, (size_t)frames * sizeof(float));
        memset(out_r, 0, (size_t)frames * sizeof(float));
        fill = 0;
        si = (int)start_sample;
        if (si < 0) { fill = -si; si = 0; }
        while (fill < frames) {
            int b2 = -1;
            for (i = 0; i < L->n; i++) {
                if (L->b[i].start <= si &&
                    si < L->b[i].start + L->b[i].frames) { b2 = i; break; }
            }
            if (b2 < 0) break;
            {
                Block *bb = &L->b[b2];
                int64_t bStart = si - bb->start;
                int avail = (int)(bb->frames - bStart);
                int take = frames - fill;
                int c;
                if (take > avail) take = avail;
                for (c = 0; c < take; c++) {
                    const float *d = bb->data + (size_t)(bStart + c) * bb->ch;
                    out_l[fill + c] = d[0];
                    out_r[fill + c] = (bb->ch >= 2) ? d[1] : d[0];
                }
                fill += take;
                si += take;
            }
        }
        if (fill <= 0) return -1;
    }
    return 0;
}

/* 等引擎线程退出（is_done）。返回 1 已退出，0 超时。 */
static int wait_done(ArchoeraMediaEngine *e, int budget_ms)
{
    int waited = 0;
    while (!archoera_mediaengine_is_done(e) && waited < budget_ms) {
        struct timespec ts = {0, 5 * 1000000L};
        nanosleep(&ts, NULL);
        waited += 5;
    }
    return archoera_mediaengine_is_done(e) ? 1 : 0;
}

static void run_engine_switch(const char *wav, const char *sdir, int sr,
                              const BlockList *ref, int engine_mode)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    ArchoeraMediaEngine *e;
    BlockList eng;
    BlockList kref;
    const BlockList *base_ref = ref;
    char errbuf[256];
    char pcm_path[640];
    char ev[4096];
    int saw_ready = 0, saw_source_ready = 0, saw_switched = 0, saw_error = 0;
    double switched_ms = -1.0;
    int64_t ref_total, eng_total;
    int done;

    memset(&eng, 0, sizeof(eng));
    memset(&kref, 0, sizeof(kref));
    cfg.skip_encoder = true; /* 纯 PCM 直出，无 Opus 编码 */
    cfg.engine_mode = engine_mode; /* 0=FFmpeg / 1=EraAudio 自研内核：两条路径都应精确 */

    /* EraAudio 模式：两种引擎解码输出不同，必须用同一引擎（内核）的参考对照。 */
    if (engine_mode != 0) {
        if (build_ref(wav, 0, &kref, engine_mode) == 0 && kref.n > 0) {
            base_ref = &kref;
        } else {
            CHECK(0, "D EraAudio 参考解码（内核）");
        }
    }

    e = archoera_mediaengine_create(wav, &cfg, NULL, sdir, errbuf, sizeof(errbuf));
    CHECK(e != NULL, "B 引擎会话可创建（player_file=NULL，headless）");
    if (!e) return;

    /* 建会话后立即提交两条命令（与首块解码同批消费：切换位置≈曲首之后一点点，
       确定性、无 sleep 竞态）。 */
    {
        char cmd[1024];
        snprintf(cmd, sizeof(cmd),
                 "{\"type\":\"prepare_source\",\"url\":\"%s\"}", wav);
        archoera_mediaengine_command(e, cmd);
    }
    archoera_mediaengine_command(e, "{\"type\":\"commit_source\"}");

    done = wait_done(e, 30000);
    CHECK(done == 1, "B 引擎在预算内正常结束（未挂起）");

    /* 事件：ready / source_ready / source_switched 齐全，无 error */
    while (archoera_mediaengine_poll_event(e, ev, sizeof(ev)) > 0) {
        if (strstr(ev, "\"type\":\"ready\"")) saw_ready = 1;
        if (strstr(ev, "\"type\":\"source_ready\"")) saw_source_ready = 1;
        if (strstr(ev, "\"type\":\"source_switched\"")) {
            saw_switched = 1;
            {
                const char *p = strstr(ev, "\"position_ms\":");
                if (p) switched_ms = atof(p + 14);
            }
        }
        if (strstr(ev, "\"type\":\"error\"") ||
            strstr(ev, "\"type\":\"source_error\"")) saw_error = 1;
    }
    CHECK(saw_ready, "B 收到 ready 事件");
    CHECK(saw_source_ready, "B 收到 source_ready 事件");
    CHECK(saw_switched, "B 收到 source_switched 事件");
    CHECK(!saw_error, "B 无 error/source_error 事件");

    snprintf(pcm_path, sizeof(pcm_path), "%s/stream.pcm", sdir);
    ref_total = bl_total_frames(base_ref);
    CHECK(ref_total > 0, "B 参考整曲解码产出 PCM");
    CHECK(parse_stream_pcm(pcm_path, &eng) == 0 && eng.n > 0,
          "B stream.pcm 可解析且非空");
    eng_total = bl_total_frames(&eng);

    /* 切换发生在曲中（非退化：旧源未整曲解完就提交） */
    CHECK(switched_ms > 0.0 && switched_ms < (double)ref_total * 1000.0 / sr - 200.0,
          "B 切换位置在曲中（非退化）");

    /* 无缺口、无整段重复：总帧数应落在 [ref, ref + <1ms 交叠上界]。
       next_start 截断到 ms 带来的交叠 ≤ rate/1000 帧，留少量余量。 */
    {
        int64_t hi = ref_total + (int64_t)(sr / 1000) + 64;
        CHECK(eng_total >= ref_total, "B 总帧数 ≥ 整曲（无缺口）");
        CHECK(eng_total <= hi, "B 总帧数 ≤ 整曲 + <1ms 交叠（无重复）");
        fprintf(stderr, "        ref_total=%lld eng_total=%lld switched=%.0fms\n",
                (long long)ref_total, (long long)eng_total, switched_ms);
    }

    /* 接缝前后窗口内容：旧源区对照「从 0 起」参考；新源区对照「从切换起点
       (start_offset=floor(base_ms)) 起」参考——验证新源从正确绝对位置续解码。
       （同批提交未跑预解码，故新源起点为整理后的 ms；与流式路径的 stage-drop
       不是同一路径，交叠由上面的总帧数上界约束。） */
    {
        static const int frames = 1024;
        BlockList ref2;
        float *l = (float *)calloc((size_t)frames, sizeof(float));
        float *r = (float *)calloc((size_t)frames, sizeof(float));
        float *l2 = (float *)calloc((size_t)frames, sizeof(float));
        float *r2 = (float *)calloc((size_t)frames, sizeof(float));
        int total_ms = (int)(ref_total * 1000 / sr);
        int start_ms = (switched_ms > 0.0) ? (int)switched_ms : 0;
        int probes[4];
        const BlockList *cmp[4];
        int ok = 1, i;

        memset(&ref2, 0, sizeof(ref2));
        if (build_ref(wav, start_ms, &ref2, engine_mode) != 0 || ref2.n <= 0) {
            CHECK(0, "B 新源区参考解码");
        } else {
            probes[0] = 100;
            probes[1] = start_ms - 250;
            probes[2] = start_ms + 250;
            probes[3] = total_ms - 200;
            cmp[0] = base_ref; cmp[1] = base_ref; cmp[2] = &ref2; cmp[3] = &ref2;
            for (i = 0; i < 4 && ok; i++) {
                double md = 0.0;
                int k;
                if (probes[i] < 0) probes[i] = 0;
                if (bl_window(&eng, sr, probes[i], frames, l, r) != 0 ||
                    bl_window(cmp[i], sr, probes[i], frames, l2, r2) != 0) {
                    ok = 0;
                    fprintf(stderr, "        probe[%d]=%dms 窗口缺失\n",
                            i, probes[i]);
                    break;
                }
                for (k = 0; k < frames; k++) {
                    double dl = fabs((double)l[k] - (double)l2[k]);
                    double dr = fabs((double)r[k] - (double)r2[k]);
                    if (dl > md) md = dl;
                    if (dr > md) md = dr;
                }
                if (md > 1e-3) { ok = 0; fprintf(stderr,
                    "        probe %dms diff=%.6f\n", probes[i], md); }
            }
            CHECK(ok, "B 接缝前后窗口与对应参考一致（≤1e-3）");
        }
        bl_free(&ref2);
        free(l); free(r); free(l2); free(r2);
    }

    bl_free(&eng);
    bl_free(&kref);
    archoera_mediaengine_destroy(e);
}

/* C. 跨采样率切档：暂存输出格式必须锁定为「活动管线实际输出」。
   否则 passthrough（output_sample_rate=0，各管线跟随各自源采样率）下，新旧源
   采样率不同（如转码 MP3 44.1k ↔ 无损 48k）时，新源 PCM 会以不同速率喂入未
   重建的 player → 变调/变速（默认 passthrough 下必现）。 */
static void run_rate_lock(const char *old_wav, const char *new_wav,
                          const char *sdir, int old_sr)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    ArchoeraMediaEngine *e;
    char errbuf[256];
    char ev[4096];
    int saw_ready = 0, saw_source_ready = 0, rate = -1, ch = -1;

    cfg.skip_encoder = true;
    e = archoera_mediaengine_create(old_wav, &cfg, NULL, sdir, errbuf, sizeof(errbuf));
    CHECK(e != NULL, "C 引擎会话可创建（跨采样率）");
    if (!e) return;
    {
        char cmd[1024];
        snprintf(cmd, sizeof(cmd),
                 "{\"type\":\"prepare_source\",\"url\":\"%s\"}", new_wav);
        archoera_mediaengine_command(e, cmd);
    }
    /* 同批 commit：与 B 用例同法（预取线程可能在旧源解完前就被抢占，commit
       回执同样携带暂存输出格式，保证本断言确定性）。 */
    archoera_mediaengine_command(e, "{\"type\":\"commit_source\"}");
    CHECK(wait_done(e, 30000) == 1, "C 跨采样率会话在预算内结束（未挂起）");
    while (archoera_mediaengine_poll_event(e, ev, sizeof(ev)) > 0) {
        if (strstr(ev, "\"type\":\"ready\"")) saw_ready = 1;
        if (strstr(ev, "\"type\":\"source_ready\"")) {
            saw_source_ready = 1;
            {
                const char *p = strstr(ev, "\"out_sample_rate\":");
                if (p) rate = atoi(p + 18);
                p = strstr(ev, "\"channels\":");
                if (p) ch = atoi(p + 11);
            }
        }
    }
    CHECK(saw_ready, "C 收到 ready 事件");
    CHECK(saw_source_ready, "C 收到 source_ready 事件");
    CHECK(rate == old_sr,
          "C 暂存输出采样率锁定为活动管线采样率（跨采样率切档不变速）");
    CHECK(ch == 2, "C 暂存输出声道锁定为活动管线声道");
    fprintf(stderr, "        old_sr=%d staged_rate=%d staged_ch=%d\n",
            old_sr, rate, ch);
    archoera_mediaengine_destroy(e);
}

int main(void)
{
    char base[] = "/tmp/archoera-srcswitch-test-XXXXXX";
    char wav_path[512], sdir[512];
    char wav2_path[512], sdir2[512];
    char sdir3[512];
    BlockList ref;
    int sr;

    memset(&ref, 0, sizeof(ref));

    /* A. 丢弃公式（不依赖 I/O） */
    check_drop_math();

    if (!mkdtemp(base)) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(wav_path, sizeof(wav_path), "%s/src.wav", base);
    snprintf(sdir, sizeof(sdir), "%s/session", base);
    if (mkdir(sdir, 0700) != 0) {
        perror("mkdir");
        rmdir(base);
        return 2;
    }

    /* 12s 确定性源：足够长，保证旧源在首块之后仍远未 EOF（切换非退化）。 */
    sr = write_sine_wav(wav_path, 12.0, 44100);
    CHECK(sr == 44100, "生成确定性 44.1k 立体声测试源");
    if (sr != 44100) return 2;

    /* 参考：同一配置整曲连续解码（窗口真值 + 总帧数） */
    CHECK(build_ref(wav_path, 0, &ref, 0) == 0, "参考 pipeline_create");
    CHECK(ref.n > 0, "参考整曲解码产出 PCM 块");

    run_engine_switch(wav_path, sdir, sr, &ref, 0);

    /* D. 同一流程但走自研内核（engine_mode=1）：验证「暂存源沿用会话引擎」时
       并发解码 + 样本级切档仍精确（不强制 FFmpeg）。 */
    snprintf(sdir3, sizeof(sdir3), "%s/session3", base);
    if (mkdir(sdir3, 0700) == 0) {
        run_engine_switch(wav_path, sdir3, sr, &ref, 1);
    } else {
        perror("mkdir session3");
        g_fail = 1;
    }

    /* C. 跨采样率切档：旧 44.1k 源 + 新 48k 源 → 暂存输出必须锁定 44.1k。 */
    snprintf(wav2_path, sizeof(wav2_path), "%s/src48.wav", base);
    snprintf(sdir2, sizeof(sdir2), "%s/session2", base);
    if (mkdir(sdir2, 0700) == 0 &&
        write_sine_wav(wav2_path, 12.0, 48000) == 48000) {
        run_rate_lock(wav_path, wav2_path, sdir2, 44100);
    } else {
        perror("rate-lock 夹具");
        g_fail = 1;
    }

    bl_free(&ref);
    unlink(wav_path);
    unlink(wav2_path);
    /* 引擎会写 stream.pcm，先删再删目录 */
    {
        char p[640];
        snprintf(p, sizeof(p), "%s/stream.pcm", sdir);
        unlink(p);
        snprintf(p, sizeof(p), "%s/stream.pcm", sdir2);
        unlink(p);
        snprintf(p, sizeof(p), "%s/stream.pcm", sdir3);
        unlink(p);
    }
    rmdir(sdir);
    rmdir(sdir2);
    rmdir(sdir3);
    rmdir(base);

    if (g_fail) {
        fprintf(stderr, "test_source_switch: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_source_switch: ALL PASS\n");
    return 0;
}

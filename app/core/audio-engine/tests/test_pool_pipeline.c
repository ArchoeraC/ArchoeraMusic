// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_pool_pipeline.c — S1 常驻内核池（zk_engine 流式 seam）接线回归（headless）
 *
 * 目标：证明 mediaengine_lib 引擎线程的 ARCHOERA_ERA_POOL gating 路径真的跑起来，
 * 且池（zk_engine_open/read）解码结果与默认 zk_decoder 路径样本级一致：
 *   - 同一 fixture（native_seek_fixture.flac，FLAC 44100/2ch）用 headless 内存
 *     模式引擎（与 test_memory_mode 同法：编译 mediaengine_lib.c + tempo.c stub，
 *     ARCHOERA_MEMORY_HEADLESS=1、engine_mode=1、无设备）跑两遍：
 *       A：ARCHOERA_ERA_POOL=1（池路径）；
 *       B：不设该 env（默认 zk_decoder 路径，作为参照）。
 *   - 两遍都完整解码（无 error 事件、有 done），产出的整曲 PCM 窗口样本级一致
 *     （memcmp 逐位相等——含尾部：整曲回放帧数一致即「sample count 相等」）；
 *   - 通过 native_decoder_stream_opens() 计数断言：A 的确走了池 open（>=1），
 *     B 未新增池 open（计数不变）——gated 路径确实执行而非静默回退。
 * 结束打印 ALL PASS（ctest PASS_REGULAR_EXPRESSION）。
 */
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE 1 /* macOS：_XOPEN_SOURCE 700 会抑制 BSD 扩展（mkdtemp 等）声明 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

#include "audio_engine.h"
#include "archoera_mediaengine.h"
#include "native_decoder.h"

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

/* ── headless 内存模式引擎会话（同 test_memory_mode：无设备、全速解码入内存块）
 *    前提：调用方已设好 ARCHOERA_MEMORY_HEADLESS / ARCHOERA_ERA_POOL */
static ArchoeraMediaEngine *run_session(const char *src, const char *sdir,
                                        char *errbuf, int errcap)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    ArchoeraMediaEngine *e;
    char wav[512];
    int waited = 0;
    snprintf(wav, sizeof(wav), "%s/stream.wav", sdir);
    cfg.engine_mode = 1;          /* EraAudio：原生内核路径 */
    cfg.no_disk_cache = 1;        /* 内存播放模式（不落盘） */
    cfg.pcm_mem_cap_kb = -1;      /* 无上限：整曲可回访 */
    e = archoera_mediaengine_create(src, &cfg, wav, sdir, errbuf, errcap);
    if (!e) {
        fprintf(stderr, "create failed: %s\n", errbuf ? errbuf : "(null)");
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

/* 排空事件：返回 1 含 done、0 无 done；遇 error 置 *had_err。 */
static int drain_events(ArchoeraMediaEngine *e, int *had_err)
{
    char line[2048];
    int got_done = 0;
    while (archoera_mediaengine_poll_event(e, line, sizeof(line))) {
        if (strstr(line, "\"type\":\"done\"")) got_done = 1;
        if (strstr(line, "\"type\":\"error\"")) *had_err = 1;
    }
    return got_done;
}

/* pcm_window 命中判定 + A/B 窗口逐位比较；返回 0 相等且命中 */
static int probe_eq(ArchoeraMediaEngine *a, ArchoeraMediaEngine *b,
                    int end_ms, int frames,
                    float *la, float *ra, float *lb, float *rb)
{
    if (archoera_mediaengine_pcm_window(a, end_ms, frames, la, ra) != 0) return -1;
    if (archoera_mediaengine_pcm_window(b, end_ms, frames, lb, rb) != 0) return -2;
    if (memcmp(la, lb, (size_t)frames * sizeof(float)) != 0) return 1;
    if (memcmp(ra, rb, (size_t)frames * sizeof(float)) != 0) return 2;
    return 0;
}

/* 窗口内有非静音内容（L/R 之一任一 |x|>1e-4） */
static int window_nonzero(const float *l, const float *r, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        if (fabs((double)l[i]) > 1e-4 || fabs((double)r[i]) > 1e-4) return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const int WIN_FULL = 40000;   /* > 0.6s×44100 ≈ 26460 整曲，含头部前缀补零 */
    const char *path = (argc > 1) ? argv[1] : NULL;
    char base[] = "/tmp/archoera-pool-test-XXXXXX";
    char dirA[512], dirB[512];
    char errbuf[256];
    ArchoeraMediaEngine *eA = NULL, *eB = NULL;
    float *lA, *rA, *lB, *rB;
    long long opens_before, opens_after_a, opens_after_b;
    int had_err, ok;
    int got_done;

    if (!path) {
        fprintf(stderr, "usage: %s <audio>\n", argv[0]);
        return 2;
    }
    if (!mkdtemp(base)) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(dirA, sizeof(dirA), "%s/A", base);
    snprintf(dirB, sizeof(dirB), "%s/B", base);
    mkdir(dirA, 0700);
    mkdir(dirB, 0700);

    lA = (float *)malloc((size_t)WIN_FULL * sizeof(float));
    rA = (float *)malloc((size_t)WIN_FULL * sizeof(float));
    lB = (float *)malloc((size_t)WIN_FULL * sizeof(float));
    rB = (float *)malloc((size_t)WIN_FULL * sizeof(float));
    if (!lA || !rA || !lB || !rB) { fprintf(stderr, "oom\n"); return 2; }

    setenv("ARCHOERA_MEMORY_HEADLESS", "1", 1);
    opens_before = native_decoder_stream_opens();

    /* ── A：ARCHOERA_ERA_POOL=1（池路径）── */
    setenv("ARCHOERA_ERA_POOL", "1", 1);
    eA = run_session(path, dirA, errbuf, sizeof(errbuf));
    CHECK(eA != NULL, "A（池开启）会话可创建");
    if (eA) {
        had_err = 0;
        got_done = drain_events(eA, &had_err);
        CHECK(got_done, "A 会话完整解码（含 done 事件）");
        CHECK(!had_err, "A 会话无 error 事件");
        opens_after_a = native_decoder_stream_opens();
        CHECK(opens_after_a > opens_before,
              "A 走 stream seam：native_decoder_stream_opens 增加（池 gated 路径实际执行）");
        CHECK(native_decoder_pool_active() == 0,
              "A 会话收尾已 native_decoder_pool_end（池已停）");
    } else {
        opens_after_a = native_decoder_stream_opens();
        CHECK(opens_after_a > opens_before,
              "A 会话创建失败但池 open 已发生（gating 在 create 线程内）");
    }

    /* ── B：ARCHOERA_ERA_POOL=0（显式关池，参照 engine_mode=1 默认 zk_decoder）── */
    setenv("ARCHOERA_ERA_POOL", "0", 1);
    eB = run_session(path, dirB, errbuf, sizeof(errbuf));
    CHECK(eB != NULL, "B（池关闭）会话可创建");
    if (eB) {
        had_err = 0;
        got_done = drain_events(eB, &had_err);
        CHECK(got_done, "B 会话完整解码（含 done 事件）");
        CHECK(!had_err, "B 会话无 error 事件");
        opens_after_b = native_decoder_stream_opens();
        CHECK(opens_after_b == opens_after_a,
              "B 未走 stream seam（env 关闭：opens 计数不变 → 默认路径原样）");
        CHECK(native_decoder_pool_active() == 0, "B 会话无池（pool_active==0）");
    }

    /* ── A/B 产出的整曲 PCM 逐位对照 ── */
    if (eA && eB) {
        /* 整曲窗口：end 远超曲尾 → 截到末块末尾，frames 含头部前缀补零的完整回放 */
        ok = (probe_eq(eA, eB, 100000, WIN_FULL, lA, rA, lB, rB) == 0);
        CHECK(ok, "整曲 PCM A==B（memcmp 逐位一致 → sample count 一致）");
        CHECK(window_nonzero(lA, rA, WIN_FULL),
              "A 整曲窗口有非静音内容（确实解码出音频）");

        /* 多点窗口（中/尾）对照。头部最小可用 end≈首块 pos_ms（~46ms：首块来自
         * 2048 帧原生 chunk）；end 更小无块命中属预期，头部样本已由上面的整曲
         * 窗口（自 sample 0 起）覆盖。 */
        {
            const int W = 4096;
            static const int ends[] = { 60, 150, 300, 450, 560, 580, 595 };
            unsigned int i;
            int all = 1;
            for (i = 0; i < sizeof(ends) / sizeof(ends[0]); i++) {
                int r = probe_eq(eA, eB, ends[i], W, lA, rA, lB, rB);
                if (r != 0) {
                    fprintf(stderr, "      窗口 end=%dms 不一致/未命中 (rc=%d)\n",
                            ends[i], r);
                    all = 0;
                }
            }
            CHECK(all, "多点 PCM 窗口 A==B（60~595ms 覆盖，头部由整曲窗口覆盖）");
        }
    } else {
        CHECK(0, "A 与 B 会话均须可创建以完成对照");
    }

    /* ── FFmpeg 回退对齐：argv[2] = Zig 未接管格式（如 ALAC .m4a）──
     *    池开启下 native open 失败（Zig 不接管该容器）→ 引擎须照常回退 FFmpeg 解码成功
     *    （无 error、有 done），
     *    且该会话不产生 native stream open（未走 zk_engine seam）。 */
    if (argc > 2) {
        ArchoeraMediaEngine *eC = NULL;
        const char *fb_path = argv[2];
        char dirC[512];
        snprintf(dirC, sizeof(dirC), "%s/C", base);
        mkdir(dirC, 0700);
        setenv("ARCHOERA_ERA_POOL", "1", 1);
        opens_before = native_decoder_stream_opens();
        eC = run_session(fb_path, dirC, errbuf, sizeof(errbuf));
        CHECK(eC != NULL, "C（pool on，Zig 未接管）会话可创建");
        if (eC) {
            had_err = 0;
            got_done = drain_events(eC, &had_err);
            CHECK(got_done, "C 完整解码（含 done）＝ FFmpeg 回退生效");
            CHECK(!had_err, "C 无 error 事件");
            CHECK(native_decoder_stream_opens() == opens_before,
                  "C 未走 native stream（Zig 未接管 → 回退 FFmpeg，非池解码）");
            archoera_mediaengine_destroy(eC);
        }
        unlink(dirC);
        rmdir(dirC);
        printf("FFmpeg fallback under pool OK\n");
    }

    if (eA) archoera_mediaengine_destroy(eA);
    if (eB) archoera_mediaengine_destroy(eB);

    unlink(dirA);
    unlink(dirB);
    rmdir(dirA);
    rmdir(dirB);
    rmdir(base);
    free(lA); free(rA); free(lB); free(rB);

    if (g_fail) {
        fprintf(stderr, "test_pool_pipeline: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_pool_pipeline: ALL PASS\n");
    return 0;
}

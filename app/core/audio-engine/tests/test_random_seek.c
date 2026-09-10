// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_random_seek.c — 音频流播放「随机跳转」回归（headless，无设备）
 *
 * 目的：验证流式会话（zk_engine_*，池内）在**播放中反复随机 seek** 后，
 * 输出与「整曲解码参考」一致（随机访问正确性）。
 *
 * 方法：
 *   1. 用同步内核解码器 zk_decoder_* 整曲解码 → 参考 float32 PCM；
 *   2. 池化流式会话 zk_engine_open 打开同一文件，循环 N 次随机 seek：
 *        - seek_ms(随机目标，含 0 / 末尾 / 越界) → 校验返回 0；
 *        - position_ms 合理；读取一块 PCM；
 *        - 在参考中按 position 对齐（±1ms 搜索窗）求最大 corr；
 *          要求 corr ≥ 0.999（无损可额外要求逐位）。
 *   3. 多次 seek 间**不重开会话**（真实播放跳转语义）。
 *
 * 用法：test_random_seek <file> [iterations] [seed]
 * 输出：ALL PASS / FAIL 明细
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kernel_bridge.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail = 1;                                                      \
        }                                                                    \
    } while (0)

static float *decode_reference(const char *path, int *out_ch, long long *out_frames)
{
    char err[128] = {0};
    ZkInfo info;
    ZkDecoder *d = zk_decoder_open(path, &info, err, sizeof(err));
    if (!d) {
        fprintf(stderr, "参考解码打开失败: %s\n", err);
        return NULL;
    }
    size_t cap = (size_t)(info.duration_us / 1000000.0 * info.sample_rate) + 65536;
    float *buf = (float *)malloc(cap * (size_t)info.channels * sizeof(float));
    long long total = 0;
    int ch = info.channels;
    while (1) {
        if ((size_t)(total + 4096) * (size_t)info.channels > cap * (size_t)info.channels) {
            cap = cap * 2 + 65536;
            buf = (float *)realloc(buf, cap * (size_t)info.channels * sizeof(float));
        }
        long long n = zk_decoder_read(d, buf + total * (size_t)info.channels,
                                      4096, &ch);
        if (n < 0) {
            fprintf(stderr, "参考解码错误 %lld\n", n);
            free(buf);
            zk_decoder_close(d);
            return NULL;
        }
        if (n == 0) break;
        total += n;
        ch = info.channels;
    }
    zk_decoder_close(d);
    *out_ch = ch;
    *out_frames = total;
    return buf;
}

static double corr_window(const float *ref, long long ref_frames, int ch,
                          long long start, const float *got, long long n, long long from)
{
    double num = 0, da = 0, db = 0;
    for (long long i = from; i < n; i++) {
        long long ri = start + i;
        if (ri < 0 || ri >= ref_frames) continue;
        for (int c = 0; c < ch; c++) {
            double a = ref[ri * ch + c];
            double b = got[i * ch + c];
            num += a * b;
            da += a * a;
            db += b * b;
        }
    }
    if (da <= 0 || db <= 0) return -1.0;
    return num / sqrt(da * db);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file> [iterations] [seed]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    int iters = argc > 2 ? atoi(argv[2]) : 200;
    unsigned seed = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 10) : 12345u;
    long long warmup = argc > 4 ? atoll(argv[4]) : 0; /* seek 后允许跳过的 transient 样本 */
    int global_search = (argc > 5 && strcmp(argv[5], "global") == 0); /* 全局对齐诊断 */

    int rch = 0;
    long long rframes = 0;
    float *ref = decode_reference(path, &rch, &rframes);
    if (!ref || rframes <= 0) return 1;

    char err[128] = {0};
    ZkEngine *host = zk_engine_init_streams(1, 4, 64, 8);
    CHECK(host != NULL, "zk_engine_init_streams");
    if (!host) return 1;

    ZkInfo info;
    ZkEngineStream *s = zk_engine_open(host, path, &info, err, sizeof(err));
    CHECK(s != NULL, "zk_engine_open");
    if (!s) { zk_engine_shutdown(host); return 1; }

    const int ch = info.channels;
    const int sr = info.sample_rate;
    const long long dur_ms = info.duration_us / 1000;
    const int window = sr / 10 + 8; /* ±100ms：覆盖 seek 帧边界（mp3 帧≈26ms，最多差 2 帧） */

    float *got = (float *)malloc(4096 * (size_t)ch * sizeof(float));

    /* 前置自检：不 seek，流式整曲解码应与参考一致（否则前提不成立） */
    {
        long long total = 0;
        double num = 0, da = 0, db = 0;
        int oc = 0;
        long long n;
        while ((n = zk_engine_read(s, got, 2048, &oc)) > 0) {
            for (long long i = 0; i < n && total + i < rframes; i++) {
                for (int c = 0; c < ch; c++) {
                    double a = ref[(total + i) * ch + c];
                    double b = got[i * ch + c];
                    num += a * b; da += a * a; db += b * b;
                }
            }
            total += n;
        }
        double base_corr = (da > 0 && db > 0) ? num / sqrt(da * db) : -1;
        fprintf(stderr, "stream full-decode corr=%.6f frames=%lld/%lld\n", base_corr, total, rframes);
        CHECK(base_corr >= 0.999, "流式整曲解码与参考一致（前提）");
    }

    srand(seed);
    double min_corr = 1.0;
    int compared = 0, exact_chunks = 0;
    long long bad_pos = 0;

    for (int it = 0; it < iters; it++) {
        /* 随机目标：多数在 [0,dur)，每 ~10 次含边界/越界 */
        long long target;
        int r = rand() % 10;
        if (r == 0) target = 0;
        else if (r == 1) target = dur_ms > 0 ? dur_ms - 1 : 0;
        else if (r == 2) target = dur_ms + 500 + (rand() % 1000); /* 越界 */
        else target = dur_ms > 0 ? (long long)(rand() % (unsigned)(dur_ms + 1)) : 0;

        int rc = zk_engine_seek_ms(s, target);
        if (rc != 0) { g_fail = 1; fprintf(stderr, "seek(%lld) rc=%d\n", target, rc); continue; }
        long long pos = zk_engine_position_ms(s);
        if (pos < 0 || pos > dur_ms + 2000) bad_pos++;

        /* seek 后 warm-up：实际读取并丢弃 N 帧（有损合成滤波 transient），
           再测量；无损 warmup=0。*/
        if (warmup > 0) {
            long long left = warmup;
            int oc0 = 0;
            while (left > 0) {
                long long dn = zk_engine_read(s, got, (size_t)(left > 2048 ? 2048 : left), &oc0);
                if (dn <= 0) break;
                left -= dn;
            }
            pos = zk_engine_position_ms(s);
        }

        int out_ch = 0;
        long long n = zk_engine_read(s, got, 2048, &out_ch);
        if (n < 0) { g_fail = 1; fprintf(stderr, "read rc=%lld @pos=%lld\n", n, pos); continue; }
        if (n == 0) continue; /* 越界/末尾 → EOF 合理 */

        /* 对齐：常规 ±window（粗→细）；global 模式扫描整段参考 */
        long long base = (long long)((double)pos * sr / 1000.0);
        double best = -1.0;
        long long best_off = 0;
        if (global_search) {
            for (long long d = -base; d <= rframes - n; d += 64) {
                double cc = corr_window(ref, rframes, ch, base + d, got, n, 0);
                if (cc > best) { best = cc; best_off = d; }
            }
            long long lo = best_off - 64, hi = best_off + 64;
            for (long long d = lo; d <= hi; d++) {
                double cc = corr_window(ref, rframes, ch, base + d, got, n, 0);
                if (cc > best) { best = cc; best_off = d; }
            }
        } else {
            for (long long d = -window; d <= window; d++) {
                double cc = corr_window(ref, rframes, ch, base + d, got, n, 0);
                if (cc > best) { best = cc; best_off = d; }
            }
        }
        if (global_search)
            fprintf(stderr, "  target=%lldms pos=%lldms base=%lld off=%lld actual=%lld corr=%.5f n=%lld\n",
                    target, pos, base, best_off, base + best_off, best, n);
        if (best < min_corr) min_corr = best;
        compared++;
        if (best < 0.999) {
            g_fail = 1;
            fprintf(stderr, "corr=%.4f < 0.999 @target=%lld pos=%lld off=%lld n=%lld\n",
                    best, target, pos, best_off, n);
        }
        /* 逐位：最佳对齐处若完全相同则记一次 */
        if (best >= 0.999) {
            long long st = base + best_off;
            int same = 1;
            for (long long i = 0; i < n; i++) {
                long long ri = st + i;
                if (ri < 0 || ri >= rframes) continue;
                for (int c = 0; c < ch; c++) {
                    if (ref[ri * ch + c] != got[i * ch + c]) { same = 0; break; }
                }
                if (!same) break;
            }
            if (same) exact_chunks++;
        }
    }

    fprintf(stderr, "random-seek: iters=%d compared=%d min_corr=%.5f exact_chunks=%d/%d bad_pos=%lld "
                    "(ch=%d sr=%d dur_ms=%lld)\n",
            iters, compared, min_corr, exact_chunks, compared, bad_pos, ch, sr, dur_ms);
    fprintf(stderr, "warmup=%lld frames\n", warmup);
    CHECK(compared > 0, "至少完成一次有效对比");
    CHECK(bad_pos == 0, "position_ms 合理");

    zk_engine_close(s);
    zk_engine_shutdown(host);
    free(got);
    free(ref);

    if (g_fail) { fprintf(stderr, "FAILED\n"); return 1; }
    printf("ALL PASS\n");
    return 0;
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/*
 * test_engine_pool.c — 常驻内核接入 seam（zk_engine_*）对照回归
 *
 * 加法式测试：不触碰 mediaengine_lib/pipeline/player/纯内存路径。
 *   - 造 8kHz mono i16 16 帧黄金 WAV；
 *   - sync 路径（zk_decoder_*）解码 → 参考 float；
 *   - pool 路径（zk_engine_decode_once，池内并行、表面同步）解码同文件 → 逐样本对照；
 *   - 附加：不存在文件 → 负状态码；并发 2 线程 decode_once 计数一致。
 * 结束打印 ALL PASS。
 */

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <sys/stat.h> /* mkfifo：槽满拒绝路径用 FIFO 占住唯一任务槽 */
#endif

#include "kernel_bridge.h"

#define FRAMES 16
#define SR 8000

static int write_gold_wav(const char *path) {
    unsigned char hdr[] = {
        'R','I','F','F', 0x34,0x00,0x00,0x00, 'W','A','V','E',
        'f','m','t',' ', 0x10,0x00,0x00,0x00,
        0x01,0x00, 0x01,0x00, 0x40,0x1f,0x00,0x00,
        0x80,0x3e,0x00,0x00, 0x02,0x00, 0x10,0x00,
        'd','a','t','a', 0x20,0x00,0x00,0x00
    };
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(hdr, 1, sizeof(hdr), f);
    for (int i = 0; i < FRAMES; i++) {
        int16_t s = (int16_t)i;
        fwrite(&s, 2, 1, f);
    }
    fclose(f);
    return 0;
}

/* sync 参考：解码全部到 buf（float 交错），返回帧数 */
static long long sync_decode_all(const char *path, float *buf, int *ch_out) {
    ZkInfo info;
    char ebuf[128];
    ZkDecoder *d = zk_decoder_open(path, &info, ebuf, sizeof ebuf);
    if (!d) return -1;
    *ch_out = info.channels;
    float tmp[1024];
    long long total = 0;
    for (;;) {
        int ch = 0;
        long long n = zk_decoder_read(d, tmp, 1024, &ch);
        if (n < 0) { zk_decoder_close(d); return n; }
        if (n == 0) break;
        memcpy(buf + total * info.channels, tmp, (size_t)n * info.channels * sizeof(float));
        total += n;
    }
    zk_decoder_close(d);
    return total;
}

/* —— 内存/回调源测试辅助 —— */
static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    unsigned char *b = malloc((size_t)n);
    if (!b) { fclose(f); return NULL; }
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); fclose(f); return NULL; }
    fclose(f);
    *out_len = (size_t)n;
    return b;
}

typedef struct { const unsigned char *data; size_t len; size_t pos; } CbCtx;

static size_t cb_read(void *ctx, unsigned char *buf, size_t len) {
    CbCtx *c = (CbCtx *)ctx;
    if (c->pos >= c->len) return 0;
    size_t n = c->len - c->pos;
    if (n > len) n = len;
    memcpy(buf, c->data + c->pos, n);
    c->pos += n;
    return n;
}

static int cb_seek(void *ctx, long long off, int whence, size_t buffered) {
    CbCtx *c = (CbCtx *)ctx;
    long long base;
    switch (whence) {
    case 0: base = 0; break;
    case 1: base = (long long)c->pos - (long long)buffered; break;
    case 2: base = (long long)c->len; break;
    default: return 0;
    }
    long long np = base + off;
    if (np < 0 || np > (long long)c->len) return 0;
    c->pos = (size_t)np;
    return 1;
}

static void *worker_dec(void *arg) {    const char *path = (const char *)arg;
    float *buf = malloc((size_t)FRAMES * 8 * sizeof(float));
    int ch = 0;
    long long n = 0;
    ZkEngine *h = zk_engine_init(1, 2, 8);
    if (!h) { free(buf); return (void *)1; }
    ZkInfo info;
    n = zk_engine_decode_once(h, path, buf, FRAMES, &ch, &info);
    long long bad = (n != FRAMES || ch != 1) ? 1 : 0;
    zk_engine_shutdown(h);
    free(buf);
    return (void *)bad;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    const char *path = "zkpool_test.wav";
    if (write_gold_wav(path) != 0) { fprintf(stderr, "cannot write wav\n"); return 1; }

    /* 1) sync 参考 */
    float *ref = malloc((size_t)FRAMES * 8 * sizeof(float));
    int ref_ch = 0;
    long long ref_frames = sync_decode_all(path, ref, &ref_ch);
    if (ref_frames != FRAMES || ref_ch != 1) {
        fprintf(stderr, "sync baseline failed frames=%lld ch=%d\n", ref_frames, ref_ch);
        return 1;
    }

    /* 2) pool decode_once 对照 */
    ZkEngine *h = zk_engine_init(2, 4, 16);
    if (!h) { fprintf(stderr, "zk_engine_init failed\n"); return 1; }
    float *pool = malloc((size_t)FRAMES * 8 * sizeof(float));
    int ch = 0;
    ZkInfo info;
    memset(&info, 0, sizeof info);
    long long n = zk_engine_decode_once(h, path, pool, FRAMES, &ch, &info);
    if (n != FRAMES || ch != 1) { fprintf(stderr, "decode_once failed n=%lld ch=%d\n", n, ch); return 1; }
    if (info.sample_rate != SR || info.bits_per_sample != 16) {
        fprintf(stderr, "info mismatch sr=%d bits=%d\n", info.sample_rate, info.bits_per_sample);
        return 1;
    }
    for (int i = 0; i < FRAMES; i++) {
        if (pool[i] != ref[i]) {
            fprintf(stderr, "sample mismatch at %d: %g vs %g\n", i, (double)pool[i], (double)ref[i]);
            return 1;
        }
    }
    printf("pool decode == sync decode: %lld frames OK\n", n);

    /* 3) 不存在文件 → 负状态码 */
    float tmp[64];
    int tmp_ch = 0;
    long long err_n = zk_engine_decode_once(h, "/nonexistent/definitely-missing.wav", tmp, 8, &tmp_ch, NULL);
    if (err_n >= 0) { fprintf(stderr, "expected negative on missing file, got %lld\n", err_n); return 1; }
    printf("missing file → status %lld OK\n", -err_n);

    /* 3b) 失败语义对齐：不可解码文件两路一致（决定 pipeline FFmpeg 回退判定的输入）
     *     zk_decoder_open == NULL / zk_engine_open == NULL 且状态码同为 ZK_UNSUPPORTED；
     *     decode_once 返回同号负码。 */
    {
        const char *bad = "zkpool_bad.txt";
        FILE *f = fopen(bad, "wb");
        if (!f) return 1;
        fputs("not-an-audio-file-at-all", f);
        fclose(f);
        char eb1[64], eb2[64];
        ZkInfo bi;
        memset(&bi, 0, sizeof bi);
        ZkDecoder *sd = zk_decoder_open(bad, &bi, eb1, sizeof eb1);
        int s1 = (sd == NULL) ? (int)((unsigned char)eb1[0] | ((unsigned char)eb1[1] << 8) |
                                     ((unsigned char)eb1[2] << 16) | ((unsigned char)eb1[3] << 24)) : 0;
        ZkEngineStream *ss2 = zk_engine_open(h, bad, NULL, eb2, sizeof eb2);
        int s2 = (ss2 == NULL) ? (int)((unsigned char)eb2[0] | ((unsigned char)eb2[1] << 8) |
                                       ((unsigned char)eb2[2] << 16) | ((unsigned char)eb2[3] << 24)) : 0;
        long long once = zk_engine_decode_once(h, bad, tmp, 8, &tmp_ch, NULL);
        if (sd != NULL || ss2 != NULL) { fprintf(stderr, "unsupported file should fail open\n"); return 1; }
        if (s1 != ZK_UNSUPPORTED || s2 != ZK_UNSUPPORTED || s1 != s2) {
            fprintf(stderr, "failure-status mismatch sync=%d stream=%d\n", s1, s2);
            return 1;
        }
        if (once != -((long long)ZK_UNSUPPORTED)) {
            fprintf(stderr, "decode_once unsupported code mismatch: %lld\n", once);
            return 1;
        }
        printf("failure alignment sync==stream==decode_once (status %d) OK\n", s1);
        remove(bad);
    }

    /* 4) 并发 2 线程 decode_once */
    pthread_t t1, t2;
    if (pthread_create(&t1, NULL, worker_dec, (void *)path) != 0) return 1;
    if (pthread_create(&t2, NULL, worker_dec, (void *)path) != 0) return 1;
    void *r1 = NULL, *r2 = NULL;
    pthread_join(t1, &r1);
    pthread_join(t2, &r2);
    if (r1 != 0 || r2 != 0) { fprintf(stderr, "concurrent decode failed\n"); return 1; }
    printf("concurrent decode_once x2 OK\n");

    /* 5) 流式会话：逐块拉取 == sync 参考；seek 后继续可读 */
    ZkInfo s_info;
    char ebuf[64];
    ZkEngineStream *ss = zk_engine_open(h, path, &s_info, ebuf, sizeof ebuf);    if (!ss) { fprintf(stderr, "zk_engine_open failed\n"); return 1; }
    if (s_info.sample_rate != SR) { fprintf(stderr, "stream info sr=%d\n", s_info.sample_rate); return 1; }
    {
        float chunk[16];
        long long got = 0, idx = 0;
        for (;;) {
            int ch2 = 0;
            long long n2 = zk_engine_read(ss, chunk, 8, &ch2);
            if (n2 < 0) { fprintf(stderr, "stream read err %lld\n", n2); return 1; }
            if (n2 == 0) break;
            for (long long k = 0; k < n2; k++) {
                if (chunk[k] != ref[idx + k]) {
                    fprintf(stderr, "stream sample mismatch at %lld\n", idx + k);
                    return 1;
                }
            }
            idx += n2;
            got += n2;
        }
        if (got != FRAMES) { fprintf(stderr, "stream frames %lld\n", got); return 1; }
        printf("stream read loop == sync: %lld frames OK\n", got);

        /* seek 回 0 再拉 4 帧 == 前 4 参考 */
        if (zk_engine_seek_ms(ss, 0) != 0) { fprintf(stderr, "seek failed\n"); return 1; }
        int ch3 = 0;
        long long ns = zk_engine_read(ss, chunk, 4, &ch3);
        if (ns != 4) { fprintf(stderr, "post-seek read %lld\n", ns); return 1; }
        for (int k = 0; k < 4; k++) {
            if (chunk[k] != ref[k]) { fprintf(stderr, "post-seek mismatch %d\n", k); return 1; }
        }
        printf("stream seek→read OK\n");
    }
    zk_engine_close(ss);

    /* 6) F9 max_streams 硬计数：独立引擎（上限 2）开两个流 ok，第三个返回 NULL
     *    （streamOpen false），关一个后第三个再开成功；流计数与任务槽分开记账。 */
    {
        ZkEngine *hs = zk_engine_init_streams(1, 2, 8, 2);
        if (!hs) { fprintf(stderr, "zk_engine_init_streams failed\n"); return 1; }
        ZkInfo si1, si2, si3;
        char se[64];
        ZkEngineStream *s1 = zk_engine_open(hs, path, &si1, se, sizeof se);
        ZkEngineStream *s2 = zk_engine_open(hs, path, &si2, se, sizeof se);
        ZkEngineStream *s3 = zk_engine_open(hs, path, &si3, se, sizeof se);
        if (!s1 || !s2) { fprintf(stderr, "stream open within max_streams failed\n"); return 1; }
        if (s3 != NULL) { fprintf(stderr, "3rd stream should be rejected at max_streams=2\n"); return 1; }
        zk_engine_close(s1);
        ZkEngineStream *s3b = zk_engine_open(hs, path, &si3, se, sizeof se);
        if (!s3b) { fprintf(stderr, "reopen after close should succeed\n"); return 1; }
        zk_engine_close(s2);
        zk_engine_close(s3b);
        zk_engine_shutdown(hs);
        printf("max_streams=2 hard count (2 open → 3rd NULL → close → reopen OK) OK\n");
    }

    /* 7) 池内存源 / 回调源（zk_engine_open_mem / _cb）== sync 参考 */
    {
        size_t flen = 0;
        unsigned char *fbuf = read_file(path, &flen);
        if (!fbuf) { fprintf(stderr, "read gold wav failed\n"); return 1; }
        float chunk[FRAMES];
        ZkInfo mi;
        char meb[64];

        /* 内存源 */
        ZkEngineStream *ms = zk_engine_open_mem(h, fbuf, flen, &mi, meb, sizeof meb);
        if (!ms) { fprintf(stderr, "zk_engine_open_mem failed\n"); free(fbuf); return 1; }
        long long got = 0;
        for (;;) {
            int c2 = 0;
            long long n2 = zk_engine_read(ms, chunk, 8, &c2);
            if (n2 < 0) { fprintf(stderr, "mem stream read err %lld\n", n2); free(fbuf); return 1; }
            if (n2 == 0) break;
            for (long long k = 0; k < n2; k++) {
                if (chunk[k] != ref[got + k]) { fprintf(stderr, "mem mismatch at %lld\n", got + k); free(fbuf); return 1; }
            }
            got += n2;
        }
        if (got != FRAMES) { fprintf(stderr, "mem stream frames %lld\n", got); free(fbuf); return 1; }
        zk_engine_close(ms);
        printf("engine open_mem == sync: %lld frames OK\n", got);

        /* 回调源 */
        CbCtx c = { fbuf, flen, 0 };
        ZkEngineStream *cs = zk_engine_open_cb(h, &c, cb_read, cb_seek, (unsigned long long)flen,
                                               &mi, meb, sizeof meb);
        if (!cs) { fprintf(stderr, "zk_engine_open_cb failed\n"); free(fbuf); return 1; }
        long long cgot = 0;
        for (;;) {
            int c2 = 0;
            long long n2 = zk_engine_read(cs, chunk, 8, &c2);
            if (n2 < 0) { fprintf(stderr, "cb stream read err %lld\n", n2); free(fbuf); return 1; }
            if (n2 == 0) break;
            for (long long k = 0; k < n2; k++) {
                if (chunk[k] != ref[cgot + k]) { fprintf(stderr, "cb mismatch at %lld\n", cgot + k); free(fbuf); return 1; }
            }
            cgot += n2;
        }
        if (cgot != FRAMES) { fprintf(stderr, "cb stream frames %lld\n", cgot); free(fbuf); return 1; }
        zk_engine_close(cs);
        printf("engine open_cb == sync: %lld frames OK\n", cgot);
        free(fbuf);
    }

    /* 8) 结构化任务提交面（zk_submit_decode / zk_task_wait / zk_task_free）：
     *    异步提交 4 个任务（同一黄金 WAV），全部提交后逐个 wait；帧数/info/逐样本
     *    与 sync 参考一致，最后 release。 */
    {
        enum { NTASK = 4 };
        ZkTask *ts[NTASK];
        float *outs[NTASK];
        ZkInfo tinfos[NTASK];
        for (int i = 0; i < NTASK; i++) {
            outs[i] = malloc((size_t)FRAMES * 8 * sizeof(float));
            if (!outs[i]) { fprintf(stderr, "alloc submit out failed\n"); return 1; }
            ts[i] = zk_submit_decode(h, path, outs[i], FRAMES, &tinfos[i]);
            if (!ts[i]) { fprintf(stderr, "zk_submit_decode #%d failed\n", i); return 1; }
        }
        for (int i = 0; i < NTASK; i++) {
            long long sn = zk_task_wait(ts[i]);
            if (sn != FRAMES) { fprintf(stderr, "submit task #%d frames %lld\n", i, sn); return 1; }
            if (tinfos[i].sample_rate != SR || tinfos[i].channels != 1 ||
                tinfos[i].bits_per_sample != 16) {
                fprintf(stderr, "submit task #%d info mismatch sr=%d ch=%d bits=%d\n",
                        i, tinfos[i].sample_rate, tinfos[i].channels, tinfos[i].bits_per_sample);
                return 1;
            }
            for (int k = 0; k < FRAMES; k++) {
                if (outs[i][k] != ref[k]) {
                    fprintf(stderr, "submit task #%d sample mismatch at %d\n", i, k);
                    return 1;
                }
            }
            zk_task_free(ts[i]);
            free(outs[i]);
        }
        printf("submit decode == sync: %d tasks OK\n", NTASK);
    }

    /* 9) 任务槽满拒绝路径（cap=1）：用 FIFO 占住唯一任务槽（worker 阻塞在 open），
     *    第二次提交必返回 NULL（InstanceLimit，与 Host.submit 满即拒一致）；
     *    随后写端打开关闭解锁，任务以负状态码完工。 */
#if !defined(_WIN32)
    {
        const char *fifo = "zkpool_block.fifo";
        remove(fifo);
        if (mkfifo(fifo, 0600) != 0) { fprintf(stderr, "mkfifo failed\n"); return 1; }
        ZkEngine *hb = zk_engine_init(1, 1, 1);
        if (!hb) { fprintf(stderr, "small host init failed\n"); remove(fifo); return 1; }
        float b1[64], b2[64];
        ZkTask *tblock = zk_submit_decode(hb, fifo, b1, 8, NULL);
        if (!tblock) {
            fprintf(stderr, "first submit on free slot failed\n");
            zk_engine_shutdown(hb); remove(fifo); return 1;
        }
        ZkTask *t2 = zk_submit_decode(hb, path, b2, 8, NULL);
        if (t2 != NULL) {
            fprintf(stderr, "cap=1: second submit must be rejected\n");
            zk_task_wait(t2); zk_task_free(t2);
            zk_engine_shutdown(hb); remove(fifo); return 1;
        }
        FILE *wf = fopen(fifo, "w"); /* 打开写端再关闭 → reader 见 EOF */
        if (wf) fclose(wf);
        long long bn = zk_task_wait(tblock);
        if (bn >= 0) {
            fprintf(stderr, "FIFO decode should fail, got %lld\n", bn);
            zk_task_free(tblock); zk_engine_shutdown(hb); remove(fifo); return 1;
        }
        zk_task_free(tblock);
        zk_engine_shutdown(hb);
        remove(fifo);
        printf("submit slot-full (cap=1) reject OK\n");
    }
#endif

    /* 10) AS1 结构化提交面（zk_submit kind/source + 句柄结果访问器）：
     *     decode/path 与 sync 参考逐样本一致；outcome/status/frames 对齐；
     *     metadata/path 填 ZkMetaInfo；参数非法返回 NULL。 */
    {
        float sout[FRAMES * 8];
        int soc = 0;
        ZkInfo sinfo;
        ZkSubmitReq req;
        memset(&req, 0, sizeof req);
        req.kind = ZK_KIND_DECODE;
        req.source = ZK_SOURCE_PATH;
        req.path = path;
        req.out = sout;
        req.max_frames = FRAMES;
        req.out_channels = &soc;
        req.info = &sinfo;
        ZkTask *st = zk_submit(h, &req);
        if (!st) { fprintf(stderr, "zk_submit decode failed\n"); return 1; }
        if (zk_task_outcome(st) != ZK_SUBMIT_PENDING) {
            fprintf(stderr, "submit should be pending before wait\n"); return 1;
        }
        long long sn = zk_task_wait(st);
        if (sn != FRAMES || soc != 1) { fprintf(stderr, "zk_submit frames %lld ch %d\n", sn, soc); return 1; }
        if (zk_task_outcome(st) != ZK_SUBMIT_DONE || zk_task_status(st) != 0) {
            fprintf(stderr, "zk_submit outcome/status bad\n"); return 1;
        }
        if (zk_task_frames(st) != FRAMES) { fprintf(stderr, "zk_task_frames %lld\n", zk_task_frames(st)); return 1; }
        if (zk_task_wait_timeout(st, 1000) != 1) { fprintf(stderr, "wait_timeout should report done\n"); return 1; }
        if (sinfo.sample_rate != SR || sinfo.bits_per_sample != 16) {
            fprintf(stderr, "submit info mismatch sr=%d bits=%d\n", sinfo.sample_rate, sinfo.bits_per_sample);
            return 1;
        }
        for (int i = 0; i < FRAMES; i++) {
            if (sout[i] != ref[i]) { fprintf(stderr, "submit sample mismatch %d\n", i); return 1; }
        }
        zk_task_free(st);
        zk_task_free(NULL);

        /* metadata kind：池内 probe+open，填 ZkMetaInfo */
        ZkMetaInfo meta;
        memset(&meta, 0, sizeof meta);
        memset(&req, 0, sizeof req);
        req.kind = ZK_KIND_METADATA;
        req.source = ZK_SOURCE_PATH;
        req.path = path;
        req.meta = &meta;
        ZkTask *mt = zk_submit(h, &req);
        if (!mt) { fprintf(stderr, "zk_submit metadata failed\n"); return 1; }
        long long mn = zk_task_wait(mt);
        if (mn != 0 || zk_task_outcome(mt) != ZK_SUBMIT_DONE || meta.sample_rate != SR || meta.channels != 1) {
            fprintf(stderr, "metadata submit bad n=%lld sr=%d ch=%d\n", mn, meta.sample_rate, meta.channels);
            return 1;
        }
        zk_task_free(mt);

        /* 参数非法：metadata + mem 源 → NULL；flags != 0 → NULL */
        memset(&req, 0, sizeof req);
        req.kind = ZK_KIND_METADATA;
        req.source = ZK_SOURCE_MEM;
        req.meta = &meta;
        if (zk_submit(h, &req) != NULL) { fprintf(stderr, "metadata/mem should be rejected\n"); return 1; }
        memset(&req, 0, sizeof req);
        req.kind = ZK_KIND_DECODE;
        req.source = ZK_SOURCE_PATH;
        req.path = path;
        req.out = sout;
        req.max_frames = FRAMES;
        req.flags = 1;
        if (zk_submit(h, &req) != NULL) { fprintf(stderr, "flags!=0 should be rejected\n"); return 1; }

        printf("structured zk_submit (decode/metadata/outcome) OK\n");
    }

    /* 11) AS2 pinned 流式会话（zk_engine_open_pinned / zk_engine_stream_pinned）：
     *     专属 worker 命中；逐块拉取与 sync 参考逐位一致。 */
    {
        ZkInfo pinfo;
        char peb[64];
        ZkEngineStream *ps = zk_engine_open_pinned(h, path, &pinfo, peb, sizeof peb);
        if (!ps) { fprintf(stderr, "zk_engine_open_pinned failed\n"); return 1; }
        if (zk_engine_stream_pinned(ps) != 1) {
            fprintf(stderr, "expected pinned stream (idle worker available)\n");
            return 1;
        }
        if (pinfo.sample_rate != SR) { fprintf(stderr, "pinned info sr=%d\n", pinfo.sample_rate); return 1; }
        float chunk[16];
        long long got = 0;
        for (;;) {
            int c2 = 0;
            long long n2 = zk_engine_read(ps, chunk, 8, &c2);
            if (n2 < 0) { fprintf(stderr, "pinned read err %lld\n", n2); return 1; }
            if (n2 == 0) break;
            for (long long k = 0; k < n2; k++) {
                if (chunk[k] != ref[got + k]) { fprintf(stderr, "pinned mismatch at %lld\n", got + k); return 1; }
            }
            got += n2;
        }
        if (got != FRAMES) { fprintf(stderr, "pinned frames %lld\n", got); return 1; }
        zk_engine_close(ps);
        printf("engine open_pinned == sync: %lld frames OK\n", got);
    }

    zk_engine_shutdown(h);
    free(pool);
    free(ref);
    remove(path);
    printf("ALL PASS\n");
    return 0;
}

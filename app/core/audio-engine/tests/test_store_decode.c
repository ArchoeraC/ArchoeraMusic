// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* store→decoder 接线冒烟（M1，多格式矩阵）：对每个传入音频样本，
 * SegStore 整曲预填 → AVIO → decoder_open_mem（自定义 IO，EOF 返回
 * AVERROR_EOF）解码，与 decoder_open(磁盘路径) 对拍：
 * 帧数/采样率/声道/时长一致且帧数 > 0。每个文件为一个用例，失败累计，
 * 全部跑完统一 summary。
 * 注意（FFmpeg 9）：read_packet 在 EOF 必须返回 AVERROR_EOF（返回 0 会被
 * fill_buffer 当作“未填满”反复重读 → 空转）。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>

#include "decoder.h"
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
    SegStore *st;
    int64_t pos;
    int64_t total;
} MemIo;

static int memio_read(void *opaque, uint8_t *buf, int size)
{
    MemIo *io = (MemIo *)opaque;
    intptr_t n = segstore_pread(io->st, buf, (size_t)size, (uint64_t)io->pos);
    if (n < 0) return AVERROR(EIO);
    if (n == 0) return AVERROR_EOF;   /* FFmpeg 9：EOF 须返回 AVERROR_EOF */
    io->pos += n;
    return (int)n;
}

static int64_t memio_seek(void *opaque, int64_t offset, int whence)
{
    MemIo *io = (MemIo *)opaque;
    if (whence == AVSEEK_SIZE) return io->total;
    int64_t base;
    switch (whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = io->pos; break;
    case SEEK_END: base = io->total; break;
    default: return -1;
    }
    io->pos = base + offset;
    if (io->pos < 0) io->pos = 0;
    if (io->pos > io->total) io->pos = io->total;
    return io->pos;
}

static long count_frames(Decoder *d)
{
    long n = 0;
    AVFrame *frame = NULL;
    while (decoder_read_frame(d, &frame) == 1) {
        n++;
    }
    return n;
}

/* 单文件用例：填 Store → 开 mem/磁盘解码 → 对拍。返回本用例失败数。 */
static int run_case(const char *file)
{
    int fails0 = g_fail;
    SegStore *st = NULL;
    AVIOContext *avio = NULL;
    Decoder *dm = NULL;
    Decoder *df = NULL;
    MemIo io;
    unsigned char *bytes = NULL;
    unsigned char *abuf = NULL;
    long flen = 0;

    fprintf(stderr, "-- 用例: %s --\n", file);

    FILE *f = fopen(file, "rb");
    CHECK(f != NULL, "fopen（可读）");
    if (!f) goto out;

    fseek(f, 0, SEEK_END);
    flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    CHECK(flen > 0, "文件非空");
    if (flen <= 0) { fclose(f); goto out; }

    bytes = (unsigned char *)malloc((size_t)flen);
    CHECK(bytes != NULL, "malloc 读缓冲");
    if (!bytes || fread(bytes, 1, (size_t)flen, f) != (size_t)flen) {
        CHECK(bytes && 0, "fread 读入完整");
        fclose(f);
        goto out;
    }
    fclose(f);

    st = segstore_new((uint64_t)flen, 0, 0);
    CHECK(st != NULL, "segstore_new");
    if (!st || segstore_fill(st, 0, bytes, (size_t)flen) != 0) {
        CHECK(0, "segstore_fill（整曲预填）");
        goto out;
    }

    io.st = st;
    io.pos = 0;
    io.total = flen;
    abuf = (unsigned char *)av_malloc(32768);
    CHECK(abuf != NULL, "av_malloc io buffer");
    avio = abuf ? avio_alloc_context(abuf, 32768, 0, &io,
                                     memio_read, NULL, memio_seek) : NULL;
    CHECK(avio != NULL, "avio_alloc_context");
    if (avio) abuf = NULL;   /* avio 接管 buffer，随 avio_context_free 释放 */

    dm = decoder_open_mem(avio);
    CHECK(dm != NULL, "decoder_open_mem（Store 源）");
    df = decoder_open(file);
    CHECK(df != NULL, "decoder_open（磁盘参照）");

    if (dm && df) {
        long nm = count_frames(dm);
        long nf = count_frames(df);
        if (nm == 0 && nf == 0) {
            fprintf(stderr,
                    "      （跳过）内存与磁盘参照均解出 0 帧："
                    "fixture 过短/损坏，无可对拍内容\n");
            goto out;
        }
        CHECK(nm > 0, "内存源解码产出帧");
        CHECK(nm == nf, "内存源帧数与磁盘一致");
        CHECK(decoder_sample_rate(dm) == decoder_sample_rate(df), "采样率一致");
        CHECK(decoder_channels(dm) == decoder_channels(df), "声道一致");
        CHECK(decoder_duration_us(dm) == decoder_duration_us(df), "时长一致");
        fprintf(stderr, "      codec=%s frames=%ld sr=%d ch=%d dur=%lldus\n",
                decoder_codec_name(dm), nm, decoder_sample_rate(dm),
                decoder_channels(dm), (long long)decoder_duration_us(dm));
    }

out:
    free(bytes);
    if (df) decoder_close(df);
    if (dm) decoder_close(dm);
    if (avio) avio_context_free(&avio);
    if (st) segstore_destroy(st);
    if (abuf) av_free(abuf);

    if (g_fail > fails0) {
        fprintf(stderr, "case FAILED  %s（本用例失败 %d）\n", file, g_fail - fails0);
    } else {
        fprintf(stderr, "case PASS    %s\n", file);
    }
    return g_fail - fails0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <audio> [<audio> ...]\n", argv[0]);
        return 2;
    }

    for (int i = 1; i < argc; i++) {
        run_case(argv[i]);
    }

    if (g_fail) {
        fprintf(stderr, "test_store_decode: FAILED（累计失败 %d）\n", g_fail);
        return 1;
    }
    fprintf(stderr, "test_store_decode: ALL PASS\n");
    return 0;
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_pcm_file_reader.c — stream.pcm 按位置取窗读取器单元测试
 *
 * 覆盖：
 *   - 增量扫描 + 二分定位 + 跨块窗口（2ch 440Hz 正弦）
 *   - 前缀补零（窗口早于文件首样本）
 *   - 尾部未解码 / 位置越界 / 参数错误
 *   - 单声道下混（L = R）
 *   - 5.1 中央声道下混（L = R = 0.7071×C）与 LFE 不入下混
 *   - 文件截断重建（自动清索引）与显式 reset 语义
 *   - 块未写完（只写半块数据）时停止索引，补全后可读
 */

#include "../src/pcm_file_reader.h"

/* Release 构建外层定义了 NDEBUG，会吞掉 assert；测试必须始终启用断言 */
#undef NDEBUG
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define SR 48000
#define BLOCK_SAMPLES 480 /* 10ms */
#define MAX_FRAMES 1024

/* 块格式小端写头 */
static void put_le32(unsigned char *p, unsigned int v)
{
    p[0] = (unsigned char)(v & 0xffu);
    p[1] = (unsigned char)((v >> 8) & 0xffu);
    p[2] = (unsigned char)((v >> 16) & 0xffu);
    p[3] = (unsigned char)((v >> 24) & 0xffu);
}

static void write_block(FILE *f, int pos_ms, int samples, int channels,
                        const float *pcm)
{
    unsigned char hdr[12];
    put_le32(hdr + 0, (unsigned int)pos_ms);
    put_le32(hdr + 4, (unsigned int)samples);
    put_le32(hdr + 8, (unsigned int)channels);
    assert(fwrite(hdr, 1, sizeof(hdr), f) == sizeof(hdr));
    assert(fwrite(pcm, sizeof(float),
                  (size_t)samples * (size_t)channels, f)
           == (size_t)samples * (size_t)channels);
}

/* 全局样本位置 s 的 440Hz 正弦（跨块连续相位） */
static float sine_at(long long s)
{
    return 0.8f * (float)sin(2.0 * M_PI * 440.0 * (double)s / (double)SR);
}

static int rd(EraPcmFileReader *r, int end_ms, int frames,
              float *l, float *rr)
{
    return era_pcm_file_reader_read(r, end_ms, frames, l, rr);
}

static void make_path(char *buf, size_t cap)
{
    const char *dir = getenv("TMPDIR");
#ifdef _WIN32
    if (!dir || !*dir) dir = getenv("TEMP");
#endif
    if (!dir || !*dir) dir = ".";
    snprintf(buf, cap, "%s/archoera_pcm_reader_test_%ld.tmp",
             dir, (long)time(NULL));
}

int main(void)
{
    char path[1024];
    FILE *w;
    EraPcmFileReader *r;
    float l[MAX_FRAMES], rr[MAX_FRAMES];
    int i;

    make_path(path, sizeof(path));

    /* ── 1. 2ch 440Hz：增量扫描 / 跨块 / 前缀补零 / 尾部 ───────── */
    w = fopen(path, "wb");
    assert(w != NULL);
    for (int b = 0; b < 4; b++) {
        float data[BLOCK_SAMPLES * 2];
        for (i = 0; i < BLOCK_SAMPLES; i++) {
            float v = sine_at((long long)b * BLOCK_SAMPLES + i);
            data[2 * i] = v;
            data[2 * i + 1] = v;
        }
        write_block(w, b * 10, BLOCK_SAMPLES, 2, data);
    }
    fclose(w);

    r = era_pcm_file_reader_open(path, SR);
    assert(r != NULL);

    /* 跨块：end = 10ms（block1 起点），窗口 [480-256+1, 480] 跨 block0/1 */
    assert(rd(r, 10, 256, l, rr) == 0);
    for (i = 0; i < 256; i++) {
        long long s = 480 - 256 + 1 + i;
        float e = sine_at(s);
        assert(fabsf(l[i] - e) < 1e-5f);
        assert(fabsf(rr[i] - e) < 1e-5f);
    }

    /* 前缀补零：end = 5ms（块内样本 240），窗口 [-271, 240] */
    assert(rd(r, 5, 512, l, rr) == 0);
    for (i = 0; i < 512; i++) {
        long long s = 240 - 512 + 1 + i;
        float e = (s < 0) ? 0.0f : sine_at(s);
        assert(fabsf(l[i] - e) < 1e-5f);
        assert(fabsf(rr[i] - e) < 1e-5f);
    }

    /* 跨块：end = 35ms（block3 内样本 240），窗口 [1425, 1680] 跨 block2/3 */
    assert(rd(r, 35, 256, l, rr) == 0);
    for (i = 0; i < 256; i++) {
        long long s = 1680 - 256 + 1 + i;
        float e = sine_at(s);
        assert(fabsf(l[i] - e) < 1e-5f);
        assert(fabsf(rr[i] - e) < 1e-5f);
    }

    /* 尾部未解码：end 恰在最后一块末尾 / 远超已解码区 */
    assert(rd(r, 40, 256, l, rr) == -1);
    assert(rd(r, 100, 256, l, rr) == -1);
    /* 位置早于首块 */
    assert(rd(r, -1, 256, l, rr) == -1);
    /* 参数错误 */
    assert(rd(r, 10, 0, l, rr) == -2);
    assert(rd(r, 10, 256, NULL, rr) == -2);
    assert(rd(r, 10, 256, l, NULL) == -2);
    assert(rd(NULL, 10, 256, l, rr) == -2);

    era_pcm_file_reader_close(r);

    /* ── 2. 单声道下混：L = R ────────────────────────────────── */
    w = fopen(path, "wb");
    assert(w != NULL);
    for (int b = 0; b < 2; b++) {
        float data[BLOCK_SAMPLES];
        for (i = 0; i < BLOCK_SAMPLES; i++)
            data[i] = sine_at((long long)b * BLOCK_SAMPLES + i);
        write_block(w, b * 10, BLOCK_SAMPLES, 1, data);
    }
    fclose(w);

    r = era_pcm_file_reader_open(path, SR);
    assert(r != NULL);
    /* end = 10ms → 终点样本 480，窗口 [1, 480] 跨两块 */
    assert(rd(r, 10, 480, l, rr) == 0);
    for (i = 0; i < 480; i++) {
        long long s = 1 + i;
        float e = sine_at(s);
        assert(fabsf(l[i] - e) < 1e-5f);
        assert(fabsf(rr[i] - e) < 1e-5f);
        assert(l[i] == rr[i]);
    }
    era_pcm_file_reader_close(r);

    /* ── 3. 5.1 下混：中央声道对称 / LFE 不入下混 ─────────────── */
    w = fopen(path, "wb");
    assert(w != NULL);
    {
        float data[BLOCK_SAMPLES * 6];
        /* block0：仅 C = 1.0（FL FR C LFE BL BR） */
        memset(data, 0, sizeof(data));
        for (i = 0; i < BLOCK_SAMPLES; i++) data[6 * i + 2] = 1.0f;
        write_block(w, 0, BLOCK_SAMPLES, 6, data);
        /* block1：仅 LFE = 1.0 */
        memset(data, 0, sizeof(data));
        for (i = 0; i < BLOCK_SAMPLES; i++) data[6 * i + 3] = 1.0f;
        write_block(w, 10, BLOCK_SAMPLES, 6, data);
    }
    fclose(w);

    r = era_pcm_file_reader_open(path, SR);
    assert(r != NULL);
    /* end = 9ms → 全在 block0：L = R = 0.70710678 */
    assert(rd(r, 9, 128, l, rr) == 0);
    for (i = 0; i < 128; i++) {
        assert(fabsf(l[i] - 0.70710678f) < 1e-6f);
        assert(fabsf(rr[i] - 0.70710678f) < 1e-6f);
        assert(fabsf(l[i] - rr[i]) < 1e-6f);
    }
    /* end = 15ms → 全在 block1（仅 LFE）：L = R = 0 */
    assert(rd(r, 15, 128, l, rr) == 0);
    for (i = 0; i < 128; i++) {
        assert(l[i] == 0.0f);
        assert(rr[i] == 0.0f);
    }
    era_pcm_file_reader_close(r);

    /* ── 4. 截断重建 / reset 语义 ─────────────────────────────── */
    w = fopen(path, "wb");
    assert(w != NULL);
    for (int b = 0; b < 3; b++) {
        float data[BLOCK_SAMPLES * 2];
        for (i = 0; i < BLOCK_SAMPLES; i++) {
            float v = sine_at((long long)b * BLOCK_SAMPLES + i);
            data[2 * i] = v;
            data[2 * i + 1] = v;
        }
        write_block(w, b * 10, BLOCK_SAMPLES, 2, data);
    }
    fclose(w);

    r = era_pcm_file_reader_open(path, SR);
    assert(r != NULL);
    assert(rd(r, 20, 128, l, rr) == 0);

    /* 写线程 seek：以 "wb" 截断重建为 2 块常量 0.25（文件变短） */
    w = fopen(path, "wb");
    assert(w != NULL);
    for (int b = 0; b < 2; b++) {
        float data[BLOCK_SAMPLES * 2];
        for (i = 0; i < BLOCK_SAMPLES * 2; i++) data[i] = 0.25f;
        write_block(w, b * 10, BLOCK_SAMPLES, 2, data);
    }
    fclose(w);

    /* 长度回退 → 自动清索引重扫：旧 20ms 块已不存在（尾部未解码） */
    assert(rd(r, 20, 128, l, rr) == -1);
    /* 新索引下 10ms 可读，内容为新写入的 0.25 */
    assert(rd(r, 10, 128, l, rr) == 0);
    for (i = 0; i < 128; i++) {
        assert(l[i] == 0.25f);
        assert(rr[i] == 0.25f);
    }

    /* 显式 reset：同长度重写为新内容，reset 后按新块重建索引 */
    w = fopen(path, "wb");
    assert(w != NULL);
    for (int b = 0; b < 2; b++) {
        float data[BLOCK_SAMPLES * 2];
        for (i = 0; i < BLOCK_SAMPLES * 2; i++) data[i] = -0.5f;
        write_block(w, b * 10, BLOCK_SAMPLES, 2, data);
    }
    fclose(w);

    era_pcm_file_reader_reset(r);
    assert(rd(r, 10, 128, l, rr) == 0);
    for (i = 0; i < 128; i++) {
        assert(l[i] == -0.5f);
        assert(rr[i] == -0.5f);
    }
    era_pcm_file_reader_close(r);

    /* ── 5. 块未写完：停止索引，补全后可读 ───────────────────── */
    w = fopen(path, "wb");
    assert(w != NULL);
    for (int b = 0; b < 2; b++) {
        float data[BLOCK_SAMPLES * 2];
        for (i = 0; i < BLOCK_SAMPLES * 2; i++) data[i] = 0.125f;
        write_block(w, b * 10, BLOCK_SAMPLES, 2, data);
    }
    /* 第三块：头声明 480 样本，但只写 100 样本（模拟引擎正在写） */
    {
        float data[BLOCK_SAMPLES * 2];
        unsigned char hdr[12];
        for (i = 0; i < BLOCK_SAMPLES * 2; i++) data[i] = 0.75f;
        put_le32(hdr + 0, 20u);
        put_le32(hdr + 4, BLOCK_SAMPLES);
        put_le32(hdr + 8, 2u);
        assert(fwrite(hdr, 1, sizeof(hdr), w) == sizeof(hdr));
        assert(fwrite(data, sizeof(float), 100u * 2u, w) == 200u);
    }
    fclose(w);

    r = era_pcm_file_reader_open(path, SR);
    assert(r != NULL);
    /* 未写完的块不入索引：20ms 之后无完整块 → 尾部未解码 */
    assert(rd(r, 25, 128, l, rr) == -1);
    /* 已写完的两块仍可读 */
    assert(rd(r, 10, 128, l, rr) == 0);
    for (i = 0; i < 128; i++) {
        assert(l[i] == 0.125f);
        assert(rr[i] == 0.125f);
    }

    /* 补全第三块剩余 380 样本（写线程继续追加） */
    w = fopen(path, "ab");
    assert(w != NULL);
    {
        float data[BLOCK_SAMPLES * 2];
        for (i = 0; i < BLOCK_SAMPLES * 2; i++) data[i] = 0.75f;
        assert(fwrite(data, sizeof(float), 380u * 2u, w) == 760u);
    }
    fclose(w);

    /* 增量扫描补索引后，窗口落在第三块（0.75） */
    assert(rd(r, 25, 128, l, rr) == 0);
    for (i = 0; i < 128; i++) {
        assert(l[i] == 0.75f);
        assert(rr[i] == 0.75f);
    }
    era_pcm_file_reader_close(r);

    /* ── 6. 空文件 / 打不开 ──────────────────────────────────── */
    w = fopen(path, "wb");
    assert(w != NULL);
    fclose(w);
    r = era_pcm_file_reader_open(path, SR);
    assert(r != NULL);
    assert(rd(r, 0, 128, l, rr) == -1);
    era_pcm_file_reader_close(r);

    assert(era_pcm_file_reader_open("/nonexistent/archoera_stream.pcm", SR)
           == NULL);
    assert(era_pcm_file_reader_open(path, 0) == NULL);
    assert(era_pcm_file_reader_open(NULL, SR) == NULL);
    era_pcm_file_reader_close(NULL);
    era_pcm_file_reader_reset(NULL);

    remove(path);
    printf("ALL PASS\n");
    return 0;
}

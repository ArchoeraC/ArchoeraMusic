// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * pcm_file_reader.c — stream.pcm 按位置取窗（L/R 下混）
 *
 * 实现说明见 pcm_file_reader.h。扫描 / 二分 / 跨块读取 / 下混系数与内存
 * 播放版 mem_window（mediaengine_lib.c）保持同一取窗语义：
 *   终点样本 = 定位块起点 + (end_pos_ms - pos_ms) × sample_rate / 1000（四舍五入）
 *   窗口     = [终点 - frames + 1, 终点]，前缀不足补零，尾部未解码返回 -1。
 *
 * 只存索引（pos_ms / file_offset / samples / sample_start），数据按需 fread；
 * 独立 FILE* + fseeko，与写线程（另一 FILE*）不共享文件位置。
 */

#define _DEFAULT_SOURCE /* fseeko/ftello（-std=c11 严格模式下 glibc 需显式声明） */
/* 32 位 POSIX 上 off_t 默认 32 位：强制 64 位，避免长会话 stream.pcm 偏移截断。
 * 必须在任何系统头之前定义。 */
#if !defined(_WIN32) && !defined(_FILE_OFFSET_BITS)
#define _FILE_OFFSET_BITS 64
#endif

#include "pcm_file_reader.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wchar.h>
#undef NOMINMAX
#undef min
#undef max
#endif

/* 块头字节数：pos_ms / samples / channels 各 int32 */
#define ERA_PCM_BLOCK_HEADER 12

/* 单块声道数上限（channels > 8 视为非法块头） */
#define ERA_PCM_MAX_CHANNELS 8

struct EraPcmFileReader {
    FILE *fp;               /* 独立只读句柄（不与写线程共享位置） */
    int sample_rate;        /* 输出采样率（ms → 样本换算） */

    /* ── 块索引（按扫描顺序；pos_ms 升序）──────────────────────── */
    int32_t *pos_ms;        /* 块头 pos_ms（按块头原样，当前实现为块起始时间） */
    int64_t *file_off;      /* 块头在文件中的字节偏移（含 12 字节头） */
    int32_t *block_samples; /* 每块样本数（每声道） */
    int64_t *sample_start;  /* 每块首样本的全局样本索引（跨块累积） */
    size_t count;
    size_t cap;

    int64_t file_end;       /* 已扫描到的文件偏移（增量游标） */
    int64_t sample_count;   /* 已累积样本总数（sample_start 计算用） */

    /* 下混输入暂存（按需增长；仅本次 read 内使用，不缓存全量 PCM） */
    float *scratch;
    size_t scratch_cap;     /* 可容纳的 float 个数 */
};

/* ── 平台文件封装（UTF-8 路径 + 64 位偏移）──────────────────────── */

#if defined(_WIN32)
/* Windows：Dart 传入 UTF-8 路径，MSVC CRT 按 ANSI 代码页解释会乱码，
 * 统一转 UTF-16 走 _wfopen（与 mediaengine_lib.c 的 fopen_utf8 同法）。 */
static FILE *era_fopen_utf8(const char *path, const char *mode)
{
    wchar_t *wp, *wm;
    int nw, nm;
    FILE *f;
    if (!path || !mode) return NULL;
    nw = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    nm = MultiByteToWideChar(CP_UTF8, 0, mode, -1, NULL, 0);
    if (nw <= 0 || nm <= 0) return NULL;
    wp = (wchar_t *)malloc((size_t)nw * sizeof(wchar_t));
    wm = (wchar_t *)malloc((size_t)nm * sizeof(wchar_t));
    if (!wp || !wm) {
        free(wp);
        free(wm);
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wp, nw);
    MultiByteToWideChar(CP_UTF8, 0, mode, -1, wm, nm);
    f = _wfopen(wp, wm);
    free(wp);
    free(wm);
    return f;
}

static int era_fseek64(FILE *fp, int64_t off, int whence)
{
    return _fseeki64(fp, off, whence) == 0 ? 0 : -1;
}

static int64_t era_ftell64(FILE *fp)
{
    return (int64_t)_ftelli64(fp);
}
#else
static FILE *era_fopen_utf8(const char *path, const char *mode)
{
    return fopen(path, mode);
}

static int era_fseek64(FILE *fp, int64_t off, int whence)
{
    return fseeko(fp, (off_t)off, whence) == 0 ? 0 : -1;
}

static int64_t era_ftell64(FILE *fp)
{
    return (int64_t)ftello(fp);
}
#endif

/* ── 小端解码（块格式固定小端；不依赖宿主字节序）────────────────── */

static int32_t era_le_i32(const unsigned char *p)
{
    uint32_t u = (uint32_t)p[0]
               | ((uint32_t)p[1] << 8)
               | ((uint32_t)p[2] << 16)
               | ((uint32_t)p[3] << 24);
    return (int32_t)u;
}

/* ── 索引管理 ─────────────────────────────────────────────────── */

static void era_index_clear(EraPcmFileReader *r)
{
    r->count = 0;
    r->file_end = 0;
    r->sample_count = 0;
}

/* 追加一条索引；失败返回 -1（原索引保持不变）。 */
static int era_index_append(EraPcmFileReader *r, int32_t pos_ms,
                            int64_t file_off, int32_t samples)
{
    if (r->count == r->cap) {
        size_t ncap = r->cap ? r->cap * 2 : 64;
        int32_t *np = (int32_t *)realloc(r->pos_ms, ncap * sizeof(*np));
        int64_t *nf;
        int32_t *ns;
        int64_t *nst;
        if (!np) return -1;
        r->pos_ms = np;
        nf = (int64_t *)realloc(r->file_off, ncap * sizeof(*nf));
        if (!nf) return -1;
        r->file_off = nf;
        ns = (int32_t *)realloc(r->block_samples, ncap * sizeof(*ns));
        if (!ns) return -1;
        r->block_samples = ns;
        nst = (int64_t *)realloc(r->sample_start, ncap * sizeof(*nst));
        if (!nst) return -1;
        r->sample_start = nst;
        r->cap = ncap;
    }
    r->pos_ms[r->count] = pos_ms;
    r->file_off[r->count] = file_off;
    r->block_samples[r->count] = samples;
    r->sample_start[r->count] = r->sample_count;
    r->count++;
    r->sample_count += samples;
    return 0;
}

/* 当前文件长度（字节）；失败 -1。 */
static int64_t era_file_size(FILE *fp)
{
    int64_t total;
    if (era_fseek64(fp, 0, SEEK_END) != 0) return -1;
    total = era_ftell64(fp);
    if (total < 0) return -1;
    return total;
}

/* 增量扫描：
 *   - 文件变短 → 已截断重建，清空重扫；
 *   - 块头非法 / pos_ms 回退 → 文件被重写（长度探测失效的竞态兜底），
 *     清空重扫一次，仍异常则停止；
 *   - 块数据未写完（当前长度不足）→ 停止，等下次调用补索引。
 * 返回 0 成功；-1 IO/内存错误。 */
static int era_scan(EraPcmFileReader *r)
{
    int64_t total;
    int restarted = 0;

    total = era_file_size(r->fp);
    if (total < 0) return -1;
    if (total < r->file_end) era_index_clear(r);

    while (r->file_end + ERA_PCM_BLOCK_HEADER <= total) {
        unsigned char hdr[ERA_PCM_BLOCK_HEADER];
        int32_t pos_ms, samples, channels;
        int64_t need;

        if (era_fseek64(r->fp, r->file_end, SEEK_SET) != 0) return -1;
        if (fread(hdr, 1, sizeof(hdr), r->fp) != sizeof(hdr)) return -1;

        pos_ms = era_le_i32(hdr + 0);
        samples = era_le_i32(hdr + 4);
        channels = era_le_i32(hdr + 8);

        /* 异常块头：索引非空且未重扫过 → 视为文件已重写，归零重扫一次 */
        if (samples <= 0 || channels <= 0 ||
            channels > ERA_PCM_MAX_CHANNELS) {
            if (r->count > 0 && !restarted) {
                restarted = 1;
                era_index_clear(r);
                continue;
            }
            break;
        }

        need = (int64_t)samples * (int64_t)channels * 4;
        /* 块未写完（含 need 溢出兜底）：停止，等下次扫描 */
        if (need > total - r->file_end - ERA_PCM_BLOCK_HEADER) break;

        /* 位置回退：同上，重扫一次仍回退则停止 */
        if (r->count > 0 && pos_ms < r->pos_ms[r->count - 1]) {
            if (!restarted) {
                restarted = 1;
                era_index_clear(r);
                continue;
            }
            break;
        }

        if (era_index_append(r, pos_ms, r->file_end, samples) != 0)
            return -1;
        r->file_end += ERA_PCM_BLOCK_HEADER + need;
    }
    return 0;
}

/* ── 下混（对齐 mem_downmix_sample / fft_process_multi，ITU-R BS.775）── */

static void era_downmix_sample(const float *d, int channels,
                               float *out_l, float *out_r)
{
    const float inv = 0.70710678f; /* 1/sqrt(2) */

    switch (channels) {
    case 1: /* 单声道：L = R */
        *out_l = d[0];
        *out_r = d[0];
        break;
    case 2: /* L R */
        *out_l = d[0];
        *out_r = d[1];
        break;
    case 3: /* L R C */
        *out_l = d[0] + inv * d[2];
        *out_r = d[1] + inv * d[2];
        break;
    case 4: /* FL FR BL BR */
        *out_l = d[0] + inv * d[2];
        *out_r = d[1] + inv * d[3];
        break;
    case 5: /* L R C BL BR */
        *out_l = d[0] + inv * d[2] + inv * d[3];
        *out_r = d[1] + inv * d[2] + inv * d[4];
        break;
    case 6: /* 5.1：FL FR C LFE BL BR，LFE 不入下混 */
        *out_l = d[0] + inv * d[2] + inv * d[4];
        *out_r = d[1] + inv * d[2] + inv * d[5];
        break;
    default: /* 超出已知布局：退化为前两个声道 */
        *out_l = d[0];
        *out_r = (channels >= 2) ? d[1] : d[0];
        break;
    }
}

/* 读取块 bi 的 [start, start+take) 样本并下混到 out_l/out_r。
 * 返回 0 成功；-1 读取失败/块头与索引不符（文件被并发重写）。 */
static int era_read_block_downmix(EraPcmFileReader *r, size_t bi, int start,
                                  int take, float *out_l, float *out_r)
{
    unsigned char hdr[ERA_PCM_BLOCK_HEADER];
    int32_t samples, channels;
    size_t need;
    int i;

    if (era_fseek64(r->fp, r->file_off[bi], SEEK_SET) != 0) return -1;
    if (fread(hdr, 1, sizeof(hdr), r->fp) != sizeof(hdr)) return -1;

    samples = era_le_i32(hdr + 4);
    channels = era_le_i32(hdr + 8);
    if (channels <= 0 || channels > ERA_PCM_MAX_CHANNELS) return -1;
    if (samples != r->block_samples[bi]) return -1;
    if (start < 0 || start >= samples) return -1;
    if (take <= 0) return -1;
    if ((int64_t)start + take > samples) take = samples - start;

    need = (size_t)take * (size_t)channels;
    if (need > r->scratch_cap) {
        float *nb = (float *)realloc(r->scratch, need * sizeof(float));
        if (!nb) return -1;
        r->scratch = nb;
        r->scratch_cap = need;
    }

    if (era_fseek64(r->fp, r->file_off[bi] + ERA_PCM_BLOCK_HEADER
                             + (int64_t)start * channels * 4, SEEK_SET) != 0)
        return -1;
    if (fread(r->scratch, sizeof(float), need, r->fp) != need) return -1;

    for (i = 0; i < take; i++) {
        era_downmix_sample(r->scratch + (size_t)i * (size_t)channels,
                           channels, &out_l[i], &out_r[i]);
    }
    return 0;
}

/* ── 二分定位 ─────────────────────────────────────────────────── */

/* 最后一个 pos_ms <= end_ms 的块下标；无返回 -1。 */
static int era_last_block_le(const EraPcmFileReader *r, int end_ms)
{
    size_t lo = 0, hi = r->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (r->pos_ms[mid] <= end_ms) lo = mid + 1;
        else hi = mid;
    }
    return (int)lo - 1;
}

/* 含全局样本 s 的块下标；s 越界返回 -1 / count。 */
static int era_block_of_sample(const EraPcmFileReader *r, int64_t s)
{
    size_t lo = 0, hi = r->count;
    if (s < 0 || hi == 0) return -1;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (r->sample_start[mid] <= s) lo = mid + 1;
        else hi = mid;
    }
    return (int)lo - 1;
}

/* ── 公共 API ─────────────────────────────────────────────────── */

EraPcmFileReader *era_pcm_file_reader_open(const char *path, int sample_rate)
{
    EraPcmFileReader *r;
    FILE *fp;

    if (!path || sample_rate <= 0) return NULL;
    fp = era_fopen_utf8(path, "rb");
    if (!fp) return NULL;

    r = (EraPcmFileReader *)calloc(1, sizeof(*r));
    if (!r) {
        fclose(fp);
        return NULL;
    }
    r->fp = fp;
    r->sample_rate = sample_rate;
    return r;
}

void era_pcm_file_reader_close(EraPcmFileReader *r)
{
    if (!r) return;
    if (r->fp) fclose(r->fp);
    free(r->pos_ms);
    free(r->file_off);
    free(r->block_samples);
    free(r->sample_start);
    free(r->scratch);
    free(r);
}

void era_pcm_file_reader_reset(EraPcmFileReader *r)
{
    if (!r) return;
    era_index_clear(r);
}

int era_pcm_file_reader_read(EraPcmFileReader *r, int end_pos_ms, int frames,
                             float *out_l, float *out_r)
{
    int bi, bi2;
    int64_t bs, delta, in_block, end_sample, start_sample, si;
    int fill;

    if (!r || !out_l || !out_r || frames <= 0) return -2;
    if (r->sample_rate <= 0) return -2;

    /* 1) 文件可能仍在增长：先增量补索引 */
    if (era_scan(r) != 0) return -1;
    if (r->count == 0) return -1;

    /* 2) 定位 end_pos_ms 所在块（pos_ms ≤ end_pos_ms 的最后一个） */
    bi = era_last_block_le(r, end_pos_ms);
    if (bi < 0) return -1;

    /* 3) 终点样本 = 块起点 + 块内毫秒偏移 × 采样率（四舍五入） */
    bs = r->block_samples[bi];
    delta = (int64_t)end_pos_ms - (int64_t)r->pos_ms[bi];
    if (delta < 0) delta = 0;
    in_block = (delta * (int64_t)r->sample_rate + 500) / 1000;
    if (in_block >= bs) {
        /* 越过最后一块末尾 → 尾部尚未解码（不做半截窗口） */
        if ((size_t)bi + 1 >= r->count) return -1;
        in_block = bs - 1; /* 块间空隙：用当前块最后一个样本 */
    }
    end_sample = r->sample_start[bi] + in_block;

    /* 4) 窗口 [end - frames + 1, end]；起点不足补零 */
    start_sample = end_sample - (int64_t)frames + 1;

    memset(out_l, 0, (size_t)frames * sizeof(float));
    memset(out_r, 0, (size_t)frames * sizeof(float));

    fill = 0;
    si = start_sample;
    if (si < 0) {
        fill = (int)(-si); /* 前缀补零（缓冲已清零） */
        si = 0;
    }

    /* 5) 跨块读取 + 下混 */
    bi2 = (si <= end_sample) ? era_block_of_sample(r, si) : (int)r->count;
    while (fill < frames) {
        int64_t bstart, avail;
        int take;

        if (bi2 < 0 || (size_t)bi2 >= r->count) return -1;
        bstart = si - r->sample_start[bi2];
        if (bstart < 0) {
            bi2++;
            continue;
        }
        if (bstart >= r->block_samples[bi2]) {
            bi2++;
            continue;
        }
        avail = (int64_t)r->block_samples[bi2] - bstart;
        take = (int64_t)(frames - fill) < avail
                   ? (frames - fill) : (int)avail;
        if (era_read_block_downmix(r, (size_t)bi2, (int)bstart, take,
                                   out_l + fill, out_r + fill) != 0)
            return -1;
        fill += take;
        si += take;
        bi2++;
    }

    return 0;
}

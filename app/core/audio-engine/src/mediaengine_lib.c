// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * mediaengine_lib.c — 音频引擎 FFI 库实现（Dart 桌面端直连，替代进程 IPC）
 *
 * 引擎线程复制 main.c run_interactive 的交互逻辑，数据源参数化：
 *   stdin 命令  → 命令 FIFO（archoera_mediaengine_command）
 *   control 事件 → 事件 FIFO（archoera_mediaengine_poll_event）
 *   PCM UDS 发送 → 会话目录文件直写（stream.pcm / stream.wav）
 *
 * Web/CLI（main.c）路径不受影响。本文件为独立单元，与 main.c 无静态依赖。
 */
#define _DEFAULT_SOURCE /* strdup 等 POSIX 函数（-std=c11 严格模式） */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include <pthread.h>
#include <time.h>

#include "audio_engine.h"
#include "player.h"
#include "archoera_mediaengine.h"
#include "native_decoder.h"
#include "compat/qatomic.h"

/* ── UTF-8 安全 fopen（Windows 宽字符边界）──────────────────────
   会话目录 / 临时文件路径由 Dart 以 UTF-8 传入（%TEMP% 可能含中文用户名）。
   MSVC CRT fopen 把窄路径按 ANSI 代码页解释 → 非 ASCII 乱码/失败（同
   scraper 根因），这里统一转 UTF-16 用 _wfopen 打开。 */
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wchar.h>
#undef NOMINMAX
#undef min
#undef max

static FILE *fopen_utf8(const char *path, const char *mode) {
    FILE *f;
    wchar_t *wp;
    wchar_t *wm;
    int nw;
    int nm;
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
#else
static FILE *fopen_utf8(const char *path, const char *mode) {
    return fopen(path, mode);
}
#endif

/* ── 队列容量 ────────────────────────────────────────────────── */
#define EV_CAP 512      /* 事件队列条数 */
#define EV_LINE 511     /* 事件行上限 */
#define CMD_CAP 256     /* 命令队列条数 */
#define CMD_LINE 4095   /* 命令行上限 */

/* ── 内存播放模式：PCM 块列表（与 stream.pcm 文件块同构）────────── */
typedef struct PcmMemBlock {
    int32_t pos_ms;     /* 块起始音频时间（ms，与文件块头一致） */
    int32_t frames;     /* 每声道帧数 */
    int32_t channels;   /* 交织声道数 */
    int64_t start;      /* 全局样本起点（跨块累积） */
    float  *data;       /* frames*channels 个交织 float（malloc） */
} PcmMemBlock;

typedef struct ArchoeraMediaEngine {
    char *source;
    EngineConfig cfg;
    char *player_file;
    char *session_dir;
    char *wav_file;
    char *pcm_file;

    /* store 内存源（docs/audio-memory-source.md §7/M2）：非空 → 引擎线程用
     * pipeline_create_store 从 SegStore 解码（source 置空）。所有权归调用方
     * （Dart 会话持有）；destroy 不释放 store，由调用方在 destroy 后释放。 */
    SegStore *store;

    pthread_t thread;
    int thread_created;
    /* 跨线程停止/完成标志：C11 原子（经 compat/qatomic.h，MSVC 走 volatile +
     * 屏障）。engine 线程 run 循环读 stop_requested；Dart/FFI 线程经
     * archoera_mediaengine_destroy / is_done 读写。 */
    qa_size stop_requested;
    qa_size done;           /* 引擎线程已退出 */

    /* 事件 FIFO */
    pthread_mutex_t ev_mutex;
    char ev_buf[EV_CAP][EV_LINE + 1];
    int ev_head, ev_tail, ev_count;

    /* 命令 FIFO */
    pthread_mutex_t cmd_mutex;
    pthread_cond_t cmd_cond;
    char cmd_buf[CMD_CAP][CMD_LINE + 1];
    int cmd_head, cmd_tail, cmd_count;

    /* 事件阻塞等待（wait_event / 事件驱动推送）：
       - ev_cond：事件入队（ev_enqueue）signal / destroy 时 broadcast；
       - destroyed：销毁已开始 —— wait_event 见到即返回 -1（不再取事件）；
       - waiters：当前在 wait_event 内的线程数（destroy 等其归零后再释放，
         保证正在阻塞/取事件的调用方不触碰已释放内存）；
       - ev_drain_cond：waiters 归零时唤醒 destroy 的 drain 等待。 */
    pthread_cond_t ev_cond;
    pthread_cond_t ev_drain_cond;
    int destroyed;
    int waiters;

    /* 引擎线程内部状态 */
    AudioPipeline *p;
    PlayerCtx *player;
    FILE *wav;
    FILE *pcm;

    /* 转码期间的待执行 seek：player 未启动时记录，播放器启动后应用。
       修复「转码/加载阶段拖动进度条不跳转」：seek 命令不再被静默丢弃 */
    int seek_pending;
    double pending_seek_ms;

    /* 降频协商的位置事件间隔（ms；0 = 未协商，播放器用默认 50ms）：
       player 启动前协商则记录于此，播放器启动后立即应用 */
    int pos_interval_ms;

    /* 播放输出 sink 选择（{"type":"set_sink","id":...} / env
       ARCHOERA_AUDIO_SINK）：空串 "" = 系统默认。初始由 create 解析 env，
       set_sink 覆盖；player 启动/平滑重启时读取。仅引擎线程访问，无锁。 */
    char *sink_id;
    /* set_sink "" / 显式 id 是否来自用户显式选择（日志语义；播放适配按
       “目标 sink 原生为低质即原生格式打开”，不区分来源，见 player.c） */
    int sink_user_set;
    /* 最近一次 set_volume 增益（引擎线程维护；切 sink 重启播放器时重放） */
    float last_volume;

    /* ── 流式播放（§B：边解码边出声，raw 设备 + 环形缓冲）────── */
    int player_stream_mode;   /* 当前播放器为流式（player_stream_open 成功） */
    int64_t session_offset_ms;/* 会话起始偏移（初始 cfg.start_offset；事件 rel 基准） */

    /* ── 内存播放模式（不落盘，cfg.no_disk_cache=1 且 player 会话）── */
    int     mem_mode;          /* 本会话为内存播放模式 */
    int     mem_sr;            /* 输出采样率（pcm_window 换算） */
    int     mem_epoch;         /* 会话重建计数（seek 重建 +1；Dart 凭此丢旧帧） */
    int64_t mem_cap_bytes;     /* 保留上限字节；INT64_MAX = 无上限 */
    int64_t mem_bytes;         /* 当前驻留字节（cap 判定用，净 PCM+块头） */
    PcmMemBlock *mem_blocks;   /* 块数组（下标 0 最早，队尾最新） */
    int     mem_block_cap;
    int     mem_block_count;
    /* ── 单会话「暂存源」无缝切换（staged source swap）────────────
       音质切换：旧源照常出声，新源在**独立预取线程**内预开 + 预解码进 stage；
       commit_source 丢弃交叠段后把 stage 余量续喂同一 ring（设备/会话不重建）。
       未使用 prepare/commit 时全部为 0，行为与旧版逐位一致（惰性）。 */
    AudioPipeline *p_next;      /* 暂存新源（NULL = 无） */
    int     next_ready;         /* 新源已就绪（source_ready 已发） */
    double  next_start_ms;      /* 新源解码起点（= 建源时旧源 decode cursor，绝对 ms） */
    double  stage_origin_ms;    /* stage[0] 真实媒体时间（首回调反推，消 ms 截断误差） */
    int     stage_have_origin;  /* stage_origin_ms 已捕获 */
    int     stage_rate;         /* 暂存 PCM 采样率（管线输出采样率） */
    int64_t p_start_ms;         /* 当前管线解码起点的绝对 ms（pipeline_get_position 相对它） */
    float  *stage;              /* 暂存 PCM（交织 float） */
    size_t  stage_len;          /* 已暂存 float 个数 */
    size_t  stage_cap;          /* 容量（float 个数） */
    int     stage_ch;           /* 暂存声道数 */
    int     stage_full;         /* 达容量上限，暂停预解码 */

    /* 预取线程：新源解码放到独立线程，避免与实时引擎线程争抢解码/IO 造成旧源
       喂环欠载（音量高时可闻的轻微顿挫）。stage_lock/stage_cv 同步三态：
       线程在 stage_busy=1 期间独占 p_next；commit/discard 置 stage_stop 后 join。 */
    pthread_t       stage_thread;
    int             stage_thread_on;
    int             stage_stop;      /* 请求预取线程退出 */
    int             stage_busy;      /* 预取线程正在 pipeline_process(p_next) */
    int             stage_eof;       /* 预取已到新源 EOF（无法再填） */
    int             stage_ready_sent;/* source_ready 已发（一次） */
    int64_t         stage_t0_ms;     /* 预取起点墙钟 ms（ready 阈值/超时判定） */
    int             carry_pending;   /* commit 时暂停：stage 余量待恢复后续喂 */
    pthread_mutex_t stage_lock;
    pthread_cond_t  stage_cv;

    /* 保护全部 mem_* 字段：写侧为引擎解码线程（mem_append/reset/free），
     * 读侧为 Dart/FFI 线程（pcm_window/pcm_epoch）。mem_window 持锁期间仅做
     * 纯计算与定长拷贝，不调用任何可重入引擎的回调。 */
    pthread_mutex_t mem_lock;
} ArchoeraMediaEngine;

/* ── 内存播放模式：cap / append / 保留 / 窗口（对齐 pcm_analyzer 语义）──
   规格见 docs/audio-memory-playback.md：0.8 GiB 硬上限 + 用户上限优先 + 查询
   故障回落 + append 后记账强制淘汰（绝不越过 cap）。 */

/* 可用内存（MB）。失败返回 -1（调用方回落保守下限）。 */
static long long mem_avail_mb(void)
{
#ifdef _WIN32
    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms))
        return (long long)(ms.ullAvailPhys / (1024ULL * 1024ULL));
    return -1;
#elif defined(__linux__)
    FILE *f = fopen("/proc/meminfo", "r");
    char line[256];
    long long mem_kb = -1;
    if (!f) return -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "MemAvailable:", 13) == 0) {
            mem_kb = atoll(line + 13);
            break;
        }
    }
    fclose(f);
    return (mem_kb < 0) ? -1 : (mem_kb / 1024);
#else
    return -1;
#endif
}

/* 解析内存保留上限（字节）。pcm_mem_cap_kb 语义见 audio_engine.h：
   0=auto（0.8 GiB 硬上限，查询故障回落下限）；>0=用户上限（绝不越过）；
   <0=无上限。 */
static int64_t mem_resolve_cap(ArchoeraMediaEngine *e)
{
    const int64_t floor_bytes = 32LL * 1024LL * 1024LL; /* 32 MiB 下限 */
    const int64_t hard_bytes  = 858993459LL;            /* 0.8 GiB 硬上限 */
    if (e->cfg.pcm_mem_cap_kb < 0) return INT64_MAX;            /* 无上限 */
    if (e->cfg.pcm_mem_cap_kb > 0) return e->cfg.pcm_mem_cap_kb * 1024LL; /* 用户 */
    {
        long long avail_mb = mem_avail_mb();
        long long bytes;
        if (avail_mb > 0) {
            long long cap_mb = avail_mb / 10; /* 可用内存 × 0.1 */
            bytes = cap_mb * (1024LL * 1024LL);
            if (bytes < floor_bytes) bytes = floor_bytes;
        } else {
            bytes = floor_bytes; /* 计算故障 → 保守下限，绝不放大 */
        }
        if (bytes > hard_bytes) bytes = hard_bytes; /* 硬封顶（≤0.8 GiB） */
        return bytes;
    }
}

/* append 后记账：超过 cap 即自队头逐最旧淘汰，直至 ≤ cap（音频超量也不越过）。
   调用方须持 mem_lock。 */
static void mem_enforce_cap(ArchoeraMediaEngine *e)
{
    if (e->mem_cap_bytes == INT64_MAX) return;
    while (e->mem_block_count > 0 && e->mem_bytes > e->mem_cap_bytes) {
        PcmMemBlock *h = &e->mem_blocks[0];
        int64_t sz = (int64_t)h->frames * h->channels * 4 + 16;
        free(h->data);
        memmove(&e->mem_blocks[0], &e->mem_blocks[1],
                (size_t)(e->mem_block_count - 1) * sizeof(*h));
        e->mem_block_count--;
        e->mem_bytes -= sz;
    }
}

/* 追加一块解码 PCM（内存播放模式取代 fwrite）；OOM 丢弃本块并返回 -1。
   内部持 mem_lock（Dart/FFI 线程正读 mem_window）。 */
static int mem_append(ArchoeraMediaEngine *e, const float *pcm,
                      int samples, int channels, double pos_ms)
{
    PcmMemBlock *b;
    if (samples <= 0 || channels <= 0 || !pcm) return 0;
    pthread_mutex_lock(&e->mem_lock);
    if (e->mem_block_count == e->mem_block_cap) {
        int ncap = e->mem_block_cap ? e->mem_block_cap * 2 : 64;
        PcmMemBlock *nb = (PcmMemBlock *)realloc(
            e->mem_blocks, (size_t)ncap * sizeof(*nb));
        if (!nb) { /* OOM：丢弃本块（解码继续，仅频谱可能缺块） */
            pthread_mutex_unlock(&e->mem_lock);
            return -1;
        }
        e->mem_blocks = nb;
        e->mem_block_cap = ncap;
    }
    b = &e->mem_blocks[e->mem_block_count];
    b->data = (float *)malloc((size_t)samples * (size_t)channels * sizeof(float));
    if (!b->data) {
        pthread_mutex_unlock(&e->mem_lock);
        return -1;
    }
    memcpy(b->data, pcm,
           (size_t)samples * (size_t)channels * sizeof(float));
    b->pos_ms = (int32_t)pos_ms;
    b->frames = samples;
    b->channels = channels;
    b->start = (e->mem_block_count > 0)
        ? e->mem_blocks[e->mem_block_count - 1].start
              + e->mem_blocks[e->mem_block_count - 1].frames
        : 0;
    e->mem_block_count++;
    e->mem_bytes += (int64_t)samples * channels * 4 + 16;
    mem_enforce_cap(e);
    pthread_mutex_unlock(&e->mem_lock);
    return 0;
}

/* mem_reset 的核心（调用方须持 mem_lock）：整表清空 + epoch++。 */
static void mem_reset_locked(ArchoeraMediaEngine *e)
{
    int i;
    for (i = 0; i < e->mem_block_count; i++) free(e->mem_blocks[i].data);
    e->mem_block_count = 0;
    e->mem_bytes = 0;
    e->mem_epoch++;
}

/* seek 重建：整表清空（对齐文件「截断重建 stream.pcm」）+ epoch++ */
static void mem_reset(ArchoeraMediaEngine *e)
{
    pthread_mutex_lock(&e->mem_lock);
    mem_reset_locked(e);
    pthread_mutex_unlock(&e->mem_lock);
}

/* 会话结束：释放块数组（destroy 调；epoch 不再递增无妨） */
static void mem_free(ArchoeraMediaEngine *e)
{
    pthread_mutex_lock(&e->mem_lock);
    mem_reset_locked(e);
    free(e->mem_blocks);
    e->mem_blocks = NULL;
    e->mem_block_cap = 0;
    pthread_mutex_unlock(&e->mem_lock);
}

/* 单样本下混 L/R（对齐 pcm_analyzer BS.775；1~6ch，超出退化取前两声道） */
static void mem_downmix_sample(const float *d, int si, int channels,
                               float *l, float *r)
{
    const float inv = 0.70710678f;
    switch (channels) {
    case 1:
        *l = d[si]; *r = d[si]; break;
    case 2:
        *l = d[2 * si]; *r = d[2 * si + 1]; break;
    case 3:
        *l = d[3 * si] + inv * d[3 * si + 2];
        *r = d[3 * si + 1] + inv * d[3 * si + 2];
        break;
    case 4:
        *l = d[4 * si] + inv * d[4 * si + 2];
        *r = d[4 * si + 1] + inv * d[4 * si + 3];
        break;
    case 5:
        *l = d[5 * si] + inv * d[5 * si + 2] + inv * d[5 * si + 3];
        *r = d[5 * si + 1] + inv * d[5 * si + 2] + inv * d[5 * si + 4];
        break;
    case 6:
        *l = d[6 * si] + inv * d[6 * si + 2] + inv * d[6 * si + 4];
        *r = d[6 * si + 1] + inv * d[6 * si + 2] + inv * d[6 * si + 5];
        break;
    default:
        *l = d[channels * si];
        *r = (channels >= 2) ? d[channels * si + 1] : d[channels * si];
        break;
    }
}

/* 最后一个 pos_ms <= end_ms 的块下标（块按 pos_ms 升序）；无返回 -1 */
static int mem_last_block_le(ArchoeraMediaEngine *e, int end_ms)
{
    int lo = 0, hi = e->mem_block_count;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (e->mem_blocks[mid].pos_ms <= end_ms) lo = mid + 1;
        else hi = mid;
    }
    return lo - 1;
}

/* 含全局样本 s 的块下标；越界返回 -1 / count */
static int mem_block_of_sample(ArchoeraMediaEngine *e, int64_t s)
{
    int lo = 0, hi = e->mem_block_count;
    if (s < 0 || hi == 0) return -1;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (e->mem_blocks[mid].start <= s) lo = mid + 1;
        else hi = mid;
    }
    return lo - 1;
}

/* pcm_window 实现：以 end_pos_ms 为终点取最近 frames 样本（L/R），语义对齐
   PcmAnalyzer.frameAt：终点样本 = 定位块内 (posMs 偏移×采样率) 取整；前缀不足
   补零（仅当头部仍在）；被淘汰/未解码 → -1。返回 0 命中 / -1 / -2。 */
static int mem_window(ArchoeraMediaEngine *e, int end_pos_ms, int frames,
                      float *out_l, float *out_r)
{
    int sr, bi, bi2, in_block, fill, c;
    int64_t end_sample, start_sample, head_start, si;
    PcmMemBlock *b;

    if (!e || !out_l || !out_r || frames <= 0) return -2;
    if (!e->mem_mode || e->mem_block_count <= 0) return -2;
    sr = e->mem_sr;
    if (sr <= 0) return -2;

    bi = mem_last_block_le(e, end_pos_ms);
    if (bi < 0) return -1;
    b = &e->mem_blocks[bi];

    /* 终点样本 = 块起点 + 块内 (end-pos) 毫秒 × 采样率（round） */
    {
        int64_t off_ms = (int64_t)end_pos_ms - b->pos_ms;
        if (off_ms < 0) off_ms = 0;
        in_block = (int)((off_ms * (int64_t)sr + 500) / 1000);
        if (in_block >= b->frames) in_block = b->frames - 1;
    }
    end_sample = b->start + in_block;
    start_sample = end_sample - (int64_t)frames + 1;
    head_start = e->mem_blocks[0].start;
    if (start_sample < head_start && head_start != 0) return -1; /* 被淘汰 */

    memset(out_l, 0, (size_t)frames * sizeof(float));
    memset(out_r, 0, (size_t)frames * sizeof(float));

    fill = 0;
    si = start_sample;
    if (si < 0) {
        fill = (int)(-si); /* 前缀补零（数组已清零） */
        si = 0;
    }
    bi2 = (si <= end_sample) ? mem_block_of_sample(e, si)
                             : e->mem_block_count;
    while (fill < frames && bi2 >= 0 && bi2 < e->mem_block_count) {
        PcmMemBlock *bb = &e->mem_blocks[bi2];
        int64_t bStart = si - bb->start;
        int avail, take;
        if (bStart < 0) { bi2++; continue; }
        if (bStart >= bb->frames) { bi2++; continue; }
        avail = (int)(bb->frames - bStart);
        if (avail <= 0) { bi2++; continue; }
        take = frames - fill;
        if (take > avail) take = avail;
        for (c = 0; c < take; c++) {
            float l, r;
            mem_downmix_sample(bb->data, (int)bStart + c, bb->channels, &l, &r);
            out_l[fill + c] = l;
            out_r[fill + c] = r;
        }
        fill += take;
        si += take;
        bi2++;
    }
    if (fill <= 0) return -1;
    return 0;
}

/* ── 事件/命令队列 ───────────────────────────────────────────── */

static void ev_enqueue(ArchoeraMediaEngine *e, const char *line)
{
    int wake = 0;
    pthread_mutex_lock(&e->ev_mutex);
    /* position 事件「只保留最新」合并：队列已有 position 时覆盖最后一条
       而非追加——恢复 50ms 前若理论上有积压（降频期不消费），从源头消除
       突发与 FIFO 溢出（EV_CAP 512 有界）。语义：position 绝对值，最新有义 */
    if (strncmp(line, "{\"type\":\"position\"", 18) == 0) {
        for (int i = e->ev_count - 1; i >= 0; i--) {
            int idx = (e->ev_head + i) % EV_CAP;
            if (strncmp(e->ev_buf[idx], "{\"type\":\"position\"", 18) == 0) {
                strncpy(e->ev_buf[idx], line, EV_LINE);
                e->ev_buf[idx][EV_LINE] = '\0';
                pthread_cond_signal(&e->ev_cond); /* 队列非空，正常无等待者；防御 */
                pthread_mutex_unlock(&e->ev_mutex);
                return;
            }
        }
    }
    if (e->ev_count < EV_CAP) {
        strncpy(e->ev_buf[e->ev_tail], line, EV_LINE);
        e->ev_buf[e->ev_tail][EV_LINE] = '\0';
        e->ev_tail = (e->ev_tail + 1) % EV_CAP;
        e->ev_count++;
        wake = 1;
    }
    if (wake) pthread_cond_signal(&e->ev_cond); /* 唤醒阻塞中的 wait_event */
    pthread_mutex_unlock(&e->ev_mutex);
}

static int cmd_enqueue(ArchoeraMediaEngine *e, const char *line)
{
    int r = -1;
    pthread_mutex_lock(&e->cmd_mutex);
    if (e->cmd_count < CMD_CAP) {
        strncpy(e->cmd_buf[e->cmd_tail], line, CMD_LINE);
        e->cmd_buf[e->cmd_tail][CMD_LINE] = '\0';
        e->cmd_tail = (e->cmd_tail + 1) % CMD_CAP;
        e->cmd_count++;
        r = 0;
    }
    pthread_cond_signal(&e->cmd_cond);
    pthread_mutex_unlock(&e->cmd_mutex);
    return r;
}

/* 非阻塞取一条命令（引擎线程调用）；返回 1 有命令、0 空 */
static int cmd_dequeue(ArchoeraMediaEngine *e, char *buf, int cap)
{
    int r = 0;
    pthread_mutex_lock(&e->cmd_mutex);
    if (e->cmd_count > 0) {
        strncpy(buf, e->cmd_buf[e->cmd_head], cap - 1);
        buf[cap - 1] = '\0';
        e->cmd_head = (e->cmd_head + 1) % CMD_CAP;
        e->cmd_count--;
        r = 1;
    }
    pthread_mutex_unlock(&e->cmd_mutex);
    return r;
}

/* ── 简单 JSON 解析（与 main.c 同协议；控制命令字段） ──────────── */

static const char* skip_ws(const char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    return s;
}

static const char* json_find(const char *json, const char *key)
{
    char search[128];
    int key_len = (int)strlen(key);
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *pos = strstr(json, search);
    if (!pos) return NULL;
    return skip_ws(pos + key_len + 3);
}

static int json_get_string(const char *json, const char *key, char *buf, int bufsize)
{
    const char *val = json_find(json, key);
    if (!val || *val != '"') return -1;
    val++;
    int i = 0;
    while (*val && *val != '"' && i < bufsize - 1) {
        buf[i++] = *val++;
    }
    buf[i] = '\0';
    return i;
}

static int json_get_number(const char *json, const char *key, double *out)
{
    const char *val = json_find(json, key);
    if (!val) return -1;
    char *end;
    *out = strtod(val, &end);
    return (end == val) ? -1 : 0;
}

static int json_get_bool(const char *json, const char *key, bool *out)
{
    const char *val = json_find(json, key);
    if (!val) return -1;
    if (strncmp(val, "true", 4) == 0) { *out = true; return 0; }
    if (strncmp(val, "false", 5) == 0) { *out = false; return 0; }
    return -1;
}

static int json_get_float_array(const char *json, const char *key,
                                float *out, int max_count)
{
    const char *val = json_find(json, key);
    if (!val || *val != '[') return 0;
    val++;
    int count = 0;
    while (*val && *val != ']' && count < max_count) {
        val = skip_ws(val);
        if (*val == ']' || *val == '\0') break;
        char *end;
        out[count++] = strtof(val, &end);
        val = skip_ws(end);
        if (*val == ',') val++;
    }
    return count;
}

/* ── WAV 落盘（float32 IEEE，格式 3；miniaudio dr_wav 解码播放） ── */

static void wav_begin(ArchoeraMediaEngine *e)
{
    e->wav = fopen_utf8(e->wav_file, "wb");
    if (!e->wav) return;

    int sample_rate = pipeline_get_output_sample_rate(e->p);
    int channels = e->cfg.output_channels;
    uint16_t block_align = (uint16_t)(channels * 4);
    uint32_t byte_rate = (uint32_t)(sample_rate * channels * 4);
    uint32_t placeholder = 0xFFFFFFFF;

    fwrite("RIFF", 1, 4, e->wav);
    fwrite(&placeholder, 4, 1, e->wav);
    fwrite("WAVEfmt ", 1, 8, e->wav);
    uint32_t fmt_size = 16;
    fwrite(&fmt_size, 4, 1, e->wav);
    uint16_t audio_format = 3;
    fwrite(&audio_format, 2, 1, e->wav);
    uint16_t ch = (uint16_t)channels;
    fwrite(&ch, 2, 1, e->wav);
    uint32_t sr = (uint32_t)sample_rate;
    fwrite(&sr, 4, 1, e->wav);
    fwrite(&byte_rate, 4, 1, e->wav);
    fwrite(&block_align, 2, 1, e->wav);
    uint16_t bits = 32;
    fwrite(&bits, 2, 1, e->wav);
    fwrite("data", 1, 4, e->wav);
    fwrite(&placeholder, 4, 1, e->wav);
}

static void wav_finalize(ArchoeraMediaEngine *e)
{
    if (!e->wav) return;
    long data_size = ftell(e->wav) - 44;
    fseek(e->wav, 40, SEEK_SET);
    uint32_t sz = (uint32_t)data_size;
    fwrite(&sz, 4, 1, e->wav);
    fseek(e->wav, 4, SEEK_SET);
    sz = (uint32_t)(data_size + 36);
    fwrite(&sz, 4, 1, e->wav);
    fclose(e->wav);
    e->wav = NULL;
}

/* PCM 流出回调：文件模式写 WAV/PCM；内存模式 append 块列表；
 *（两种模式）流式播放时喂入 raw 设备环形缓冲（背压 → 解码 ≈ 实时）。 */
static void on_pcm_out(const float *pcm, int samples, int channels,
                       double position_ms, void *user_data)
{
    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)user_data;
    if (samples <= 0 || channels <= 0) return;

    if (e->mem_mode) {
        mem_append(e, pcm, samples, channels, position_ms);
    } else {
        if (e->wav) {
            fwrite(pcm, sizeof(float), (size_t)samples * (size_t)channels, e->wav);
        }
        if (e->pcm) {
            int32_t header[3];
            header[0] = (int32_t)position_ms;
            header[1] = (int32_t)samples;
            header[2] = (int32_t)channels;
            fwrite(header, sizeof(header), 1, e->pcm);
            fwrite(pcm, sizeof(float), (size_t)samples * (size_t)channels, e->pcm);
        }
    }
    if (e->player && e->player_stream_mode) {
        player_stream_write(e->player, pcm, samples);
    }
}

/* skip_encoder 时管线无编码输出；非 skip 走丢弃回调（FFI 桌面恒为 player 模式） */
static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

/* ── 单会话暂存源（staged source swap）────────────────────────── */

/* 前向声明（json_escape_str 定义于本节之后；prepare 失败事件需转义消息） */
static void json_escape_str(const char *in, char *out, size_t cap);

/* 墙钟毫秒（timespec_get，跨平台，与 destroy 既有用法一致）。仅用于取相对
   时长（预取 ready 阈值/超时），系统时间跳变影响可忽略。 */
static int64_t me_now_ms(void)
{
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

/* 暂存源 PCM 回调：新源预解码 PCM 追加进 stage（交织 float），达容量上限即
   置 stage_full。首个回调反推 stage[0] 的真实媒体时间（= 本块末位置 - 本块
   时长）——pipeline 的 start_offset 被截断到整 ms，用真实起点才能与旧源
   decode cursor 做样本级对齐，消除切换瞬间的亚毫秒错位（高音量可闻的顿挫）。
   仅预取线程调用（p_next 独占），无需持锁。 */
static void on_stage_out(const float *pcm, int samples, int channels,
                         double position_ms, void *user_data)
{
    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)user_data;
    size_t add;
    if (!e || !pcm || samples <= 0 || channels <= 0) return;
    if (!e->stage_have_origin && e->stage_rate > 0) {
        e->stage_origin_ms = position_ms
            - (double)samples * 1000.0 / (double)e->stage_rate;
        e->stage_have_origin = 1;
    }
    if (e->stage_ch <= 0) e->stage_ch = channels;
    if (e->stage_full || !e->stage) return;
    add = (size_t)samples * (size_t)channels;
    if (add > e->stage_cap - e->stage_len) {
        add = (e->stage_cap > e->stage_len) ? (e->stage_cap - e->stage_len) : 0;
        e->stage_full = 1; /* 只填入剩余容量，其后丢弃 */
    }
    if (add > 0) {
        memcpy(e->stage + e->stage_len, pcm, add * sizeof(float));
        e->stage_len += add;
    }
    if (e->stage_len >= e->stage_cap) e->stage_full = 1;
}

/* 暂存富余达标：已暂存媒体时长 - 距 prepare 的墙钟时长 ≥ lead，即 commit
   裁剪掉实时追赶段后仍有 lead 秒新源 PCM 兜底（防切换后新源网络/解码抖动
   → ring 欠载顿挫）；满/EOF/超时兜底放行，绝不挂死。 */
#define STAGE_READY_LEAD_MS    1500   /* commit 后保留的新源缓冲下限 */
#define STAGE_READY_TIMEOUT_MS 10000  /* 网络慢也最多等这么久即放行 */
#define STAGE_CAP_MS           20000  /* stage 容量上限（内存兜底，remain≈lead） */

static int stage_target_reached(ArchoeraMediaEngine *e)
{
    double staged_ms, elapsed_ms;
    if (e->stage_full || e->stage_eof) return 1;
    if (!e->stage || e->stage_ch <= 0 || e->stage_rate <= 0) return 1;
    staged_ms = (double)(e->stage_len / (size_t)e->stage_ch) * 1000.0
                / (double)e->stage_rate;
    elapsed_ms = (double)(me_now_ms() - e->stage_t0_ms);
    if (elapsed_ms >= (double)STAGE_READY_TIMEOUT_MS) return 1;
    return staged_ms - elapsed_ms >= (double)STAGE_READY_LEAD_MS;
}

/* 发 source_ready 事件（含暂存管线的输出格式，供调用方校验/诊断）。调用方
   须已置 stage_ready_sent，并自行处理锁（引擎线程 commit 路径无锁）。 */
static void stage_emit_ready_event(ArchoeraMediaEngine *e)
{
    char buf[128];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"source_ready\",\"out_sample_rate\":%d,\"channels\":%d}",
             e->stage_rate, e->stage_ch);
    ev_enqueue(e, buf);
}

/* 预取线程：边播旧源边在另一核上预解码新源，维持「领先实时 lead 秒」的缓冲。
   stage 仅在本线程 stage_busy=1 期间被独占；commit/discard 置 stage_stop 并
   join 后由引擎线程接管。 */
static void *stage_prefetch_thread(void *arg)
{
    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)arg;
    pthread_mutex_lock(&e->stage_lock);
    while (!e->stage_stop) {
        if (stage_target_reached(e)) {
            struct timespec ts;
            timespec_get(&ts, TIME_UTC);
            ts.tv_nsec += 200 * 1000000L;
            if (ts.tv_nsec >= 1000000000L) {
                ts.tv_sec += ts.tv_nsec / 1000000000L;
                ts.tv_nsec %= 1000000000L;
            }
            pthread_cond_timedwait(&e->stage_cv, &e->stage_lock, &ts);
            continue;
        }
        e->stage_busy = 1;
        pthread_mutex_unlock(&e->stage_lock);
        ssize_t n = pipeline_process(e->p_next);
        pthread_mutex_lock(&e->stage_lock);
        e->stage_busy = 0;
        if (e->stage_stop) break; /* 已被 discard/commit 接管，勿再发事件 */
        if (n <= 0) {
            e->stage_eof = 1;
            if (!e->stage_ready_sent) {
                e->stage_ready_sent = 1;
                pthread_mutex_unlock(&e->stage_lock);
                stage_emit_ready_event(e);
                pthread_mutex_lock(&e->stage_lock);
            }
            pthread_cond_broadcast(&e->stage_cv);
            pthread_cond_wait(&e->stage_cv, &e->stage_lock);
            continue;
        }
        if (!e->stage_ready_sent && stage_target_reached(e)) {
            e->stage_ready_sent = 1;
            pthread_mutex_unlock(&e->stage_lock);
            stage_emit_ready_event(e);
            pthread_mutex_lock(&e->stage_lock);
            pthread_cond_broadcast(&e->stage_cv);
        }
    }
    pthread_mutex_unlock(&e->stage_lock);
    return NULL;
}

/* 停止并汇合预取线程（幂等）。interrupt_next!=0 时先 signal_shutdown 打断
   线程可能阻塞的网络读（用于彻底丢弃 p_next 的场景；commit 需保留 p_next
   以接力续播，故传 0）。 */
static void mediaengine_stage_stop_join(ArchoeraMediaEngine *e, int interrupt_next)
{
    if (!e->stage_thread_on) return;
    if (interrupt_next && e->p_next) pipeline_signal_shutdown(e->p_next);
    pthread_mutex_lock(&e->stage_lock);
    e->stage_stop = 1;
    pthread_cond_broadcast(&e->stage_cv);
    pthread_mutex_unlock(&e->stage_lock);
    pthread_join(e->stage_thread, NULL);
    e->stage_thread_on = 0;
}

/* 计算 commit 时需从 stage 头部丢弃的交叠 float 样本数：
     drop_ms = old_ms - next_start_ms（clamp >= 0）
     frames  = llround(drop_ms * rate / 1000)
     samples = frames * stage_ch（夹取到 [0, staged]）
   参数非法 / 无交叠 → 0。纯函数，供测试直接调用。 */
size_t archoera_mediaengine_stage_drop_samples(size_t staged, int stage_ch,
                                               int rate, double old_ms,
                                               double next_start_ms)
{
    double drop_ms;
    long long frames;
    unsigned long long max_frames;
    size_t samples;
    if (staged == 0 || stage_ch <= 0 || rate <= 0) return 0;
    drop_ms = old_ms - next_start_ms;
    if (!(drop_ms > 0.0)) return 0; /* 含 NaN → 不丢弃 */
    frames = llround(drop_ms * (double)rate / 1000.0);
    if (frames <= 0) return 0;
    /* 防乘法溢出：所需帧数超过暂存帧数 → 全丢 */
    max_frames = (unsigned long long)(staged / (size_t)stage_ch);
    if ((unsigned long long)frames > max_frames) return staged;
    samples = (size_t)frames * (size_t)stage_ch;
    return samples > staged ? staged : samples;
}

/* 丢弃暂存新源 + 释放 stage（幂等；未使用则空操作）。引擎线程/destroy 调用。 */
static void mediaengine_discard_next(ArchoeraMediaEngine *e)
{
    mediaengine_stage_stop_join(e, 1); /* 先停预取线程（打断阻塞读），再销毁管线 */
    if (e->p_next) {
        pipeline_signal_shutdown(e->p_next); /* 优雅中断（若正阻塞 IO） */
        pipeline_destroy(e->p_next);
        e->p_next = NULL;
    }
    free(e->stage);
    e->stage = NULL;
    e->stage_len = 0;
    e->stage_cap = 0;
    e->stage_ch = 0;
    e->stage_rate = 0;
    e->stage_full = 0;
    e->stage_eof = 0;
    e->stage_ready_sent = 0;
    e->stage_have_origin = 0;
    e->stage_origin_ms = 0.0;
    e->carry_pending = 0;
    e->next_ready = 0;
    e->next_start_ms = 0.0;
}

/* 暂存余量延迟续喂：把 e->stage 里剩余的新源 PCM 喂完再继续解码新源，保证
   「旧已排队 PCM → 新源」连续。流式走 ring（背压=实时），无设备（headless/
   文件）直接写出。用于 commit 时设备未消费（暂停）的 deferred 场景。 */
static void mediaengine_flush_carry(ArchoeraMediaEngine *e)
{
    int ch, frames;
    if (!e->stage || e->stage_len == 0) {
        e->carry_pending = 0;
        return;
    }
    ch = e->stage_ch > 0 ? e->stage_ch : 2;
    frames = (int)(e->stage_len / (size_t)ch);
    if (frames > 0) {
        if (e->player && e->player_stream_mode) {
            player_stream_write(e->player, e->stage, frames);
        } else {
            on_pcm_out(e->stage, frames, ch, (double)e->p_start_ms, e);
        }
    }
    e->stage_len = 0;
    e->carry_pending = 0;
}

/* prepare_source：为旧源当前 decode cursor（绝对 ms）预开新源并预解码进 stage。
   已有暂存源则先销毁（幂等重发覆盖）。失败 emit source_error 且旧源原样保留。 */
static void handle_prepare_source(ArchoeraMediaEngine *e, const char *line)
{
    char url[2048] = {0};
    EngineConfig cfg;
    double base_ms;
    int rate, ch;
    size_t cap;

    if (json_get_string(line, "url", url, sizeof(url)) < 0 || url[0] == '\0') {
        ev_enqueue(e, "{\"type\":\"source_error\",\"message\":\"missing url\"}");
        return;
    }
    if (!e->p) {
        ev_enqueue(e, "{\"type\":\"source_error\",\"message\":\"no active source\"}");
        return;
    }

    mediaengine_discard_next(e); /* 已有暂存源：先丢弃 */

    /* 旧源 decode cursor（写头，绝对 ms）：pipeline_get_position 相对本管线
       start_offset，故须加回 p_start_ms，跨 seek/CUE 偏移亦正确。
       新源从此处续，commit 时按交叠裁剪。 */
    base_ms = (double)e->p_start_ms + pipeline_get_position(e->p) * 1000.0;
    cfg = e->cfg;
    cfg.start_offset_ms = (int64_t)base_ms;
    /* 暂存源**沿用会话引擎**（尊重用户的 EraAudio / Stable 选择），不强制 FFmpeg。
       两条解码路径的 seek 都已样本级对齐（FFmpeg 走 decoder.c 的 PTS 裁剪；
       自研内核走 position_samples 裁剪），因此切档拼接对两种引擎都兼容且精确。 */
    /* 输出采样率/声道锁定为**当前活动管线的实际输出**：passthrough 下
       cfg.output_sample_rate=0（各管线跟随各自源采样率），新旧源采样率不同
       （如转码 MP3 44.1k ↔ 无损 48k/96k）时，切档后新源会以不同速率喂入
       **未重建**的 player → 变调/变速（默认 passthrough 下必现）。锁定后
       新源必要时做一次重采样，ring/设备格式始终不变。 */
    cfg.output_sample_rate = pipeline_get_output_sample_rate(e->p);
    if (cfg.output_sample_rate <= 0) cfg.output_sample_rate = e->cfg.output_sample_rate;
    cfg.output_channels = pipeline_get_output_channels(e->p);
    if (cfg.output_channels <= 0) cfg.output_channels = e->cfg.output_channels;

    e->p_next = pipeline_create(url, &cfg, dummy_output, NULL);
    if (!e->p_next) {
        char msg[320], esc[384], buf[512];
        snprintf(msg, sizeof(msg), "prepare create failed: %s", url);
        json_escape_str(msg, esc, sizeof(esc));
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"source_error\",\"message\":\"%s\"}", esc);
        ev_enqueue(e, buf);
        return;
    }
    pipeline_set_playback_streaming(e->p_next, true);

    rate = pipeline_get_output_sample_rate(e->p_next);
    if (rate <= 0) rate = pipeline_get_output_sample_rate(e->p);
    if (rate <= 0) rate = 48000;
    ch = pipeline_get_output_channels(e->p_next);
    if (ch <= 0) ch = e->cfg.output_channels > 0 ? e->cfg.output_channels : 2;
    cap = (size_t)((double)rate * (STAGE_CAP_MS / 1000.0)) * (size_t)ch;
    if (cap == 0) cap = (size_t)rate * (size_t)ch;
    e->stage = (float *)malloc(cap * sizeof(float));
    if (!e->stage) {
        pipeline_signal_shutdown(e->p_next);
        pipeline_destroy(e->p_next);
        e->p_next = NULL;
        ev_enqueue(e, "{\"type\":\"source_error\",\"message\":\"stage alloc failed\"}");
        return;
    }
    e->stage_cap = cap;
    e->stage_len = 0;
    e->stage_ch = ch;
    e->stage_rate = rate;
    e->stage_full = 0;
    e->stage_eof = 0;
    e->stage_ready_sent = 0;
    e->stage_have_origin = 0;
    e->stage_origin_ms = 0.0;
    e->next_start_ms = base_ms;
    e->next_ready = 1;
    e->stage_t0_ms = me_now_ms();
    e->stage_stop = 0;
    e->stage_busy = 0;
    pipeline_set_pcm_out_cb(e->p_next, on_stage_out, e);

    /* 独立预取线程：把新源解码从实时引擎线程剥离（旧源照常喂环），避免争抢
       造成旧源欠载顿挫。source_ready 由该线程在「缓冲富余达标/EOF/超时」异步发。 */
    if (pthread_create(&e->stage_thread, NULL, stage_prefetch_thread, e) != 0) {
        pipeline_signal_shutdown(e->p_next);
        pipeline_destroy(e->p_next);
        e->p_next = NULL;
        free(e->stage);
        e->stage = NULL;
        e->stage_cap = 0;
        e->stage_ch = 0;
        e->stage_rate = 0;
        e->next_ready = 0;
        ev_enqueue(e, "{\"type\":\"source_error\",\"message\":\"stage thread failed\"}");
        return;
    }
    e->stage_thread_on = 1;
}

/* commit_source：停止并汇合预取线程后，把已预解码的 stage 续喂同一 ring，新源
   转正（设备/会话不重建）。交叠按「旧源当前 decode cursor − stage[0] 真实媒体
   时间」样本级裁剪（亚毫秒对齐，消除切换瞬间错位）。余量续喂：播放中立即喂完
   （背压=实时）；暂停时挂起为 carry，由主循环在恢复后先喂（不阻塞引擎线程）；
   无设备（headless/文件）直接写出保持连续；若旧源已在曲尾排空（EOF），先清
   EOF/停止标志并重启设备，保证新源被播出（尾部切档不失效）。 */
static void handle_commit_source(ArchoeraMediaEngine *e)
{
    double old_ms, origin_ms;
    int rate, ch;
    size_t drop, remain;

    if (!e->p_next || !e->stage || !e->next_ready) {
        ev_enqueue(e, "{\"type\":\"source_error\",\"message\":\"no staged source\"}");
        return;
    }
    /* 停止并汇合预取线程：此后 p_next/stage 独占归引擎线程（不打断 p_next，
       保留其解码位置以便接力续播）。 */
    mediaengine_stage_stop_join(e, 0);
    /* 调用方可能在预取线程发出 source_ready 前就 commit（如测试同批下发）：
       补发一次，保证 ready→switched 事件握手始终完整。 */
    if (!e->stage_ready_sent) {
        e->stage_ready_sent = 1;
        stage_emit_ready_event(e);
    }

    old_ms = (double)e->p_start_ms + pipeline_get_position(e->p) * 1000.0;
    rate = e->stage_rate > 0 ? e->stage_rate
                             : pipeline_get_output_sample_rate(e->p_next);
    if (rate <= 0) rate = pipeline_get_output_sample_rate(e->p);
    if (rate <= 0) rate = 48000;
    ch = e->stage_ch > 0 ? e->stage_ch : e->cfg.output_channels;
    if (ch <= 0) ch = 2;
    /* stage[0] 真实媒体时间（首回调反推）；未跑预解码则退化为建源起点。 */
    origin_ms = e->stage_have_origin ? e->stage_origin_ms : e->next_start_ms;

    drop = archoera_mediaengine_stage_drop_samples(e->stage_len, ch, rate,
                                                   old_ms, origin_ms);
    remain = e->stage_len - drop;

    /* 把剩余新源 PCM 移到 stage 头部作为「待喂余量」。 */
    if (remain > 0 && drop > 0) {
        memmove(e->stage, e->stage + drop, remain * sizeof(float));
    }
    e->stage_len = remain;

    /* 新源转正：回调切回正常输出（内存/文件/ring），保持流式小块语义。 */
    pipeline_set_pcm_out_cb(e->p_next, on_pcm_out, e);
    pipeline_set_playback_streaming(e->p_next, true);
    pipeline_signal_shutdown(e->p);
    pipeline_destroy(e->p);
    e->p = e->p_next;
    e->p_next = NULL;
    /* p_start_ms 跟随新管线 cfg.start_offset（= (int64_t)base_ms，截断值，故用
       (int64_t) 而非 llround 保持一致）；session_offset_ms 是 rel 事件零点
       （= cfg.start_offset_ms），切档不改变，后续 seek 仍正确。 */
    e->p_start_ms = (int64_t)e->next_start_ms;
    e->next_ready = 0;
    e->next_start_ms = 0.0;
    e->stage_cap = 0;
    e->stage_rate = 0;
    e->stage_full = 0;
    e->stage_eof = 0;
    e->stage_ready_sent = 0;
    e->stage_have_origin = 0;
    e->stage_origin_ms = 0.0;

    /* 余量续喂：播放中立即喂完（背压=实时，旧已排队 PCM 播完自然接上新源）；
       暂停时挂起为 carry，恢复播放后由主循环先喂（绝不在此阻塞引擎线程）；
       曲尾排空（EOF）先 resume 让设备继续消费，保证尾部切档不失效。 */
    if (e->stage_len > 0) {
        int playing = 1;
        if (e->player && e->player_stream_mode) {
            if (player_stream_eof(e->player)) {
                player_stream_resume(e->player); /* 曲尾排空：清 EOF/重启设备 */
            }
            player_get_state(e->player, &playing, NULL, NULL);
        }
        if (playing) {
            mediaengine_flush_carry(e);
        } else {
            e->carry_pending = 1;
        }
    }
    if (e->stage_len == 0) {
        free(e->stage);
        e->stage = NULL;
        e->stage_cap = 0;
        e->stage_ch = 0;
        e->stage_rate = 0;
        e->carry_pending = 0;
    }

    {
        char buf[160];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"source_switched\",\"position_ms\":%.0f}", old_ms);
        ev_enqueue(e, buf);
    }
}

/* 播放器事件 → 事件 FIFO（player_event_fn 签名） */
static void player_event_cb(const char *json, void *user_data)
{
    ev_enqueue((ArchoeraMediaEngine *)user_data, json);
}

/* 简易 JSON 字符串转义（事件里嵌 C 错误信息时防破 JSON） */
static void json_escape_str(const char *in, char *out, size_t cap)
{
    size_t i, o = 0;
    if (cap == 0) return;
    for (i = 0; in && in[i] && o + 8 < cap; ++i) {
        unsigned char c = (unsigned char)in[i];
        switch (c) {
        case '"':  out[o++] = '\\'; out[o++] = '"';  break;
        case '\\': out[o++] = '\\'; out[o++] = '\\'; break;
        case '\n': out[o++] = '\\'; out[o++] = 'n';  break;
        case '\r': out[o++] = '\\'; out[o++] = 'r';  break;
        case '\t': out[o++] = '\\'; out[o++] = 't';  break;
        default:
            if (c < 0x20) {
                /* 控制字符按 \uXXXX 转义（理论上不出现，防御） */
                if (o + 6 < cap) {
                    snprintf(out + o, cap - o, "\\u%04x", c);
                    o += 6;
                }
            } else {
                out[o++] = (char)c;
            }
            break;
        }
    }
    out[o] = '\0';
}

/* 播放中切 sink：先在“新设备上、暂停状态”建好播放器（带音量/续播位置、
   不重发 playing），成功后停旧播新。失败返回 -1 且旧播放器原样保留（回退）。 */
static int mediaengine_switch_sink(ArchoeraMediaEngine *e,
                                   char *errbuf, size_t errcap)
{
    double pos_ms = 0.0;
    int playing = 0;
    float vol = 1.0f;
    PlayerCtx *np;

    if (!e->player) return 0; /* 尚未播放：仅存储（调用方已更新 sink_id） */

    /* 流式播放：raw 设备直接切 sink（管线/解码不停，清缓冲续播） */
    if (e->player_stream_mode) {
        player_get_state(e->player, &playing, &pos_ms, &vol);
        if (player_stream_switch_sink(e->player, e->sink_id) != 0) {
            if (errbuf && errcap > 0) {
                snprintf(errbuf, errcap,
                    "流式切换到 sink '%s' 失败（设备消失/不支持），沿用原设备",
                    e->sink_id[0] ? e->sink_id : "(系统默认)");
            }
            return -1;
        }
        if (e->pos_interval_ms > 0) {
            player_set_position_interval(e->player, e->pos_interval_ms);
        }
        return 0;
    }

    player_get_state(e->player, &playing, &pos_ms, &vol);

    player_start_options opts = PLAYER_START_OPTIONS_DEFAULT;
    opts.start_paused = 1;     /* 建好→停旧→再启动，无缝切换不叠音 */
    opts.volume       = vol;
    opts.seek_ms      = pos_ms;
    opts.emit_playing = 0;     /* 同一曲续播，Dart 无需重复收到 playing */

    np = player_start_opts(e->wav_file, e->sink_id, &opts,
                              player_event_cb, e);
    if (!np) {
        if (errbuf && errcap > 0) {
            snprintf(errbuf, errcap,
                "切换到 sink '%s' 的播放器启动失败（设备消失/不支持），"
                "沿用原设备", e->sink_id[0] ? e->sink_id : "(系统默认)");
        }
        return -1;
    }
    if (e->pos_interval_ms > 0) {
        player_set_position_interval(np, e->pos_interval_ms);
    }

    /* 新播放器就绪（暂停、已 seek 到位）→ 停旧 → 按原状态恢复 */
    player_stop(e->player);
    e->player = np;
    if (playing) {
        player_command(np, "play", NULL, NULL);
        /* 立即以续播位置推一次 position，UI 进度不等到下一个 poll 节拍 */
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"position\",\"position_ms\":%.0f}", pos_ms);
        ev_enqueue(e, buf);
    }
    return 0;
}

/* set_sink 处理：存引擎选择 →（播放中）平滑重启播放器 → 事件回报。
   id 为空串 = 回系统默认。 */
static void handle_set_sink(ArchoeraMediaEngine *e, const char *id)
{
    char err[256];
    int ok = 1;
    const char *req = (id && id[0]) ? id : "";
    const char *old = e->sink_id ? e->sink_id : "";

    err[0] = '\0';
    fprintf(stderr, "[mediaengine] set_sink id=\"%s\" (playing=%s)\n",
            req, e->player ? "yes" : "no");

    if (strcmp(req, old) == 0) {
        /* 幂等：与当前应用一致，不重启 */
        ok = 1;
    } else {
        free(e->sink_id);
        e->sink_id = strdup(req);
        e->sink_user_set = 1;
        if (e->player) {
            if (mediaengine_switch_sink(e, err, sizeof(err)) != 0) {
                ok = 0;
            }
        }
    }

    {
        char esc_err[256];
        char buf[384];
        json_escape_str(err, esc_err, sizeof(esc_err));
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"sink_changed\",\"ok\":%s,\"err\":\"%s\"}",
                 ok ? "true" : "false", esc_err);
        ev_enqueue(e, buf);
    }
}

/* ── 控制命令处理（对应 main.c handle_command；事件改入 FIFO） ──── */

/* 前向声明（定义在引擎线程节；handle_command 在此引用） */
static int mediaengine_stream_rebuild(ArchoeraMediaEngine *e, int64_t abs_start_ms,
                                      double pos_base);
static void mediaengine_stream_seek(ArchoeraMediaEngine *e, double rel_ms);

static void handle_command(ArchoeraMediaEngine *e, const char *line)
{
    char type[64] = {0};
    if (json_get_string(line, "type", type, sizeof(type)) < 0) return;

    if (strcmp(type, "set_eq") == 0) {
        float gains[EQ_BANDS] = {0};
        int n = json_get_float_array(line, "gains", gains, EQ_BANDS);
        if (n > 0) pipeline_set_eq_gains(e->p, gains);
        double preamp = 0;
        if (json_get_number(line, "preamp", &preamp) == 0) {
            pipeline_set_preamp(e->p, (float)preamp);
        }
    } else if (strcmp(type, "set_peq") == 0) {
        /* 方向① D1：参数化 EQ（扁平 [kind,freq,q,gain,...]，长度须 % 4 == 0） */
        float bands[PARAMETRIC_EQ_MAX_BANDS * 4] = {0};
        int n = json_get_float_array(line, "bands", bands,
                                     PARAMETRIC_EQ_MAX_BANDS * 4);
        if (n > 0 && n % 4 == 0) {
            pipeline_set_peq_bands(e->p, bands, n / 4);
        }
        bool peq_enabled = true;
        if (json_get_bool(line, "enabled", &peq_enabled) == 0) {
            pipeline_set_peq_enabled(e->p, peq_enabled);
        }
        double peq_preamp = 0;
        if (json_get_number(line, "preamp", &peq_preamp) == 0) {
            pipeline_set_peq_preamp(e->p, (float)peq_preamp);
        }
    } else if (strcmp(type, "set_lowfreq") == 0) {
        /* 方向① D2：次声/低频管理 */
        bool lf_enabled = true;
        if (json_get_bool(line, "enabled", &lf_enabled) == 0) {
            pipeline_set_lowfreq_enabled(e->p, lf_enabled);
        }
        double hpf_freq = -1.0, hpf_order = 2.0;
        if (json_get_number(line, "hpf_freq", &hpf_freq) == 0) {
            if (json_get_number(line, "hpf_order", &hpf_order) != 0) hpf_order = 2.0;
            pipeline_set_lowfreq_hpf(e->p, (float)hpf_freq, (int)hpf_order);
        }
        double bass_gain = 0.0, bass_freq = 100.0;
        if (json_get_number(line, "bass_gain", &bass_gain) == 0) {
            if (json_get_number(line, "bass_freq", &bass_freq) != 0) bass_freq = 100.0;
            pipeline_set_lowfreq_bass(e->p, (float)bass_gain, (float)bass_freq);
        }
    } else if (strcmp(type, "set_volume") == 0) {
        double vol = 1.0;
        if (json_get_number(line, "gain", &vol) == 0) {
            e->last_volume = (float)vol;
            if (e->player) {
                player_command(e->player, "set_volume", NULL, &vol);
            } else {
                pipeline_set_volume(e->p, (float)vol);
            }
        }
    } else if (strcmp(type, "set_sink") == 0) {
        char id[512] = {0};
        if (json_get_string(line, "id", id, sizeof(id)) >= 0) {
            handle_set_sink(e, id);
        } else {
            ev_enqueue(e, "{\"type\":\"sink_changed\",\"ok\":false,\"err\":\"missing id\"}");
        }
    } else if (strcmp(type, "set_normalization") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_normalization_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "set_limiter") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_limiter_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "set_fft") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_fft_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "set_tempo_speed") == 0) {
        double speed = 1.0;
        if (json_get_number(line, "speed", &speed) == 0) {
            pipeline_set_tempo_speed(e->p, (float)speed);
        }
    } else if (strcmp(type, "set_tempo_pitch") == 0) {
        double semitones = 0.0;
        if (json_get_number(line, "semitones", &semitones) == 0) {
            pipeline_set_tempo_pitch(e->p, (float)semitones);
        }
    } else if (strcmp(type, "set_tempo") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_tempo_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "get_status") == 0) {
        if (e->player) {
            player_command(e->player, "get_status", NULL, NULL);
        } else {
            char buf[256];
            double pos = pipeline_get_position(e->p);
            double dur = pipeline_get_duration(e->p);
            snprintf(buf, sizeof(buf),
                "{\"type\":\"status\",\"position_ms\":%.0f,\"duration_ms\":%.0f}",
                pos * 1000.0, dur * 1000.0);
            ev_enqueue(e, buf);
        }
    } else if (strcmp(type, "play") == 0) {
        if (e->player) player_command(e->player, "play", NULL, NULL);
    } else if (strcmp(type, "pause") == 0) {
        if (e->player) player_command(e->player, "pause", NULL, NULL);
    } else if (strcmp(type, "set_playing") == 0) {
        bool playing = true;
        if (json_get_bool(line, "playing", &playing) == 0 && e->player) {
            double v = playing ? 1.0 : 0.0;
            player_command(e->player, "set_playing", NULL, &v);
        }
    } else if (strcmp(type, "seek") == 0) {
        double pos = 0.0;
        if (json_get_number(line, "position_ms", &pos) == 0) {
            /* 无条件记录 pending（player 存在则立即执行）：
               转码/加载阶段拖动进度条也能生效——播放器启动后应用目标位置 */
            e->seek_pending = 1;
            e->pending_seek_ms = pos;
            if (e->player) {
                if (e->player_stream_mode) {
                    /* 流式：重建解码会话（停流 → 从目标偏移重新解码出声） */
                    mediaengine_stream_seek(e, pos);
                    e->seek_pending = 0;
                } else {
                    player_command(e->player, "seek", &pos, NULL);
                }
            }
        }
    } else if (strcmp(type, "set_event_interval") == 0) {
        /* 降频协商（engine-event-push-plan §4.2）：Dart 发目标间隔 →
           写入 player 运行期字段 → 立即回执 event_interval 确认实际生效值。
           以 C 回执为准，Dart 不假设切换已生效 */
        double iv = 0.0;
        if (json_get_number(line, "interval_ms", &iv) == 0 && iv >= 20) {
            int interval = (int)iv;
            if (interval < 20) interval = 20;
            e->pos_interval_ms = interval;
            if (e->player) {
                player_set_position_interval(e->player, interval);
            }
            char buf[96];
            snprintf(buf, sizeof(buf),
                "{\"type\":\"event_interval\",\"interval_ms\":%d}", interval);
            ev_enqueue(e, buf);
        }
    } else if (strcmp(type, "prepare_source") == 0) {
        /* 无缝音质切换：旧源照常播放，预开 + 预解码新源进 stage（同会话同设备）。 */
        handle_prepare_source(e, line);
    } else if (strcmp(type, "commit_source") == 0) {
        /* 提交暂存源：丢弃交叠段后续喂同一 ring，新源转正（会话不重建）。 */
        handle_commit_source(e);
    } else if (strcmp(type, "stop") == 0) {
        QA_STORE_REL(&e->stop_requested, 1);
    }
}

/* ── 流式会话（§B：边解码边出声）────────────────────────────── */

/* 重建会话（seek / 新解码段）：以 abs_start_ms（源绝对 ms）重建管线 + 输出
 * 文件；流播放器对象保留（设备不重建），游标基置 pos_base（事件 rel 基准）。
 * 事务式：先建好新管线/输出再停旧（失败返回 -1 且旧会话原样保留——seek 永不
 * 因重建失败把引擎拖停；调用方只回执错误，主循环继续旧流）。返回 0 成功。 */
static int mediaengine_stream_rebuild(ArchoeraMediaEngine *e, int64_t abs_start_ms,
                                      double pos_base)
{
    EngineConfig cfg2 = e->cfg;
    AudioPipeline *np;

    /* seek/重建会使暂存新源的解码起点失效：先整体丢弃，避免悬垂/错位续喂。 */
    mediaengine_discard_next(e);

    cfg2.start_offset_ms = abs_start_ms;
    /* 1) 先建新管线（含解码 seek；native 失败内部已回退 FFmpeg）——旧会话不动。
       磁盘源走 pipeline_create；store 会话（整曲驻留可 seek）经 AVIO-mem 重建，
       游标从目标偏移继续从同一 store 解码。 */
    np = e->store
        ? pipeline_create_store(e->store, &cfg2, dummy_output, NULL)
        : pipeline_create(e->source, &cfg2, dummy_output, NULL);
    if (!np) return -1;
    pipeline_set_playback_streaming(np, true);

    /* 2) 新管线就绪 → 停旧设备/缓冲、销毁旧管线与输出文件 */
    if (e->player && e->player_stream_mode) {
        player_stream_seek_reset(e->player); /* 停设备、清缓冲、游标归零 */
    }
    if (e->p) { pipeline_destroy(e->p); e->p = NULL; }
    if (e->wav) { fclose(e->wav); e->wav = NULL; }
    if (e->pcm) { fclose(e->pcm); e->pcm = NULL; }
    if (e->mem_mode) mem_reset(e); /* 内存模式：清块列表 + epoch++（对齐文件截断） */

    e->p = np;
    e->p_start_ms = abs_start_ms; /* 新管线起点绝对 ms（prepare 的绝对 cursor 基准） */
    if (e->mem_mode) {
        pipeline_set_pcm_out_cb(e->p, on_pcm_out, e);
    } else {
        if (e->player_file) {
            wav_begin(e); /* 截断重建 stream.wav */
            pipeline_set_playback_streaming(e->p, true);
        }
        e->pcm = fopen_utf8(e->pcm_file, "wb"); /* 截断重建 stream.pcm */
        if (e->wav || e->pcm) {
            pipeline_set_pcm_out_cb(e->p, on_pcm_out, e);
        }
    }
    if (e->player && e->player_stream_mode) {
        player_stream_set_pos_base(e->player, pos_base);
        if (e->pos_interval_ms > 0) {
            player_set_position_interval(e->player, e->pos_interval_ms);
        }
        double v = (double)e->last_volume;
        player_command(e->player, "set_volume", NULL, &v);
    }
    return 0;
}

/* 会话开始时（已有管线/输出文件）尝试启动流式播放器。返回 1=流式已启动。 */
static int mediaengine_stream_begin(ArchoeraMediaEngine *e)
{
    int rate, ch;
    player_start_options popts = PLAYER_START_OPTIONS_DEFAULT;
    if (!e->player_file || !e->p) return 0;
    rate = pipeline_get_output_sample_rate(e->p);
    ch = e->cfg.output_channels;
    if (rate <= 0) rate = 48000;
    if (ch <= 0) ch = 2;
    e->player = player_stream_open(e->sink_id, &popts, rate, ch,
                                   player_event_cb, e);
    if (!e->player) {
        e->player_stream_mode = 0;
        return 0; /* 无声/设备不可用：回退旧路径（全速解码 → 文件播放器） */
    }
    e->player_stream_mode = 1;
    pipeline_set_playback_streaming(e->p, true);
    player_stream_set_pos_base(e->player,
        (double)(e->cfg.start_offset_ms - e->session_offset_ms));
    if (e->pos_interval_ms > 0) {
        player_set_position_interval(e->player, e->pos_interval_ms);
    }
    double v = (double)e->last_volume;
    player_command(e->player, "set_volume", NULL, &v);
    fprintf(stderr,
        "[mediaengine] 流式播放启动（首块 PCM 即出声，解码按设备消费节奏推进）\n");
    return 1;
}

/* 流式播放中 seek（rel 相对 session offset）→ 重建管线 + 播放器归位。
 * 重建失败（解码器开不了目标段/设备不可用）不拖停引擎：回执错误，主循环沿用
 * 旧流继续（旧会话未被销毁），用户可再次 seek/暂停，绝不「卡死/静音挂起」。 */
static void mediaengine_stream_seek(ArchoeraMediaEngine *e, double rel_ms)
{
    double dur_ms = pipeline_get_duration(e->p) * 1000.0;
    double abs_ms;
    if (rel_ms < 0) rel_ms = 0;
    abs_ms = (double)e->session_offset_ms + rel_ms;
    if (dur_ms > 0 && abs_ms > dur_ms) abs_ms = dur_ms;
    if (mediaengine_stream_rebuild(e, (int64_t)abs_ms, rel_ms) != 0) {
        ev_enqueue(e, "{\"type\":\"error\",\"message\":\"seek 重建会话失败，沿用当前播放\"}");
        return;
    }
    /* 立即确认位置（UI 立即回填；随后按设备消费继续推 position） */
    {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"position\",\"position_ms\":%.0f}", rel_ms);
        ev_enqueue(e, buf);
    }
}

/* 流式主循环：解码（背压≈实时）→ 喂设备，穿插处理命令/位置事件；
 * EOF+flush 后喂完剩余即自然结束；缓冲排空期间若收到 seek（重建出新管线），
 * 回到解码循环续播新段（seek 永不因「已在曲尾排空」而静默失效/挂死）。
 * 返回 0 正常 / <0 错误码。 */
static int mediaengine_stream_run(ArchoeraMediaEngine *e)
{
    int code = 0;

    while (!QA_LOAD_ACQ(&e->stop_requested)) {
        char line[CMD_LINE + 1];
        int playing = 1;

        /* 暂停（设备停）时不解码：ring 满会自阻塞，且无需超前解码 */
        if (e->player) player_get_state(e->player, &playing, NULL, NULL);
        if (!playing) {
            while (cmd_dequeue(e, line, sizeof(line))) {
                handle_command(e, line);
            }
            if (e->player) player_poll(e->player);
            struct timespec ts = {0, 20 * 1000000L};
            nanosleep(&ts, NULL);
            continue;
        }

        /* 暂停期间 commit 的暂存余量：恢复播放后先把新源余量喂完再解码新源
           （背压=实时），保证拼接连续。 */
        if (e->carry_pending) {
            mediaengine_flush_carry(e);
            continue;
        }

        /* 缓冲水位软门（≈1.4s，< ring 上限）：解码≈实时推进，位置事件/命令
           轮询保持 ~20ms 节拍（而非在 ring 满处长时间阻塞） */
        if (e->player && e->player_stream_mode) {
            if (player_stream_buffered_ms(e->player) > 1400.0) {
                while (cmd_dequeue(e, line, sizeof(line))) {
                    handle_command(e, line);
                }
                if (e->player) player_poll(e->player);
                struct timespec ts = {0, 20 * 1000000L};
                nanosleep(&ts, NULL);
                continue;
            }
        }

        if (!e->p) break; /* 防御：无管线不进入解码 */

        ssize_t n = pipeline_process(e->p);
        if (n < 0) {
            char err[160];
            snprintf(err, sizeof(err),
                "{\"type\":\"error\",\"message\":\"pipeline error %zd\"}", (size_t)n);
            ev_enqueue(e, err);
            code = (int)n;
            /* 对齐原语义：解码错误后仍执行 flush + 收尾（WAV 头回填/排空） */
        } else if (n > 0) {
            while (cmd_dequeue(e, line, sizeof(line))) {
                handle_command(e, line);
            }
            if (e->player) player_poll(e->player);
            continue;
        }

        /* n == 0（本段 EOF）或解码错误：flush 残留 → 标记解码流结束 → 缓冲尾段播完自然结束 */
        if (QA_LOAD_ACQ(&e->stop_requested)) break;
        {
            int ret = pipeline_run(e->p); /* flush 残留（最后喂入缓冲） */
            if (ret < 0) {
                char err[160];
                snprintf(err, sizeof(err), "{\"type\":\"error\",\"message\":\"flush %d\"}", ret);
                ev_enqueue(e, err);
                code = ret;
                break;
            }
            ev_enqueue(e, "{\"type\":\"done\"}");
            if (e->wav) wav_finalize(e);
            if (e->player && e->player_stream_mode) {
                AudioPipeline *eof_pipe = e->p;
                player_stream_end(e->player);
                /* 排空期间持续响应命令：seek（重建出新管线）→ 回到解码循环续播 */
                for (;;) {
                    if (QA_LOAD_ACQ(&e->stop_requested)) break;
                    while (cmd_dequeue(e, line, sizeof(line))) {
                        handle_command(e, line);
                    }
                    if (e->p != eof_pipe) break; /* 已重建：新段解码 */
                    if (e->player && player_poll(e->player)) break; /* 自然结束 */
                    struct timespec ts = {0, 20 * 1000000L};
                    nanosleep(&ts, NULL);
                }
                if (QA_LOAD_ACQ(&e->stop_requested)) break;
                if (e->p == eof_pipe) {
                    break; /* 自然结束（无重建） */
                }
                continue; /* seek 重建：回到解码循环续播新段 */
            }
            break; /* 非流式（回退路径不会走到这） */
        }
    }

    if (e->player) {
        player_stop(e->player);
        e->player = NULL;
        e->player_stream_mode = 0;
    }
    mediaengine_discard_next(e); /* 会话结束：丢弃未提交的暂存源/暂存缓冲 */
    return code;
}

/* ── 引擎线程 ────────────────────────────────────────────────── */

static void *engine_thread(void *arg)
{
    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)arg;
    int pool_on = 0;

    /* S1 常驻内核池（默认开启）：EraAudio 原生（engine_mode==1）时，本地路径 /
     * 在线回调（source）与 SegStore 内存源（store）均走 zk_engine 流式 seam；
     * ARCHOERA_ERA_POOL=0 可关闭（A/B 回退）；失败（含内核未链接）继续旧
     * zk_decoder 路径，回退语义完全不变。 */
    if (e->cfg.engine_mode == 1 && (e->source || e->store)) {
        const char *pool_env = getenv("ARCHOERA_ERA_POOL");
        if (pool_env == NULL || pool_env[0] != '0') {
            if (native_decoder_pool_begin(1, 2, 16) == 0) {
                pool_on = 1;
                fprintf(stderr,
                    "[mediaengine] EraAudio 常驻内核池已启用 (ARCHOERA_ERA_POOL)\n");
            } else {
                fprintf(stderr,
                    "[mediaengine] EraAudio 常驻内核池启用失败 → 沿用旧 zk_decoder 路径\n");
            }
        }
    }

    /* pipeline_create / pipeline_create_store 在引擎线程执行：avformat_open_input
       对网络源是阻塞 IO，在 Dart isolate 线程执行会被 VM 中断信号打断（poll/recv
       返回 EINTR，FFmpeg 网络层直接失败）。pthread 线程不接收 Dart VM 信号，安全。
       store 会话（整曲已驻留内存）经 pipeline_create_store → AVIO-mem 解码。 */
    e->p = e->store
        ? pipeline_create_store(e->store, &e->cfg, dummy_output, NULL)
        : pipeline_create(e->source, &e->cfg, dummy_output, NULL);
    if (!e->p) {
        char err[320];
        if (e->store) {
            snprintf(err, sizeof(err),
                "{\"type\":\"error\",\"message\":\"pipeline create_store failed\"}");
        } else {
            snprintf(err, sizeof(err),
                "{\"type\":\"error\",\"message\":\"pipeline create failed: %s\"}",
                e->source);
        }
        ev_enqueue(e, err);
        ev_enqueue(e, "{\"type\":\"exited\",\"code\":-1}");
        QA_STORE_REL(&e->done, 1);
        if (pool_on) native_decoder_pool_end(); /* 无流打开，可直接停池 */
        return NULL;
    }

    if (e->mem_mode) {
        /* 内存播放模式：不开 stream.wav / stream.pcm（PCM 入内存块列表）。
           mem_sr 供 Dart 线程 pcm_window 换算，写入持 mem_lock。 */
        int sr = pipeline_get_output_sample_rate(e->p);
        if (sr <= 0) sr = pipeline_get_source_sample_rate(e->p);
        pthread_mutex_lock(&e->mem_lock);
        e->mem_sr = sr;
        pthread_mutex_unlock(&e->mem_lock);
        pipeline_set_pcm_out_cb(e->p, on_pcm_out, e);
    } else {
        if (e->player_file) {
            wav_begin(e);
        }
        e->pcm = fopen_utf8(e->pcm_file, "wb");
        if (e->wav || e->pcm) {
            pipeline_set_pcm_out_cb(e->p, on_pcm_out, e);
        }
    }

    /* ready 事件（backend：F5 实际解码后端 "zig"/"ffmpeg"） */
    char ready[384];
    snprintf(ready, sizeof(ready),
        "{\"type\":\"ready\",\"version\":\"%s\",\"duration_ms\":%.0f,"
        "\"sample_rate\":%d,\"channels\":%d,\"out_sample_rate\":%d,"
        "\"backend\":\"%s\"}",
        audio_engine_version(),
        pipeline_get_duration(e->p) * 1000.0,
        pipeline_get_source_sample_rate(e->p),
        pipeline_get_source_channels(e->p),
        pipeline_get_output_sample_rate(e->p),
        pipeline_backend(e->p));
    ev_enqueue(e, ready);

    int code = 0;
    int streaming = 0;

    if (e->mem_mode) {
        /* 内存播放模式（不落盘）：无设备不可回退（不写 stream.wav，无文件播放器可用）。
           - ARCHOERA_MEMORY_HEADLESS=1：测试/无声环境专用——不触碰设备，全速解码至
             EOF，PCM 仅入内存块列表（pcm_window 可验证内容），不落盘、不播放；
           - 否则先尝试 raw 设备流；失败直接 error（不做文件回退）。 */
        if (getenv("ARCHOERA_MEMORY_HEADLESS")) {
            fprintf(stderr,
                "[mediaengine] 内存播放模式 headless（无设备，解码入内存块列表）\n");
            for (;;) {
                if (QA_LOAD_ACQ(&e->stop_requested)) break;
                if (e->carry_pending) mediaengine_flush_carry(e);
                ssize_t n = pipeline_process(e->p);
                if (n < 0) {
                    char err[160];
                    snprintf(err, sizeof(err),
                        "{\"type\":\"error\",\"message\":\"pipeline error %zd\"}", (size_t)n);
                    ev_enqueue(e, err);
                    code = (int)n;
                    break;
                }
                if (n == 0) break; /* EOF */
                char line[CMD_LINE + 1];
                while (cmd_dequeue(e, line, sizeof(line))) {
                    handle_command(e, line);
                }
            }
            if (!QA_LOAD_ACQ(&e->stop_requested)) {
                int ret = pipeline_run(e->p); /* flush 残留 */
                if (ret < 0) {
                    char err[160];
                    snprintf(err, sizeof(err),
                        "{\"type\":\"error\",\"message\":\"flush %d\"}", ret);
                    ev_enqueue(e, err);
                    code = ret;
                } else {
                    ev_enqueue(e, "{\"type\":\"done\"}");
                }
            }
        } else {
            streaming = mediaengine_stream_begin(e);
            if (!streaming) {
                ev_enqueue(e,
                    "{\"type\":\"error\",\"message\":\"内存播放模式无可用输出设备\"}");
                code = -1;
            } else {
                code = mediaengine_stream_run(e);
            }
        }
        goto mem_exit;
    }

    /* 流式优先：player 模式先尝试 raw 设备流（首块 PCM 即出声）；失败回退旧路径。
     * ARCHOERA_STREAM_DISABLE=1：调试/对拍用，强制走旧路径（全速解码→文件播放）。 */
    if (e->player_file && !getenv("ARCHOERA_STREAM_DISABLE")) {
        streaming = mediaengine_stream_begin(e);
    }

    if (streaming) {
        code = mediaengine_stream_run(e);
    } else {
        /* ── 旧路径：全速解码 → 转码完成 → 文件播放器（无声设备/流不可用回退） ── */
        /* 转码主循环（全速；命令队列非阻塞消费） */
        for (;;) {
            if (QA_LOAD_ACQ(&e->stop_requested)) break;
            if (e->carry_pending) mediaengine_flush_carry(e);
            ssize_t n = pipeline_process(e->p);
            if (n < 0) {
                char err[160];
                snprintf(err, sizeof(err),
                    "{\"type\":\"error\",\"message\":\"pipeline error %zd\"}", (size_t)n);
                ev_enqueue(e, err);
                code = (int)n;
                break;
            }
            if (n == 0) break; /* EOF */

            char line[CMD_LINE + 1];
            while (cmd_dequeue(e, line, sizeof(line))) {
                handle_command(e, line);
            }
        }

        if (!QA_LOAD_ACQ(&e->stop_requested)) {
            int ret = pipeline_run(e->p); /* flush 残留 */
            if (ret < 0) {
                char err[160];
                snprintf(err, sizeof(err), "{\"type\":\"error\",\"message\":\"flush %d\"}", ret);
                ev_enqueue(e, err);
                code = ret;
            } else {
                ev_enqueue(e, "{\"type\":\"done\"}");
            }

            if (e->wav) wav_finalize(e); /* 转码完成，WAV 头回填后供播放器加载 */
            if (e->player_file && !QA_LOAD_ACQ(&e->stop_requested)) {
                fprintf(stderr, "[mediaengine] 播放器启动 sink=\"%s\" (env/上次选择；"
                        "播放原生适配见 [player] 日志)\n",
                        e->sink_id && e->sink_id[0] ? e->sink_id : "(系统默认)");
                player_start_options popts = PLAYER_START_OPTIONS_DEFAULT;
                e->player = player_start_opts(e->wav_file, e->sink_id,
                                                 &popts, player_event_cb, e);
                if (!e->player) {
                    ev_enqueue(e, "{\"type\":\"error\",\"message\":\"player start failed\"}");
                }
                /* 转码期间协商的位置事件间隔：播放器启动后立即应用 */
                if (e->player && e->pos_interval_ms > 0) {
                    player_set_position_interval(e->player, e->pos_interval_ms);
                }
                /* 转码期间记录的 seek 目标：播放器启动后立即应用
                   （player 已存在时 seek 命令在 handle_command 即时执行过） */
                if (e->player && e->seek_pending) {
                    e->seek_pending = 0;
                    player_command(e->player, "seek", &e->pending_seek_ms, NULL);
                }
                /* 播放循环（50ms 节拍；播放自然结束 / stop 退出） */
                while (!QA_LOAD_ACQ(&e->stop_requested)) {
                    if (e->player && player_poll(e->player)) {
                        break; /* 播放结束 */
                    }
                    char line[CMD_LINE + 1];
                    while (cmd_dequeue(e, line, sizeof(line))) {
                        handle_command(e, line);
                    }
                    struct timespec ts = {0, 50 * 1000000L};
                    nanosleep(&ts, NULL);
                }
                if (e->player) {
                    player_stop(e->player);
                    e->player = NULL;
                }
            }
        }
    }

    if (e->wav) { fclose(e->wav); e->wav = NULL; }
    if (e->pcm) { fclose(e->pcm); e->pcm = NULL; }
    mediaengine_discard_next(e); /* 丢弃未提交的暂存源（管线/缓冲） */
    if (e->p) { pipeline_destroy(e->p); e->p = NULL; }

mem_exit:
    /* 汇合点统一收尾。S1 池会话须先关流再停池：内存播放模式路径以 goto 直达此
     * 处、其上未销毁管线（非池会话保持既有行为不动），池会话在此补销毁，保证
     * native_decoder_close（→zk_engine_close）先于 native_decoder_pool_end
     * （→zk_engine_shutdown）。非池会话此处 e->p 已在上方销毁，恒为空操作。 */
    mediaengine_discard_next(e); /* 暂存源（若仍未提交）同样先于 pool_end 关闭 */
    if (pool_on && e->p) { pipeline_destroy(e->p); e->p = NULL; }
    char exited[64];
    snprintf(exited, sizeof(exited), "{\"type\":\"exited\",\"code\":%d}", code);
    ev_enqueue(e, exited);
    if (pool_on) native_decoder_pool_end();

    QA_STORE_REL(&e->done, 1);
    return NULL;
}

/* ── 公开 API ────────────────────────────────────────────────── */

/* create / create_store 共用实现：store 非空 → 内存源会话（source 置空，引擎
 * 线程 pipeline_create_store 解码）；store 空 → 磁盘/URL 源会话（create）。 */
static ArchoeraMediaEngine *mediaengine_create_impl(const char *source,
                                     SegStore *store,
                                     const EngineConfig *cfg,
                                     const char *player_file,
                                     const char *session_dir,
                                     char *errbuf, int errbuf_size)
{
    if ((!source && !store) || !session_dir) return NULL;

    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)calloc(1, sizeof(ArchoeraMediaEngine));
    if (!e) return NULL;

    e->store = store; /* 非空 = store 内存源会话；生命周期归调用方，destroy 不释放 */
    e->source = source ? strdup(source) : NULL;
    if (player_file) e->player_file = strdup(player_file);
    e->session_dir = strdup(session_dir);
    e->cfg = cfg ? *cfg : ENGINE_CONFIG_DEFAULT;
    if (e->player_file) {
        e->cfg.skip_encoder = true; /* 播放模式：仅 PCM 落盘，无 Opus 编码 */
    }
    e->session_offset_ms = e->cfg.start_offset_ms;
    e->p_start_ms = e->cfg.start_offset_ms;

    /* 内存播放模式：cfg.no_disk_cache=1 且为 player 会话 → mem_mode。
       cap 按配置解析：auto（0.8 GiB 硬上限）/ 用户上限 / 无上限（见 mem_resolve_cap）。 */
    if (e->player_file && e->cfg.no_disk_cache) {
        e->mem_mode = 1;
        e->mem_cap_bytes = mem_resolve_cap(e);
        fprintf(stderr,
                "[mediaengine] 内存播放模式（不落盘）：cap=%lld bytes (cfg=%lld KB)\n",
                (long long)e->mem_cap_bytes,
                (long long)e->cfg.pcm_mem_cap_kb);
    }

    size_t dl = strlen(session_dir);
    e->wav_file = (char *)malloc(dl + 16);
    e->pcm_file = (char *)malloc(dl + 16);
    snprintf(e->wav_file, dl + 16, "%s/stream.wav", session_dir);
    snprintf(e->pcm_file, dl + 16, "%s/stream.pcm", session_dir);

    pthread_mutex_init(&e->ev_mutex, NULL);
    pthread_mutex_init(&e->cmd_mutex, NULL);
    pthread_mutex_init(&e->mem_lock, NULL);
    pthread_mutex_init(&e->stage_lock, NULL);
    pthread_cond_init(&e->cmd_cond, NULL);
    pthread_cond_init(&e->ev_cond, NULL);
    pthread_cond_init(&e->ev_drain_cond, NULL);
    pthread_cond_init(&e->stage_cv, NULL);

    /* 播放输出 sink 初始选择：env ARCHOERA_AUDIO_SINK 显式覆盖 → 否则系统默认。
       仅播放模式有意义；后续 set_sink 命令会覆盖此值。 */
    {
        const char *env = getenv("ARCHOERA_AUDIO_SINK");
        e->sink_id = strdup((env && env[0]) ? env : "");
        e->sink_user_set = (env && env[0]) ? 1 : 0;
        e->last_volume = 1.0f;
        fprintf(stderr, "[mediaengine] 初始 sink=%s (%s)\n",
                e->sink_id && e->sink_id[0] ? e->sink_id : "(系统默认)",
                e->sink_user_set ? "env 显式指定" : "系统默认");
    }

    /* pipeline_create（avformat_open_input 网络 IO）移到引擎线程执行：
       create 立即返回，不占用 Dart isolate 线程（避免 VM 中断信号打断
       阻塞系统调用；详见 engine_thread 注释）。错误经 error 事件上报。 */
    if (pthread_create(&e->thread, NULL, engine_thread, e) != 0) {
        free(e->source);
        free(e->player_file);
        free(e->session_dir);
        free(e->wav_file);
        free(e->pcm_file);
        free(e->sink_id);
        pthread_mutex_destroy(&e->ev_mutex);
        pthread_mutex_destroy(&e->cmd_mutex);
        pthread_mutex_destroy(&e->mem_lock);
        pthread_mutex_destroy(&e->stage_lock);
        pthread_cond_destroy(&e->cmd_cond);
        pthread_cond_destroy(&e->ev_cond);
        pthread_cond_destroy(&e->ev_drain_cond);
        pthread_cond_destroy(&e->stage_cv);
        free(e);
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "pthread_create failed");
        }
        return NULL;
    }
    e->thread_created = 1;
    return e;
}

ArchoeraMediaEngine *archoera_mediaengine_create(const char *source,
                                     const EngineConfig *cfg,
                                     const char *player_file,
                                     const char *session_dir,
                                     char *errbuf, int errbuf_size)
{
    return mediaengine_create_impl(source, NULL, cfg, player_file, session_dir,
                                   errbuf, errbuf_size);
}

ArchoeraMediaEngine *archoera_mediaengine_create_store(SegStore *store,
                                     const EngineConfig *cfg,
                                     const char *player_file,
                                     const char *session_dir,
                                     char *errbuf, int errbuf_size)
{
    return mediaengine_create_impl(NULL, store, cfg, player_file, session_dir,
                                   errbuf, errbuf_size);
}

int archoera_mediaengine_command(ArchoeraMediaEngine *e, const char *json_line)
{
    if (!e || !json_line) return -1;
    return cmd_enqueue(e, json_line);
}

int archoera_mediaengine_poll_event(ArchoeraMediaEngine *e, char *buf, int cap)
{
    if (!e || !buf || cap <= 0) return 0;
    int r = 0;
    pthread_mutex_lock(&e->ev_mutex);
    if (e->ev_count > 0) {
        strncpy(buf, e->ev_buf[e->ev_head], cap - 1);
        buf[cap - 1] = '\0';
        e->ev_head = (e->ev_head + 1) % EV_CAP;
        e->ev_count--;
        r = 1;
    }
    pthread_mutex_unlock(&e->ev_mutex);
    return r;
}

/* ── wait_event（事件驱动阻塞等待）──────────────────────────────

   契约（与 Dart 事件泵对齐，见 engine-event-push-plan 第二步）：
     - 有事件：pop 一条写入 buf（'\0' 结尾），返回事件字节长度；
     - 无事件：在 ev_cond 上阻塞，等待 ev_enqueue 唤醒（条件变量，
       非忙轮询——空闲零唤醒、零 CPU）；
     - timeout_ms < 0：永久等待，直到事件或销毁；
     - timeout_ms >= 0：最多等该毫秒；超时返 0；
     - destroy 已开始（destroyed=1）：立即返 -1（唤醒等待者后返回）。
       销毁期间 wait_event **不再取事件**（先进先销毁语义：stop 后的
       残留在队列里的事件不再交付）。

   生命周期/并发：
     - waiters 统计当前在 wait_event 内的线程；destroy 置 destroyed=1 并
       broadcast 唤醒全部等待者后，等 waiters 归零（drain）才释放资源——
       保证阻塞中的调用方安全返回（-1），不触碰已释放内存；
     - wait_event 与 poll_event/ev_enqueue 共用 ev_mutex，互斥安全；
     - 同一 handle 建议单线程阻塞等待（Dart 事件泵即单接收 isolate），
       destroy 与 wait_event 可在不同线程并发调用。 */
int archoera_mediaengine_wait_event(ArchoeraMediaEngine *e, char *buf, int cap,
                                    int timeout_ms)
{
    if (!e || !buf || cap <= 0) return 0;

    int use_timeout = (timeout_ms >= 0);
    struct timespec deadline;
    if (use_timeout) {
        timespec_get(&deadline, TIME_UTC);
        deadline.tv_sec += timeout_ms / 1000;
        deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec += deadline.tv_nsec / 1000000000L;
            deadline.tv_nsec %= 1000000000L;
        }
    }

    int r = 0;
    pthread_mutex_lock(&e->ev_mutex);
    e->waiters++;
    for (;;) {
        if (e->destroyed) { /* 销毁已开始：唤醒即退出，不再交付事件 */
            r = -1;
            break;
        }
        if (e->ev_count > 0) {
            int len = (int)strlen(e->ev_buf[e->ev_head]);
            if (len > cap - 1) len = cap - 1;
            memcpy(buf, e->ev_buf[e->ev_head], (size_t)len);
            buf[len] = '\0';
            e->ev_head = (e->ev_head + 1) % EV_CAP;
            e->ev_count--;
            r = len;
            break;
        }
        if (use_timeout) {
            struct timespec now;
            timespec_get(&now, TIME_UTC);
            if (now.tv_sec > deadline.tv_sec ||
                (now.tv_sec == deadline.tv_sec &&
                 now.tv_nsec >= deadline.tv_nsec)) {
                r = 0; /* 超时无事件 */
                break;
            }
            pthread_cond_timedwait(&e->ev_cond, &e->ev_mutex, &deadline);
        } else {
            pthread_cond_wait(&e->ev_cond, &e->ev_mutex);
        }
    }
    e->waiters--;
    if (e->waiters == 0) {
        pthread_cond_signal(&e->ev_drain_cond); /* 通知 destroy drain 可继续 */
    }
    pthread_mutex_unlock(&e->ev_mutex);
    return r;
}

const char *archoera_mediaengine_session_dir(ArchoeraMediaEngine *e)
{
    return e ? e->session_dir : NULL;
}

int archoera_mediaengine_is_done(ArchoeraMediaEngine *e)
{
    return e ? (int)QA_LOAD_ACQ(&e->done) : 1;
}

/* 内存播放模式：以 end_pos_ms 为终点取最近 frames 样本（L/R）写 out_l/out_r。
 * 返回 0 命中；-1 越出保留窗 / 尚未解码；-2 参数错或非内存模式会话。
 * 语义对齐 PcmAnalyzer.frameAt（前缀补零仅在头部仍在时；被淘汰返回 -1）。 */
int archoera_mediaengine_pcm_window(ArchoeraMediaEngine *e, int end_pos_ms,
                                    int frames, float *out_l, float *out_r)
{
    int r;
    if (!e) return -2;
    /* 与引擎解码线程的 mem_append/reset 互斥；mem_window 持锁期间只做纯计算
     * 与（至多 frames 样本的）结果拷贝，不做任何回调/重入。 */
    pthread_mutex_lock(&e->mem_lock);
    r = mem_window(e, end_pos_ms, frames, out_l, out_r);
    pthread_mutex_unlock(&e->mem_lock);
    return r;
}

/* 会话重建计数（seek 重建即 +1）：Dart 凭此丢弃旧帧索引（对齐文件截断语义）。 */
int archoera_mediaengine_pcm_epoch(ArchoeraMediaEngine *e)
{
    int epoch;
    if (!e) return -1;
    pthread_mutex_lock(&e->mem_lock);
    epoch = e->mem_epoch;
    pthread_mutex_unlock(&e->mem_lock);
    return epoch;
}

/* M3（§6.2/§6.1）：当前可用内存（MB），供 Dart 预算管理器算 auto ceiling/
 * requiredCeiling。失败返回 -1（调用方回落保守下限）。 */
long long archoera_mediaengine_mem_available_mb(void)
{
    return mem_avail_mb();
}

void archoera_mediaengine_destroy(ArchoeraMediaEngine *e)
{
    if (!e) return;

    /* 1) 置销毁标志并唤醒全部阻塞中的 wait_event（立即返 -1）。
        先于 join：阻塞的接收线程尽快退场，不被慢 join（网络 IO 中断）拖住。 */
    QA_STORE_REL(&e->stop_requested, 1);
    if (e->p) {
        pipeline_signal_shutdown(e->p); /* 转码中 → 优雅中断退出 */
    }
    pthread_mutex_lock(&e->ev_mutex);
    e->destroyed = 1;
    pthread_cond_broadcast(&e->ev_cond);
    pthread_mutex_unlock(&e->ev_mutex);

    /* 2) join 引擎线程（网络/解码中断下数百 ms 内返回） */
    if (e->thread_created) {
        pthread_join(e->thread, NULL);
        e->thread_created = 0;
    }

    /* 2.5) 引擎线程已退出：防御性丢弃暂存源（正常路径已在其收尾处释放，
       此处兜底 pthread 提前返回等异常，确保无泄漏/UAF）。 */
    mediaengine_discard_next(e);

    /* 3) drain：等仍在 wait_event 内的线程退出（看到 destroyed → -1 后
        自行归还）。有界等待作防御兜底——正常 wait_event 见 destroyed 即
        立即返回，此处只差一个调度周期。 */
    pthread_mutex_lock(&e->ev_mutex);
    if (e->waiters > 0) {
        struct timespec dl;
        timespec_get(&dl, TIME_UTC);
        dl.tv_sec += 2;
        while (e->waiters > 0) {
            pthread_cond_timedwait(&e->ev_drain_cond, &e->ev_mutex, &dl);
            struct timespec now;
            timespec_get(&now, TIME_UTC);
            if (now.tv_sec > dl.tv_sec ||
                (now.tv_sec == dl.tv_sec && now.tv_nsec >= dl.tv_nsec)) {
                break; /* 防御超时：异常调用方不归还也不永久挂 destroy */
            }
        }
    }
    pthread_mutex_unlock(&e->ev_mutex);

    mem_free(e); /* 内存播放模式的块列表（自持 mem_lock） */

    free(e->source);
    free(e->player_file);
    free(e->session_dir);
    free(e->wav_file);
    free(e->pcm_file);
    free(e->sink_id);
    pthread_mutex_destroy(&e->mem_lock);
    pthread_mutex_destroy(&e->ev_mutex);
    pthread_mutex_destroy(&e->cmd_mutex);
    pthread_mutex_destroy(&e->stage_lock);
    pthread_cond_destroy(&e->cmd_cond);
    pthread_cond_destroy(&e->ev_cond);
    pthread_cond_destroy(&e->ev_drain_cond);
    pthread_cond_destroy(&e->stage_cv);
    free(e);
}


/* sink 分类由 audio_output 模块的平台 provider 给出（player_sink_info.cls），
   经 player_sink_class_str 转稳定字符串；旧名称启发式已迁入 audio_output_platform.c。 */

int archoera_mediaengine_list_sinks(char *buf, int cap)
{
    player_sink_info *infos;
    char *jbuf;
    size_t used = 0, jcap;
    int n, i, ret = -1;

    if (!buf || cap <= 0) return -1;

    /* 枚举（自建/拆 context）：数量上限 64，防极端多 sink 撑爆栈 */
    infos = (player_sink_info *)calloc(64, sizeof(*infos));
    if (!infos) return -1;
    n = player_list_sinks(infos, 64);
    if (n <= 0) {
        free(infos);
        return 0; /* 无设备：返回 0（≤0 语义），不写 buf */
    }

    /* 动态构建 JSON：逐项拼接转义后的 id/name */
    jcap = (size_t)cap > 0 ? (size_t)cap : 1;
    if ((size_t)cap < 256) jcap = 256; /* 至少容纳几项再判定溢出 */
    jbuf = (char *)malloc(jcap + 1);
    if (!jbuf) { free(infos); return -1; }
    jbuf[0] = '[';
    used = 1;
    for (i = 0; i < n; ++i) {
        char eid[PLAYER_SINK_ID_CAP * 2 + 8];
        char ename[PLAYER_SINK_ID_CAP * 2 + 8];
        char edesc[PLAYER_SINK_ID_CAP * 2 + 8];
        char item[PLAYER_SINK_ID_CAP * 8 + 192];
        json_escape_str(infos[i].id, eid, sizeof(eid));
        json_escape_str(infos[i].name, ename, sizeof(ename));
        json_escape_str(infos[i].description, edesc, sizeof(edesc));
        const char *cls = player_sink_class_str(infos[i].cls);
        snprintf(item, sizeof(item),
                 "%s{\"id\":\"%s\",\"name\":\"%s\",\"description\":\"%s\","
                 "\"rate\":%u,\"channels\":%u,\"default\":%s,"
                 "\"flags\":%u,\"class\":\"%s\"}",
                 i ? "," : "", eid, ename, edesc,
                 infos[i].sample_rate, infos[i].channels,
                 infos[i].is_default ? "true" : "false",
                 infos[i].flags, cls);
        size_t ilen = strlen(item);
        if (used + ilen + 2 > (size_t)cap) {
            /* 缓冲区不足：写不下完整数组 → 失败（调用方加大 cap 重试） */
            free(jbuf);
            free(infos);
            return -1;
        }
        memcpy(jbuf + used, item, ilen);
        used += ilen;
    }
    if (used + 1 >= (size_t)cap) { /* 结尾 ] 放不下 */
        free(jbuf);
        free(infos);
        return -1;
    }
    jbuf[used++] = ']';
    memcpy(buf, jbuf, used);
    buf[used] = '\0';
    ret = (int)used;

    free(jbuf);
    free(infos);
    return ret;
}

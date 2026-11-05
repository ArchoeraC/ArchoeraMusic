// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_service.c — 频谱 v2 引擎侧推送服务（docs/spectrum-analyzer.md §5）
 *
 * 线程模型：
 *   - create 只分配服务壳 + 输入/输出缓冲，不建分析器、不建线程；
 *   - start 首次创建分析器（懒初始化）并启动独立线程；
 *   - 线程每 interval_ms 读一次「已播放位置」窗口 → era_dsp_spectrum_process
 *     → emit（可丢）；
 *   - stop 置停止标志，10ms 分片 sleep，join 在 ~10ms 内返回；
 *   - 不占用解码 worker 池、不在音频回调做 FFT、零每帧分配。
 *
 * 分析器后端由 spectrum_dsp.c 在编译期选择（Zig VQT / FFmpeg FFT），本文件
 * 不感知；两种后端输出同一契约。
 */
#define _DEFAULT_SOURCE
#include "spectrum_service.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "compat/qatomic.h"
#include "era_log.h"
#include "spectrum_dsp.h"

#define LOG_TAG "[audio-engine:spectrum]"

struct EraSpectrumService {
    EraSpectrumServiceConfig cfg;
    int frames;
    int bins;
    int interval_ms;

    EraDspSpectrum *spectrum;

    /* 复用的取窗/输出缓冲（create 时一次性分配，线程内零分配）。 */
    float *l;
    float *r;
    float *out_l;
    float *out_r;
    float *peak_l;
    float *peak_r;

    pthread_t thread;
    pthread_mutex_t lock; /* 保护 spectrum 配置/状态（set_* vs 分析线程） */
    qa_size stop;   /* 0 = 运行，1 = 停止（跨线程标志） */
    int running;
    int seq;
    int last_pos;   /* 上一帧绝对位置（ms）；回退 >200ms 视为 seek → reset */
};

/* 10ms 分片 sleep：stop 检查足够密，join 不会卡满一个推送周期。 */
static void era_spectrum_sleep_ms(int ms)
{
    struct timespec ts;
    if (ms <= 0) return;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static void *era_spectrum_thread(void *arg)
{
    EraSpectrumService *s = (EraSpectrumService *)arg;

    while (!QA_LOAD_ACQ(&s->stop)) {
        const int pos = s->cfg.position ? s->cfg.position(s->cfg.ctx) : -1;
        if (pos >= 0) {
            /* 位置跳变（seek / 切歌 / 会话重建）：清空频谱通量状态，避免
               旧帧与新位置混在一起产生假节拍/拖尾。 */
            pthread_mutex_lock(&s->lock);
            if (s->last_pos >= 0) {
                const int delta = pos - s->last_pos;
                if (delta < -200 || delta > 1000) {
                    era_dsp_spectrum_reset(s->spectrum);
                }
            }
            s->last_pos = pos;
            pthread_mutex_unlock(&s->lock);
            const int future = s->cfg.future_samples;
            int read_pos = pos;
            if (future > 0) {
                read_pos = pos + (int)(((int64_t)future * 1000
                                        + s->cfg.sample_rate / 2)
                                       / s->cfg.sample_rate);
            }
            int rc = s->cfg.read(s->cfg.ctx, read_pos, s->frames,
                                 s->l, s->r);
            int used_future = future;
            if (rc != 0 && future > 0) {
                /* 源还没解码到未来位置（启动/欠载）：退回因果窗口。 */
                used_future = 0;
                rc = s->cfg.read(s->cfg.ctx, pos, s->frames, s->l, s->r);
            }
            if (rc == 0) {
                pthread_mutex_lock(&s->lock);
                const float beat = era_dsp_spectrum_process_centered(
                    s->spectrum, s->l, s->r, s->frames, used_future,
                    s->out_l, s->out_r);
                era_dsp_spectrum_peaks(s->spectrum, s->peak_l, s->peak_r);
                pthread_mutex_unlock(&s->lock);
                if (s->cfg.emit) {
                    s->cfg.emit(s->cfg.ctx, s->out_l, s->out_r,
                                s->peak_l, s->peak_r, s->bins,
                                beat, s->seq++, s->interval_ms);
                }
            }
        }

        int remain = s->interval_ms;
        while (remain > 0 && !QA_LOAD_ACQ(&s->stop)) {
            const int step = remain > 10 ? 10 : remain;
            era_spectrum_sleep_ms(step);
            remain -= step;
        }
    }
    return NULL;
}

EraSpectrumService *era_spectrum_service_create(
    const EraSpectrumServiceConfig *cfg)
{
    EraSpectrumService *s;

    if (!cfg || !cfg->read || !cfg->position || !cfg->emit) return NULL;
    if (cfg->sample_rate <= 0 || cfg->bins <= 0 || cfg->bins > 1024) return NULL;
    if (cfg->min_hz <= 0.0f || cfg->max_hz <= cfg->min_hz) return NULL;
    if (cfg->max_hz >= (float)cfg->sample_rate * 0.5f) return NULL;

    s = (EraSpectrumService *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    pthread_mutex_init(&s->lock, NULL);

    s->cfg = *cfg;
    s->frames = cfg->frames > 0 ? cfg->frames : 12288;
    if (s->frames > 16384) s->frames = 16384;
    if (s->cfg.future_samples < 0) s->cfg.future_samples = 0;
    if (s->cfg.future_samples > s->frames / 2) {
        s->cfg.future_samples = s->frames / 2;
    }
    s->bins = cfg->bins;
    s->interval_ms = cfg->interval_ms > 0 ? cfg->interval_ms : 50;
    s->last_pos = -1;
    QA_STORE_REL(&s->stop, 1);

    s->l = (float *)malloc((size_t)s->frames * sizeof(float));
    s->r = (float *)malloc((size_t)s->frames * sizeof(float));
    s->out_l = (float *)malloc((size_t)s->bins * sizeof(float));
    s->out_r = (float *)malloc((size_t)s->bins * sizeof(float));
    s->peak_l = (float *)malloc((size_t)s->bins * sizeof(float));
    s->peak_r = (float *)malloc((size_t)s->bins * sizeof(float));
    if (!s->l || !s->r || !s->out_l || !s->out_r ||
        !s->peak_l || !s->peak_r) {
        era_spectrum_service_destroy(s);
        return NULL;
    }
    return s;
}

int era_spectrum_service_start(EraSpectrumService *s)
{
    if (!s) return -1;
    if (s->running) return 0;

    if (!s->spectrum) {
        s->spectrum = era_dsp_spectrum_create(
            s->cfg.sample_rate, s->bins, s->cfg.min_hz, s->cfg.max_hz);
        if (!s->spectrum) {
            ERA_LOGE(NULL, "%s 分析器创建失败（rate=%d bins=%d %.0f–%.0fHz）\n",
                     LOG_TAG, s->cfg.sample_rate, s->bins,
                     (double)s->cfg.min_hz, (double)s->cfg.max_hz);
            return -1;
        }
    }

    QA_STORE_REL(&s->stop, 0);
    if (pthread_create(&s->thread, NULL, era_spectrum_thread, s) != 0) {
        QA_STORE_REL(&s->stop, 1);
        ERA_LOGE(NULL, "%s 线程创建失败\n", LOG_TAG);
        return -1;
    }
    s->running = 1;
    ERA_LOGI(NULL, "%s 已启动：%dHz / %d bins / %dms / %d 样本窗 / %s\n",
             LOG_TAG, s->cfg.sample_rate, s->bins, s->interval_ms, s->frames,
             era_dsp_spectrum_backend());
    return 0;
}

void era_spectrum_service_stop(EraSpectrumService *s)
{
    if (!s || !s->running) return;
    QA_STORE_REL(&s->stop, 1);
    pthread_join(s->thread, NULL);
    s->running = 0;
    /* 暂停/关闭后再启用：清空通量/节拍历史，避免旧帧在恢复首帧误触发。 */
    if (s->spectrum) era_dsp_spectrum_reset(s->spectrum);
    s->last_pos = -1;
}

void era_spectrum_service_reset(EraSpectrumService *s)
{
    if (!s || !s->spectrum) return;
    pthread_mutex_lock(&s->lock);
    era_dsp_spectrum_reset(s->spectrum);
    s->last_pos = -1;
    pthread_mutex_unlock(&s->lock);
}

void era_spectrum_service_set_peak_hold(EraSpectrumService *s, bool enabled)
{
    if (!s || !s->spectrum) return;
    pthread_mutex_lock(&s->lock);
    era_dsp_spectrum_set_peak_hold(s->spectrum, enabled);
    pthread_mutex_unlock(&s->lock);
}

void era_spectrum_service_set_agc(EraSpectrumService *s, bool enabled)
{
    if (!s || !s->spectrum) return;
    pthread_mutex_lock(&s->lock);
    era_dsp_spectrum_set_agc(s->spectrum, enabled);
    pthread_mutex_unlock(&s->lock);
}

void era_spectrum_service_set_gamma(EraSpectrumService *s, float gamma)
{
    if (!s || !s->spectrum) return;
    pthread_mutex_lock(&s->lock);
    era_dsp_spectrum_set_gamma(s->spectrum, gamma);
    pthread_mutex_unlock(&s->lock);
}

void era_spectrum_service_set_tilt(EraSpectrumService *s, float db_per_oct)
{
    if (!s || !s->spectrum) return;
    pthread_mutex_lock(&s->lock);
    era_dsp_spectrum_set_tilt(s->spectrum, db_per_oct);
    pthread_mutex_unlock(&s->lock);
}

bool era_spectrum_service_is_running(const EraSpectrumService *s)
{
    return s && s->running;
}

void era_spectrum_service_destroy(EraSpectrumService *s)
{
    if (!s) return;
    era_spectrum_service_stop(s);
    if (s->spectrum) {
        era_dsp_spectrum_destroy(s->spectrum);
        s->spectrum = NULL;
    }
    free(s->l);
    free(s->r);
    free(s->out_l);
    free(s->out_r);
    free(s->peak_l);
    free(s->peak_r);
    pthread_mutex_destroy(&s->lock);
    free(s);
}

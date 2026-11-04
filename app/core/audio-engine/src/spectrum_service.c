// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_service.c — 频谱 v2 引擎侧推送服务（docs/spectrum-analyzer.md §5）
 *
 * 线程模型：
 *   - create 只分配服务壳 + 输入/输出缓冲，不建 FFT 表、不建线程；
 *   - start 首次创建内核分析器（懒初始化）并启动独立线程；
 *   - 线程每 interval_ms 读一次「已播放位置」窗口 → zk_dsp_spectrum_process
 *     → emit（可丢）；
 *   - stop 置停止标志，10ms 分片 sleep，join 在 ~10ms 内返回；
 *   - 不占用解码 worker 池、不在音频回调做 FFT、零每帧分配。
 */
#define _DEFAULT_SOURCE
#include "spectrum_service.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "compat/qatomic.h"
#include "era_log.h"

#if defined(HAS_ARCHOERA_KERNEL)
#include "kernel_bridge.h"
#endif

#define LOG_TAG "[audio-engine:spectrum]"

struct EraSpectrumService {
    EraSpectrumServiceConfig cfg;
    int frames;
    int bins;
    int interval_ms;

#if defined(HAS_ARCHOERA_KERNEL)
    ZkSpectrum *spectrum;
#endif

    /* 复用的取窗/输出缓冲（create 时一次性分配，线程内零分配）。 */
    float *l;
    float *r;
    float *out_l;
    float *out_r;

    pthread_t thread;
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

#if defined(HAS_ARCHOERA_KERNEL)
static void *era_spectrum_thread(void *arg)
{
    EraSpectrumService *s = (EraSpectrumService *)arg;

    while (!QA_LOAD_ACQ(&s->stop)) {
        const int pos = s->cfg.position ? s->cfg.position(s->cfg.ctx) : -1;
        if (pos >= 0) {
            /* 位置跳变（seek / 切歌 / 会话重建）：清空频谱通量状态，避免
               旧帧与新位置混在一起产生假节拍/拖尾。 */
            if (s->last_pos >= 0) {
                const int delta = pos - s->last_pos;
                if (delta < -200 || delta > 1000) {
                    zk_dsp_spectrum_reset(s->spectrum);
                }
            }
            s->last_pos = pos;
            const int rc = s->cfg.read(s->cfg.ctx, pos, s->frames,
                                       s->l, s->r);
            if (rc == 0) {
                const float beat = zk_dsp_spectrum_process(
                    s->spectrum, s->l, s->r, s->frames,
                    s->out_l, s->out_r);
                if (s->cfg.emit) {
                    s->cfg.emit(s->cfg.ctx, s->out_l, s->out_r, s->bins,
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
#endif

EraSpectrumService *era_spectrum_service_create(
    const EraSpectrumServiceConfig *cfg)
{
#if !defined(HAS_ARCHOERA_KERNEL)
    (void)cfg;
    return NULL;
#else
    EraSpectrumService *s;

    if (!cfg || !cfg->read || !cfg->position || !cfg->emit) return NULL;
    if (cfg->sample_rate <= 0 || cfg->bins <= 0 || cfg->bins > 1024) return NULL;
    if (cfg->min_hz <= 0.0f || cfg->max_hz <= cfg->min_hz) return NULL;
    if (cfg->max_hz >= (float)cfg->sample_rate * 0.5f) return NULL;

    s = (EraSpectrumService *)calloc(1, sizeof(*s));
    if (!s) return NULL;

    s->cfg = *cfg;
    s->frames = cfg->frames > 0 ? cfg->frames : 8192;
    if (s->frames > 8192) s->frames = 8192;
    s->bins = cfg->bins;
    s->interval_ms = cfg->interval_ms > 0 ? cfg->interval_ms : 50;
    s->last_pos = -1;
    QA_STORE_REL(&s->stop, 1);

    s->l = (float *)malloc((size_t)s->frames * sizeof(float));
    s->r = (float *)malloc((size_t)s->frames * sizeof(float));
    s->out_l = (float *)malloc((size_t)s->bins * sizeof(float));
    s->out_r = (float *)malloc((size_t)s->bins * sizeof(float));
    if (!s->l || !s->r || !s->out_l || !s->out_r) {
        era_spectrum_service_destroy(s);
        return NULL;
    }
    return s;
#endif
}

int era_spectrum_service_start(EraSpectrumService *s)
{
#if !defined(HAS_ARCHOERA_KERNEL)
    (void)s;
    return -1;
#else
    if (!s) return -1;
    if (s->running) return 0;

    if (!s->spectrum) {
        s->spectrum = zk_dsp_spectrum_create(
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
    ERA_LOGI(NULL, "%s 已启动：%dHz / %d bins / %dms / %d 样本窗\n",
             LOG_TAG, s->cfg.sample_rate, s->bins, s->interval_ms, s->frames);
    return 0;
#endif
}

void era_spectrum_service_stop(EraSpectrumService *s)
{
#if defined(HAS_ARCHOERA_KERNEL)
    if (!s || !s->running) return;
    QA_STORE_REL(&s->stop, 1);
    pthread_join(s->thread, NULL);
    s->running = 0;
    /* 暂停/关闭后再启用：清空通量/节拍历史，避免旧帧在恢复首帧误触发。 */
    if (s->spectrum) zk_dsp_spectrum_reset(s->spectrum);
    s->last_pos = -1;
#else
    (void)s;
#endif
}

void era_spectrum_service_reset(EraSpectrumService *s)
{
#if defined(HAS_ARCHOERA_KERNEL)
    if (!s || !s->spectrum) return;
    zk_dsp_spectrum_reset(s->spectrum);
    s->last_pos = -1;
#else
    (void)s;
#endif
}

bool era_spectrum_service_is_running(const EraSpectrumService *s)
{
    return s && s->running;
}

void era_spectrum_service_destroy(EraSpectrumService *s)
{
#if defined(HAS_ARCHOERA_KERNEL)
    if (!s) return;
    era_spectrum_service_stop(s);
    if (s->spectrum) {
        zk_dsp_spectrum_destroy(s->spectrum);
        s->spectrum = NULL;
    }
    free(s->l);
    free(s->r);
    free(s->out_l);
    free(s->out_r);
    free(s);
#else
    (void)s;
#endif
}

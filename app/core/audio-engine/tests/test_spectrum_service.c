// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_spectrum_service.c — 频谱 v2 引擎侧推送服务（headless）
 *
 * 验证：
 *   - 非法配置拒绝创建；
 *   - start 后独立线程按 50ms 推送 128 带事件，440Hz 正弦峰值带正确；
 *   - l/r 值域 [0,1]、beat 有限、seq 单调；
 *   - stop 在 ~10ms 分片内快速返回，可重复 start/stop；
 *   - reset / destroy 不崩溃。
 *
 * 不依赖音频设备、不依赖文件；read 回调现场生成 440Hz 正弦。
 */
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "spectrum_service.h"

#define TEST_SR 48000
#define TEST_FRAMES 12288
#define TEST_BINS 128
#define TEST_FREQ 440.0
#define TEST_PI 3.14159265358979323846

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t cv;
    int frames;
    int seq_last;
    int interval_ms;
    int peak_l;
    int peak_r;
    float beat_last;
    float min_l;
    float max_l;
    float min_r;
    float max_r;
    int bad_value;
} TestSink;

static int g_fail;
static int g_last_read_end = -1;

static void check(int cond, const char *what)
{
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_fail = 1;
    }
}

static int test_read(void *ctx, int end_pos_ms, int frames,
                     float *out_l, float *out_r)
{
    int i;
    (void)ctx;
    g_last_read_end = end_pos_ms;
    if (!out_l || !out_r || frames <= 0) return -2;
    for (i = 0; i < frames; i++) {
        const float v = (float)sin(2.0 * TEST_PI * TEST_FREQ * (double)i / TEST_SR);
        out_l[i] = v;
        out_r[i] = v;
    }
    return 0;
}

static int test_position(void *ctx)
{
    (void)ctx;
    return 1000; /* 固定播放位置；窗口内容由 read 提供 */
}

static void test_emit(void *ctx, const float *l, const float *r,
                      const float *pl, const float *pr,
                      int bins, float beat, int seq, int interval_ms)
{
    TestSink *s = (TestSink *)ctx;
    int i;
    int peak_l = 0, peak_r = 0;
    float min_l = 1.0f, max_l = 0.0f, min_r = 1.0f, max_r = 0.0f;
    int bad = 0;

    for (i = 0; i < bins; i++) {
        if (!isfinite(l[i]) || !isfinite(r[i]) ||
            !isfinite(pl[i]) || !isfinite(pr[i]) ||
            l[i] < 0.0f || l[i] > 1.0f || r[i] < 0.0f || r[i] > 1.0f ||
            pl[i] < 0.0f || pl[i] > 1.0f || pr[i] < 0.0f || pr[i] > 1.0f) {
            bad = 1;
        }
        if (l[i] < min_l) min_l = l[i];
        if (l[i] > max_l) max_l = l[i];
        if (r[i] < min_r) min_r = r[i];
        if (r[i] > max_r) max_r = r[i];
        if (l[i] > l[peak_l]) peak_l = i;
        if (r[i] > r[peak_r]) peak_r = i;
    }
    if (!isfinite(beat) || beat < 0.0f || beat > 1.0f) bad = 1;

    pthread_mutex_lock(&s->lock);
    s->frames++;
    s->seq_last = seq;
    s->interval_ms = interval_ms;
    s->peak_l = peak_l;
    s->peak_r = peak_r;
    s->beat_last = beat;
    s->min_l = min_l;
    s->max_l = max_l;
    s->min_r = min_r;
    s->max_r = max_r;
    if (bad) s->bad_value = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->lock);
}

static int wait_frames(TestSink *s, int want, int timeout_ms)
{
    struct timespec deadline;
    int ok;
    timespec_get(&deadline, TIME_UTC);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += deadline.tv_nsec / 1000000000L;
        deadline.tv_nsec %= 1000000000L;
    }
    pthread_mutex_lock(&s->lock);
    while (s->frames < want) {
        if (pthread_cond_timedwait(&s->cv, &s->lock, &deadline) != 0) break;
    }
    ok = s->frames >= want;
    pthread_mutex_unlock(&s->lock);
    return ok;
}

static long long now_ms(void)
{
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(void)
{
    TestSink sink;
    TestSink sink2;
    EraSpectrumServiceConfig cfg;
    EraSpectrumService *svc;
    int expected_band;
    long long t0, elapsed;

    memset(&sink, 0, sizeof(sink));
    pthread_mutex_init(&sink.lock, NULL);
    pthread_cond_init(&sink.cv, NULL);
    memset(&sink2, 0, sizeof(sink2));
    pthread_mutex_init(&sink2.lock, NULL);
    pthread_cond_init(&sink2.cv, NULL);

    /* 非法配置：缺回调 / 非法频段。 */
    memset(&cfg, 0, sizeof(cfg));
    cfg.sample_rate = TEST_SR;
    cfg.bins = TEST_BINS;
    cfg.min_hz = 40.0f;
    cfg.max_hz = 16000.0f;
    check(era_spectrum_service_create(&cfg) == NULL, "缺回调应拒绝创建");
    cfg.read = test_read;
    cfg.position = test_position;
    cfg.emit = test_emit;
    cfg.ctx = &sink;
    cfg.max_hz = 30000.0f; /* > Nyquist */
    check(era_spectrum_service_create(&cfg) == NULL, "max_hz 超 Nyquist 应拒绝");

    cfg.max_hz = 16000.0f;
    cfg.frames = TEST_FRAMES;
    svc = era_spectrum_service_create(&cfg);
    check(svc != NULL, "合法配置应创建服务");
    if (!svc) {
        pthread_mutex_destroy(&sink.lock);
        pthread_cond_destroy(&sink.cv);
        return 1;
    }
    check(!era_spectrum_service_is_running(svc), "create 后不应运行");

    check(era_spectrum_service_start(svc) == 0, "start 应成功");
    check(era_spectrum_service_is_running(svc), "start 后应运行");

    check(wait_frames(&sink, 3, 3000), "3 秒内应收到至少 3 帧频谱");
    pthread_mutex_lock(&sink.lock);
    check(sink.bad_value == 0, "频带/节拍值域应为 [0,1] 且有限");
    check(sink.interval_ms == 50, "默认推送间隔应为 50ms");
    check(sink.seq_last >= 2, "seq 应单调递增");
    /* 440Hz 在 40–16000Hz 对数轴上的期望带（128 带）。 */
    expected_band = (int)lround(
        (double)TEST_BINS * log(TEST_FREQ / 40.0) / log(16000.0 / 40.0));
    check(abs(sink.peak_l - expected_band) <= 3,
          "左声道峰值带应接近 440Hz 对应带");
    check(abs(sink.peak_r - expected_band) <= 3,
          "右声道峰值带应接近 440Hz 对应带");
    check(sink.max_l > 0.3f && sink.max_r > 0.3f,
          "0dBFS 正弦峰值应明显高于底噪");
    pthread_mutex_unlock(&sink.lock);

    /* stop 应快速返回（10ms 分片 + join）。 */
    t0 = now_ms();
    era_spectrum_service_stop(svc);
    elapsed = now_ms() - t0;
    check(!era_spectrum_service_is_running(svc), "stop 后不应运行");
    check(elapsed < 500, "stop 应在 500ms 内返回");

    /* reset / 重启幂等。 */
    era_spectrum_service_reset(svc);
    check(era_spectrum_service_start(svc) == 0, "重复 start 应成功");
    check(wait_frames(&sink, 4, 3000), "重启后应继续推送");
    era_spectrum_service_stop(svc);
    era_spectrum_service_stop(svc); /* 幂等 */

    era_spectrum_service_destroy(svc);

    /* 居中窗口：future_samples 应让 read 的 end_pos 前移 half window
       （6144 @48k = 128ms），从而把长窗中心对准当前播放位置。 */
    cfg.future_samples = TEST_FRAMES / 2;
    cfg.ctx = &sink2;
    g_last_read_end = -1;
    svc = era_spectrum_service_create(&cfg);
    check(svc != NULL, "居中窗口服务应创建");
    if (svc) {
        check(era_spectrum_service_start(svc) == 0, "居中窗口服务应启动");
        check(wait_frames(&sink2, 1, 3000), "居中窗口应推送至少 1 帧");
        check(g_last_read_end == 1000 + 128,
              "居中窗口应读取未来 128ms（1000 → 1128）");
        era_spectrum_service_stop(svc);
        era_spectrum_service_destroy(svc);
    }

    pthread_mutex_destroy(&sink.lock);
    pthread_cond_destroy(&sink.cv);
    pthread_mutex_destroy(&sink2.lock);
    pthread_cond_destroy(&sink2.cv);

    if (g_fail) {
        fprintf(stderr, "test_spectrum_service: FAILED\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}

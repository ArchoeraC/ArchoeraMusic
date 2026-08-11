/**
 * tempo.c — 变速变调处理器（C FFI 调用 Rust audio-tempo）
 *
 * 当 HAS_TEMPO 未定义时（无 Rust/cargo），提供 stub 实现，tempo 始终 bypass。
 */
#include "tempo.h"

#include <stdlib.h>

#define LOG_TAG "[audio-engine:tempo]"
#include <stdio.h>

#ifdef HAS_TEMPO

#include <string.h>

/* Rust FFI 声明（内部使用，不导出） */
extern void* rs_tempo_create(int sample_rate, int channels);
extern void  rs_tempo_destroy(void *handle);
extern void  rs_tempo_reset(void *handle);
extern void  rs_tempo_set_enabled(void *handle, bool enabled);
extern void  rs_tempo_set_speed(void *handle, float speed);
extern void  rs_tempo_set_pitch(void *handle, float semitones);
extern void  rs_tempo_set_pitch_sync(void *handle, bool sync);
extern int   rs_tempo_process(void *handle, const float *input, int input_samples,
                               float *output, int output_capacity);

struct Tempo {
    void  *handle;
    int    sample_rate;
    int    channels;
    float  speed;
    float  pitch;
    bool   pitch_sync;
    bool   enabled;

    float *tmp_out;
    int    tmp_capacity;
};

Tempo* tempo_create(int sample_rate, int channels)
{
    Tempo *t = calloc(1, sizeof(*t));
    if (!t) return NULL;

    t->handle = rs_tempo_create(sample_rate, channels);
    if (!t->handle) {
        free(t);
        return NULL;
    }

    t->sample_rate = sample_rate;
    t->channels = channels;
    t->speed = 1.0f;
    t->pitch = 0.0f;
    t->pitch_sync = true;
    t->enabled = true;

    t->tmp_capacity = 8192;
    t->tmp_out = malloc(t->tmp_capacity * channels * sizeof(float));
    if (!t->tmp_out) {
        rs_tempo_destroy(t->handle);
        free(t);
        return NULL;
    }

    fprintf(stderr, "%s 创建: %dHz / %dch (signalsmith-stretch)\n", LOG_TAG, sample_rate, channels);
    return t;
}

void tempo_destroy(Tempo *t)
{
    if (!t) return;
    if (t->handle) rs_tempo_destroy(t->handle);
    if (t->tmp_out) free(t->tmp_out);
    free(t);
}

void tempo_reset(Tempo *t)
{
    if (t && t->handle) rs_tempo_reset(t->handle);
}

void tempo_set_enabled(Tempo *t, bool enabled)
{
    if (!t) return;
    t->enabled = enabled;
    rs_tempo_set_enabled(t->handle, enabled);
}

void tempo_set_speed(Tempo *t, float speed)
{
    if (!t) return;
    t->speed = speed;
    rs_tempo_set_speed(t->handle, speed);
}

void tempo_set_pitch(Tempo *t, float semitones)
{
    if (!t) return;
    t->pitch = semitones;
    rs_tempo_set_pitch(t->handle, semitones);
}

void tempo_set_pitch_sync(Tempo *t, bool sync)
{
    if (!t) return;
    t->pitch_sync = sync;
    rs_tempo_set_pitch_sync(t->handle, sync);
}

int tempo_process(Tempo *t, float *pcm, int *samples_in_out)
{
    if (!t || !pcm || !samples_in_out) return -1;
    if (!t->enabled && *samples_in_out <= 0) return 0;

    int in_samples = *samples_in_out;
    if (in_samples <= 0) return 0;

    int max_out = (int)((float)in_samples / 0.5f) + 256;
    if (max_out > t->tmp_capacity) {
        t->tmp_capacity = max_out * 2;
        float *new_buf = realloc(t->tmp_out, t->tmp_capacity * t->channels * sizeof(float));
        if (!new_buf) return -1;
        t->tmp_out = new_buf;
    }

    int out_samples = rs_tempo_process(t->handle, pcm, in_samples,
                                        t->tmp_out, max_out);
    if (out_samples < 0) return -1;

    if (out_samples > 0) {
        memmove(pcm, t->tmp_out, out_samples * t->channels * sizeof(float));
    }

    *samples_in_out = out_samples;
    return 0;
}

bool tempo_is_bypass(const Tempo *t)
{
    if (!t || !t->enabled) return true;
    float diff = t->speed - 1.0f;
    if (diff < 0.0f) diff = -diff;
    if (diff < 1e-4f) {
        diff = t->pitch;
        if (diff < 0.0f) diff = -diff;
        if (diff < 1e-4f) return true;
    }
    return false;
}

#else /* !HAS_TEMPO — stub 实现，tempo 始终 bypass */

struct Tempo {
    bool dummy;
};

Tempo* tempo_create(int sample_rate, int channels)
{
    (void)sample_rate; (void)channels;
    fprintf(stderr, "%s 创建: %dHz / %dch (stub, 未链接 Rust tempo 库)\n",
            LOG_TAG, sample_rate, channels);
    Tempo *t = calloc(1, sizeof(*t));
    return t;
}

void tempo_destroy(Tempo *t) { if (t) free(t); }
void tempo_reset(Tempo *t) { (void)t; }
void tempo_set_enabled(Tempo *t, bool enabled) { (void)t; (void)enabled; }
void tempo_set_speed(Tempo *t, float speed) { (void)t; (void)speed; }
void tempo_set_pitch(Tempo *t, float semitones) { (void)t; (void)semitones; }
void tempo_set_pitch_sync(Tempo *t, bool sync) { (void)t; (void)sync; }

int tempo_process(Tempo *t, float *pcm, int *samples_in_out)
{
    (void)t; (void)pcm;
    /* stub: 输出等于输入 */
    return 0;
}

bool tempo_is_bypass(const Tempo *t)
{
    (void)t;
    return true; /* stub 永远 bypass */
}

#endif /* HAS_TEMPO */

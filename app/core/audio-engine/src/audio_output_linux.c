// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output_linux.c — Linux 平台 provider
 *
 * - 后端优先级：pulse → alsa（与 miniaudio 默认 Linux 优先级一致）。
 * - 原生富化：dlopen libpulse（不新增链接依赖），读 sink 的 proplist
 *   （device.form-factor / device.bus / device.class / bluetooth.codec）与
 *   active_port 可用性，做精确分类与插拔判定；结果 3s 缓存。
 * - libpulse 缺失时回退名称启发式（ao_classify_by_name）。
 */
#define _POSIX_C_SOURCE 200809L

#include "audio_output_platform.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__has_include)
#if __has_include(<pulse/pulseaudio.h>)
#include <pulse/pulseaudio.h>
#define AO_HAVE_PULSE 1
#endif
#endif

static const ma_backend kLinuxBackends[] = {
    ma_backend_pulseaudio, ma_backend_alsa
};

static const ma_backend *linux_backend_order(int *count)
{
    if (count) *count = (int)(sizeof(kLinuxBackends) / sizeof(kLinuxBackends[0]));
    return kLinuxBackends;
}

#ifdef AO_HAVE_PULSE

/* dlopen 的 libpulse 符号表 */
typedef struct {
    void *h;
    pa_threaded_mainloop *(*ml_new)(void);
    void (*ml_free)(pa_threaded_mainloop *);
    int  (*ml_start)(pa_threaded_mainloop *);
    void (*ml_stop)(pa_threaded_mainloop *);
    void (*ml_lock)(pa_threaded_mainloop *);
    void (*ml_unlock)(pa_threaded_mainloop *);
    void (*ml_wait)(pa_threaded_mainloop *);
    void (*ml_signal)(pa_threaded_mainloop *, int wait_for_accept);
    pa_mainloop_api *(*ml_get_api)(pa_threaded_mainloop *);
    pa_context *(*ctx_new)(pa_mainloop_api *, const char *);
    void (*ctx_unref)(pa_context *);
    int  (*ctx_connect)(pa_context *, const char *, pa_context_flags_t,
                        const pa_spawn_api *);
    void (*ctx_disconnect)(pa_context *);
    pa_context_state_t (*ctx_get_state)(const pa_context *);
    void (*ctx_set_state_cb)(pa_context *, pa_context_notify_cb_t, void *);
    pa_operation *(*ctx_get_sink_info_list)(pa_context *, pa_sink_info_cb_t, void *);
    pa_operation_state_t (*op_get_state)(const pa_operation *);
    void (*op_unref)(pa_operation *);
    const char *(*proplist_gets)(const pa_proplist *, const char *);
} ao_pa_api;

typedef struct {
    char name[AUDIO_OUTPUT_ID_CAP];
    int  has_ports;
    int  available;       /* 端口是否可用（无端口=1） */
    int  is_bt, is_hdmi, is_usb, is_internal, is_virtual, is_monitor;
    char codec[32];       /* bluetooth.codec */
} ao_pulse_sink;

#define AO_PULSE_MAX 64

static ao_pa_api g_pa;
static int g_pa_ready;              /* 0=未加载 1=可用 -1=不可用 */
static ao_pulse_sink g_pulse[AO_PULSE_MAX];
static int g_pulse_count;
static time_t g_pulse_ts;

#define AO_PA_LOAD(field, sym)                                        \
    do {                                                              \
        void *p_ = dlsym(g_pa.h, sym);                                \
        if (!p_) return 0;                                            \
        memcpy(&g_pa.field, &p_, sizeof(p_));                         \
    } while (0)

static int ao_pa_load(void)
{
    static const char *kLibs[] = { "libpulse.so.0", "libpulse.so", NULL };
    int i;

    memset(&g_pa, 0, sizeof(g_pa));
    for (i = 0; kLibs[i]; ++i) {
        g_pa.h = dlopen(kLibs[i], RTLD_LAZY | RTLD_LOCAL);
        if (g_pa.h) break;
    }
    if (!g_pa.h) return 0;

    AO_PA_LOAD(ml_new, "pa_threaded_mainloop_new");
    AO_PA_LOAD(ml_free, "pa_threaded_mainloop_free");
    AO_PA_LOAD(ml_start, "pa_threaded_mainloop_start");
    AO_PA_LOAD(ml_stop, "pa_threaded_mainloop_stop");
    AO_PA_LOAD(ml_lock, "pa_threaded_mainloop_lock");
    AO_PA_LOAD(ml_unlock, "pa_threaded_mainloop_unlock");
    AO_PA_LOAD(ml_wait, "pa_threaded_mainloop_wait");
    AO_PA_LOAD(ml_signal, "pa_threaded_mainloop_signal");
    AO_PA_LOAD(ml_get_api, "pa_threaded_mainloop_get_api");
    AO_PA_LOAD(ctx_new, "pa_context_new");
    AO_PA_LOAD(ctx_unref, "pa_context_unref");
    AO_PA_LOAD(ctx_connect, "pa_context_connect");
    AO_PA_LOAD(ctx_disconnect, "pa_context_disconnect");
    AO_PA_LOAD(ctx_get_state, "pa_context_get_state");
    AO_PA_LOAD(ctx_set_state_cb, "pa_context_set_state_callback");
    AO_PA_LOAD(ctx_get_sink_info_list, "pa_context_get_sink_info_list");
    AO_PA_LOAD(op_get_state, "pa_operation_get_state");
    AO_PA_LOAD(op_unref, "pa_operation_unref");
    AO_PA_LOAD(proplist_gets, "pa_proplist_gets");
    return 1;
}

static void ao_pa_state_cb(pa_context *c, void *userdata)
{
    (void)c;
    if (userdata) g_pa.ml_signal((pa_threaded_mainloop *)userdata, 0);
}

typedef struct {
    pa_threaded_mainloop *ml;
    int done;
    int count;
    ao_pulse_sink items[AO_PULSE_MAX];
} ao_pa_query;

/* 端口可用性：有端口时看活动端口，无端口视为可用。 */
static int ao_pa_available(const pa_sink_info *info)
{
    if (!info) return 1;
    if (info->ports && info->n_ports > 0) {
        const pa_sink_port_info *ap = info->active_port;
        if (!ap) {
            uint8_t i;
            for (i = 0; i < info->n_ports; ++i) {
                if (info->ports[i] &&
                    info->ports[i]->available == PA_PORT_AVAILABLE_YES)
                    return 1;
            }
            return 0;
        }
        return ap->available != PA_PORT_AVAILABLE_NO;
    }
    return 1;
}

static void ao_pa_sink_cb(pa_context *c, const pa_sink_info *info,
                          int eol, void *userdata)
{
    ao_pa_query *q = (ao_pa_query *)userdata;
    (void)c;
    if (eol) {
        q->done = 1;
        g_pa.ml_signal(q->ml, 0);
        return;
    }
    if (!info || q->count >= AO_PULSE_MAX) return;

    {
        ao_pulse_sink *s = &q->items[q->count++];
        const char *ff, *bus, *dclass, *codec;
        memset(s, 0, sizeof(*s));
        ao_copy(s->name, sizeof(s->name), info->name);
        s->available = ao_pa_available(info);
        s->has_ports = (info->ports && info->n_ports > 0) ? 1 : 0;

        ff     = g_pa.proplist_gets(info->proplist, "device.form-factor");
        bus    = g_pa.proplist_gets(info->proplist, "device.bus");
        dclass = g_pa.proplist_gets(info->proplist, "device.class");
        codec  = g_pa.proplist_gets(info->proplist, "bluetooth.codec");
        if (codec) ao_copy(s->codec, sizeof(s->codec), codec);

        s->is_bt = (bus && ao_contains_ci(bus, "bluetooth")) ||
                   (ff && ao_contains_ci(ff, "headset")) ||
                   (ff && ao_contains_ci(ff, "hands-free")) ||
                   (s->codec[0] != '\0');
        s->is_hdmi = (ff && ao_contains_ci(ff, "hdmi")) ||
                     ao_contains_ci(s->name, "hdmi");
        s->is_usb = (bus && ao_contains_ci(bus, "usb")) ||
                    ao_contains_ci(s->name, "usb");
        s->is_virtual = (dclass && ao_contains_ci(dclass, "abstract")) ||
                        ao_contains_ci(s->name, "null") ||
                        ao_contains_ci(s->name, "virtual");
        s->is_monitor = ao_contains_ci(s->name, "monitor");
        s->is_internal = !s->is_bt && !s->is_hdmi && !s->is_usb && !s->is_virtual;
    }
}

/* 刷新 pulse sink 表（3s 缓存，失败也记时间避免风暴式重试）。 */
static void ao_pulse_refresh(void)
{
    pa_threaded_mainloop *ml;
    pa_context *c = NULL;
    ao_pa_query *q;
    time_t now = time(NULL);

    if (g_pulse_ts != 0 && now - g_pulse_ts < 3) return;
    g_pulse_ts = now;
    g_pulse_count = 0;

    if (g_pa_ready == 0) g_pa_ready = ao_pa_load() ? 1 : -1;
    if (g_pa_ready < 0) return;

    q = (ao_pa_query *)calloc(1, sizeof(*q));
    if (!q) return;

    ml = g_pa.ml_new();
    if (!ml) { free(q); return; }
    q->ml = ml;
    if (g_pa.ml_start(ml) < 0) {
        g_pa.ml_free(ml);
        free(q);
        return;
    }

    g_pa.ml_lock(ml);
    c = g_pa.ctx_new(g_pa.ml_get_api(ml), "archoera-enum");
    if (c) {
        pa_context_state_t st;
        g_pa.ctx_set_state_cb(c, ao_pa_state_cb, ml);
        g_pa.ctx_connect(c, NULL, PA_CONTEXT_NOFLAGS, NULL);
        for (;;) {
            st = g_pa.ctx_get_state(c);
            if (st == PA_CONTEXT_READY) break;
            if (!PA_CONTEXT_IS_GOOD(st)) { c = NULL; break; }
            g_pa.ml_wait(ml);
        }
    }
    if (c) {
        pa_operation *op = g_pa.ctx_get_sink_info_list(c, ao_pa_sink_cb, q);
        if (op) {
            while (!q->done) g_pa.ml_wait(ml);
            g_pa.op_unref(op);
        }
        g_pulse_count = q->count;
        if (g_pulse_count > 0)
            memcpy(g_pulse, q->items, sizeof(g_pulse[0]) * (size_t)g_pulse_count);
        g_pa.ctx_disconnect(c);
        g_pa.ctx_unref(c);
    }
    g_pa.ml_unlock(ml);
    g_pa.ml_stop(ml);
    g_pa.ml_free(ml);
    free(q);
}

static const ao_pulse_sink *ao_pulse_find(const char *id)
{
    int i;
    if (!id || g_pulse_count <= 0) return NULL;
    for (i = 0; i < g_pulse_count; ++i) {
        if (strcmp(g_pulse[i].name, id) == 0) return &g_pulse[i];
    }
    return NULL;
}

#endif /* AO_HAVE_PULSE */

static void linux_classify(const ma_context *ctx, audio_output *io)
{
    int is_pulse = (ctx && ctx->backend == ma_backend_pulseaudio);

#ifdef AO_HAVE_PULSE
    if (is_pulse) {
        const ao_pulse_sink *s = ao_pulse_find(io->id);
        if (s) {
            int low = io->has_native &&
                      (io->sample_rate < 44100u || io->channels < 2u);
            if (s->is_bt) {
                if (s->codec[0] != '\0' || !low)
                    io->cls = AUDIO_OUTPUT_CLASS_A2DP;
                else
                    io->cls = AUDIO_OUTPUT_CLASS_HFP;
            } else if (s->is_hdmi) {
                io->cls = AUDIO_OUTPUT_CLASS_HDMI;
            } else if (low) {
                io->cls = AUDIO_OUTPUT_CLASS_LOW;
            } else if (s->is_usb) {
                io->cls = AUDIO_OUTPUT_CLASS_USB;
            } else if (s->is_monitor) {
                io->cls = AUDIO_OUTPUT_CLASS_VIRTUAL;
            } else if (s->is_virtual) {
                io->cls = AUDIO_OUTPUT_CLASS_VIRTUAL;
            } else if (s->is_internal) {
                io->cls = AUDIO_OUTPUT_CLASS_INTERNAL;
            } else {
                io->cls = AUDIO_OUTPUT_CLASS_UNKNOWN;
            }

            if (s->is_virtual) io->flags |= AUDIO_OUTPUT_F_VIRTUAL;
            if (s->is_monitor) io->flags |= AUDIO_OUTPUT_F_MONITOR;
            if (!s->available) {
                io->flags &= ~(uint32_t)AUDIO_OUTPUT_F_AVAILABLE;
                io->flags &= ~(uint32_t)AUDIO_OUTPUT_F_PLUGGED;
            }
            if (s->is_bt) {
                if (s->codec[0])
                    snprintf(io->description, sizeof(io->description),
                             "Bluetooth A2DP · %s", s->codec);
                else
                    snprintf(io->description, sizeof(io->description),
                             "Bluetooth");
            } else if (s->is_hdmi) {
                ao_copy(io->description, sizeof(io->description), "HDMI");
            } else if (s->is_usb) {
                ao_copy(io->description, sizeof(io->description), "USB");
            }
            return;
        }
    }
#else
    (void)is_pulse;
#endif

    ao_classify_by_name(io, is_pulse ? 0 : 1);
}

static int linux_begin(ma_context *ctx)
{
    (void)ctx;
#ifdef AO_HAVE_PULSE
    if (ctx && ctx->backend == ma_backend_pulseaudio) ao_pulse_refresh();
#endif
    return 0;
}

static const audio_output_provider kLinuxProvider = {
    "linux", linux_backend_order, linux_begin, NULL, linux_classify, NULL
};

const audio_output_provider *audio_output_platform_provider(void)
{
    return &kLinuxProvider;
}

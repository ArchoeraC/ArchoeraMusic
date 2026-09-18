// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output.c — 输出设备枚举通用逻辑（miniaudio 抽象）
 *
 * 只做跨平台通用部分：打开枚举 context、拉取设备、取 native 格式、标记默认、
 * 归纳 flag、调用平台 provider 的 classify/keep。平台差异见 audio_output_platform.c。
 *
 * miniaudio 实现由 player.c 的 MINIAUDIO_IMPLEMENTATION 提供；本文件仅用其声明。
 */
#include "audio_output.h"

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

/* 本地安全字符串拷贝：miniaudio 的 ma_strncpy_s / MA_ZERO_OBJECT 只在实现段
   （player.c 的 MINIAUDIO_IMPLEMENTATION）内可见，本 TU 只有声明。 */
static void ao_strcpy(char *dst, size_t cap, const char *src)
{
    size_t n;
    if (!dst || cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* 后端原生 id → UTF-8 字符串（作为「可回传 set_sink」的稳定 id）。 */
static void audio_output_id_from_device(const ma_context *ctx,
                                        const ma_device_id *id,
                                        char *out, size_t cap)
{
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (!ctx || !id) return;

    switch (ctx->backend) {
    case ma_backend_pulseaudio:
        ao_strcpy(out, cap, id->pulse);
        break;
    case ma_backend_alsa:
        ao_strcpy(out, cap, id->alsa);
        break;
    case ma_backend_coreaudio:
        ao_strcpy(out, cap, id->coreaudio);
        break;
#ifdef _WIN32
    case ma_backend_wasapi: {
        /* WASAPI 用宽字符 endpoint id；转 UTF-8 供 UI/选择使用 */
        int n = WideCharToMultiByte(CP_UTF8, 0, id->wasapi, -1,
                                    out, (int)cap, NULL, NULL);
        if (n <= 0) out[0] = '\0';
        break;
    }
#endif
    default:
        /* 其它后端不做显式选择（回到默认设备语义），id 留空 */
        break;
    }
}

int audio_output_context_open(ma_context *ctx)
{
    const audio_output_provider *prov = audio_output_provider_get();
    const ma_backend *order = NULL;
    int count = 0;

    if (!ctx) return -1;

    if (prov && prov->backend_order) order = prov->backend_order(&count);
    if (order && count > 0) {
        if (ma_context_init(order, (ma_uint32)count, NULL, ctx) != MA_SUCCESS)
            return -1;
    } else {
        /* 平台默认后端顺序（Windows→WASAPI / macOS→CoreAudio / 其它默认） */
        if (ma_context_init(NULL, 0, NULL, ctx) != MA_SUCCESS) return -1;
    }
    return 0;
}

int audio_output_collect(ma_context *ctx, audio_output_entry **out)
{
    const audio_output_provider *prov = audio_output_provider_get();
    ma_device_info *pPlay = NULL, *pCap = NULL;
    ma_uint32 nPlay = 0, nCap = 0;
    audio_output_entry *arr;
    ma_uint32 i;
    int n = 0;

    if (out) *out = NULL;
    if (!ctx) return -1;

    if (prov && prov->begin) prov->begin(ctx);

    if (ma_context_get_devices(ctx, &pPlay, &nPlay, &pCap, &nCap) != MA_SUCCESS) {
        if (prov && prov->end) prov->end(ctx);
        return -1;
    }
    if (nPlay == 0 || pPlay == NULL) {
        if (prov && prov->end) prov->end(ctx);
        return 0;
    }
    if (nPlay > AUDIO_OUTPUT_MAX) nPlay = AUDIO_OUTPUT_MAX;

    arr = (audio_output_entry *)calloc(nPlay, sizeof(*arr));
    if (!arr) {
        if (prov && prov->end) prov->end(ctx);
        return -1;
    }

    for (i = 0; i < nPlay; ++i) {
        audio_output_entry *e = &arr[n];   /* 仅保留时 n 递增，剔除项被后续覆盖 */
        audio_output *io = &e->info;
        ma_device_info di;

        memset(io, 0, sizeof(*io));
        e->dev_id = pPlay[i].id;
        audio_output_id_from_device(ctx, &pPlay[i].id, io->id, sizeof(io->id));
        ao_strcpy(io->name, sizeof(io->name), pPlay[i].name);

        /* 默认：可用 + 已插拔；平台 classify 可改写 */
        io->flags = AUDIO_OUTPUT_F_AVAILABLE | AUDIO_OUTPUT_F_PLUGGED;
        if (pPlay[i].isDefault) io->flags |= AUDIO_OUTPUT_F_DEFAULT;

        /* native 格式：逐个查（pulse 填 sink sample_spec 等） */
        memset(&di, 0, sizeof(di));
        if (ma_context_get_device_info(ctx, ma_device_type_playback,
                                       &pPlay[i].id, &di) == MA_SUCCESS &&
            di.nativeDataFormatCount > 0) {
            io->sample_rate = di.nativeDataFormats[0].sampleRate;
            io->channels    = di.nativeDataFormats[0].channels;
            io->has_native  = 1;
        }

        if (prov && prov->classify) prov->classify(ctx, io);

        /* 归纳：低质类别补 flag；不可用/未插拔/虚拟/monitor → 默认隐藏 */
        if (io->cls == AUDIO_OUTPUT_CLASS_HFP ||
            io->cls == AUDIO_OUTPUT_CLASS_LOW) {
            io->flags |= AUDIO_OUTPUT_F_LOW_QUALITY;
        }
        if (!(io->flags & AUDIO_OUTPUT_F_AVAILABLE) ||
            !(io->flags & AUDIO_OUTPUT_F_PLUGGED) ||
            (io->flags & (AUDIO_OUTPUT_F_VIRTUAL | AUDIO_OUTPUT_F_MONITOR))) {
            io->flags |= AUDIO_OUTPUT_F_HIDDEN;
        }
        /* 系统默认设备永不隐藏：KDE 风格下仍保留默认入口，避免唯一设备被折叠 */
        if (io->flags & AUDIO_OUTPUT_F_DEFAULT) {
            io->flags &= ~(uint32_t)AUDIO_OUTPUT_F_HIDDEN;
        }

        if (!prov || !prov->keep || prov->keep(io)) ++n;
    }

    if (prov && prov->end) prov->end(ctx);

    if (n == 0) {
        free(arr);
        return 0;
    }
    if (out) *out = arr;
    return n;
}

void audio_output_free(audio_output_entry *entries)
{
    free(entries);
}

const char *audio_output_class_str(int cls)
{
    switch (cls) {
    case AUDIO_OUTPUT_CLASS_INTERNAL: return "internal";
    case AUDIO_OUTPUT_CLASS_USB:      return "usb";
    case AUDIO_OUTPUT_CLASS_HDMI:     return "hdmi";
    case AUDIO_OUTPUT_CLASS_A2DP:     return "a2dp";
    case AUDIO_OUTPUT_CLASS_HFP:      return "hfp";
    case AUDIO_OUTPUT_CLASS_LOW:      return "low";
    case AUDIO_OUTPUT_CLASS_VIRTUAL:  return "virtual";
    default:                          return "unknown";
    }
}

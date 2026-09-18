// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output_platform.c — 平台 provider 通用部分 + 选择入口
 *
 * 通用小工具、名称启发式基线分类、以及 [audio_output_provider_get] 入口。
 * 具体平台 provider 见 audio_output_{linux,windows,macos,stub}.c（按平台编译期选择）。
 */
#include "audio_output_platform.h"

#include <ctype.h>
#include <string.h>

int ao_contains_ci(const char *haystack, const char *needle)
{
    size_t hn, nn, i, j;
    if (!haystack || !needle || needle[0] == '\0') return 0;
    hn = strlen(haystack);
    nn = strlen(needle);
    if (nn > hn) return 0;
    for (i = 0; i + nn <= hn; ++i) {
        for (j = 0; j < nn; ++j) {
            char h = haystack[i + j], n = needle[j];
            if (h >= 'A' && h <= 'Z') h = (char)(h - 'A' + 'a');
            if (n >= 'A' && n <= 'Z') n = (char)(n - 'A' + 'a');
            if (h != n) break;
        }
        if (j == nn) return 1;
    }
    return 0;
}

void ao_copy(char *dst, size_t cap, const char *src)
{
    size_t n;
    if (!dst || cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

void ao_classify_by_name(audio_output *io, int allow_alsa_virtual)
{
    int is_bt, is_hdmi, is_usb, low;

    is_bt = ao_contains_ci(io->id, "bluetooth") ||
            ao_contains_ci(io->id, "bluez") ||
            ao_contains_ci(io->id, "blue_") ||
            ao_contains_ci(io->name, "bluetooth") ||
            ao_contains_ci(io->name, "bluez") ||
            ao_contains_ci(io->name, "blue_") ||
            ao_contains_ci(io->name, "headset") ||
            ao_contains_ci(io->name, "head-unit") ||
            ao_contains_ci(io->id, "headset") ||
            ao_contains_ci(io->id, "head-unit");
    is_hdmi = ao_contains_ci(io->id, "hdmi") || ao_contains_ci(io->name, "hdmi");
    is_usb  = ao_contains_ci(io->id, "usb")  || ao_contains_ci(io->name, "usb");
    low = io->has_native &&
          (io->sample_rate < 44100u || io->channels < 2u);

    if (is_bt && low)      io->cls = AUDIO_OUTPUT_CLASS_HFP;
    else if (is_bt)        io->cls = AUDIO_OUTPUT_CLASS_A2DP;
    else if (low)          io->cls = AUDIO_OUTPUT_CLASS_LOW;
    else if (is_hdmi)      io->cls = AUDIO_OUTPUT_CLASS_HDMI;
    else if (is_usb)       io->cls = AUDIO_OUTPUT_CLASS_USB;
    else if (ao_contains_ci(io->id, "analog") ||
             ao_contains_ci(io->id, "built") ||
             ao_contains_ci(io->name, "analog") ||
             ao_contains_ci(io->name, "built") ||
             ao_contains_ci(io->name, "speaker") ||
             ao_contains_ci(io->name, "internal") ||
             ao_contains_ci(io->name, "pci")) {
        io->cls = AUDIO_OUTPUT_CLASS_INTERNAL;
    } else {
        io->cls = AUDIO_OUTPUT_CLASS_UNKNOWN;
    }

    if (allow_alsa_virtual) {
        /* ALSA 回退时的插件伪设备（pulse 可用时不会走到这里） */
        static const char *kVirtual[] = {
            "null", "dmix", "surround", "vdownmix", "upmix",
            "speex", "samplerate", "monitor", "loopback", NULL
        };
        int k;
        for (k = 0; kVirtual[k]; ++k) {
            if (ao_contains_ci(io->id, kVirtual[k]) ||
                ao_contains_ci(io->name, kVirtual[k])) {
                io->flags |= AUDIO_OUTPUT_F_VIRTUAL;
                if (io->cls == AUDIO_OUTPUT_CLASS_UNKNOWN)
                    io->cls = AUDIO_OUTPUT_CLASS_VIRTUAL;
                break;
            }
        }
        if (ao_contains_ci(io->id, "monitor"))
            io->flags |= AUDIO_OUTPUT_F_MONITOR;
    }
}

const audio_output_provider *audio_output_provider_get(void)
{
    return audio_output_platform_provider();
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output_macos.c — macOS 平台 provider（CoreAudio 原生富化）
 *
 * miniaudio 默认后端（CoreAudio）。用 AudioObjectGetPropertyData 枚举输出设备，
 * 读取 kAudioDevicePropertyTransportType / kAudioDevicePropertyDeviceIsAlive /
 * kAudioDevicePropertyDeviceUID，做精确分类（蓝牙/HDMI/USB/内置/虚拟）与可用性判定。
 * 结果 3s 缓存。
 *
 * id 与 miniaudio `ma_device_id.coreaudio`（设备 UID）一致，保证 set_sink 可对上。
 *
 * 参考：Apple Docs — Audio Hardware / AudioDevice Property Selectors
 * （kAudioHardwarePropertyDevices、kAudioDevicePropertyTransportType 等）。
 */
#if defined(__APPLE__)

#include "audio_output_platform.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <stdlib.h>
#include <string.h>
#include <time.h>

#define AO_MAC_MAX 64

typedef struct {
    char id[AUDIO_OUTPUT_ID_CAP];   /* 设备 UID（= ma_device_id.coreaudio） */
    int  available;
    int  is_bt, is_hdmi, is_usb, is_internal, is_virtual;
    char desc[64];
} ao_mac_dev;

static ao_mac_dev g_mac[AO_MAC_MAX];
static int g_mac_count;
static time_t g_mac_ts;

static int mac_get_u32(AudioObjectID obj, AudioObjectPropertySelector sel,
                       UInt32 *out)
{
    AudioObjectPropertyAddress a = {
        sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(*out);
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, out) == noErr;
}

static CFStringRef mac_copy_cfstr(AudioObjectID obj, AudioObjectPropertySelector sel)
{
    AudioObjectPropertyAddress a = {
        sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFStringRef s = NULL;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &s) != noErr)
        return NULL;
    return s;  /* 调用方 CFRelease */
}

/* 仅保留有输出声道的设备（排除纯输入）。 */
static int mac_has_output(AudioObjectID dev)
{
    AudioObjectPropertyAddress a = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    AudioBufferList *bl;
    int ok = 0;

    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size == 0)
        return 0;
    bl = (AudioBufferList *)malloc(size);
    if (!bl) return 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, bl) == noErr) {
        UInt32 i;
        for (i = 0; i < bl->mNumberBuffers; ++i) {
            if (bl->mBuffers[i].mNumberChannels > 0) { ok = 1; break; }
        }
    }
    free(bl);
    return ok;
}

static void ao_mac_refresh(void)
{
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioDeviceID *ids;
    UInt32 size = 0, n = 0, i;
    time_t now = time(NULL);

    if (g_mac_ts != 0 && now - g_mac_ts < 3) return;
    g_mac_ts = now;
    g_mac_count = 0;

    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size)
            != noErr || size == 0)
        return;
    ids = (AudioDeviceID *)malloc(size);
    if (!ids) return;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids)
            != noErr) {
        free(ids);
        return;
    }
    n = size / (UInt32)sizeof(AudioDeviceID);

    for (i = 0; i < n && g_mac_count < AO_MAC_MAX; ++i) {
        AudioDeviceID dev = ids[i];
        CFStringRef uid;
        ao_mac_dev *d;
        UInt32 alive = 1, transport = 0;

        if (!mac_has_output(dev)) continue;
        uid = mac_copy_cfstr(dev, kAudioDevicePropertyDeviceUID);
        if (!uid) continue;

        d = &g_mac[g_mac_count];
        memset(d, 0, sizeof(*d));
        if (!CFStringGetCString(uid, d->id, sizeof(d->id), kCFStringEncodingUTF8)) {
            CFRelease(uid);
            continue;
        }
        CFRelease(uid);

        mac_get_u32(dev, kAudioDevicePropertyDeviceIsAlive, &alive);
        d->available = alive ? 1 : 0;
        mac_get_u32(dev, kAudioDevicePropertyTransportType, &transport);

        switch (transport) {
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE:
            d->is_bt = 1;
            break;
        case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort:
            d->is_hdmi = 1;
            break;
        case kAudioDeviceTransportTypeUSB:
            d->is_usb = 1;
            break;
        case kAudioDeviceTransportTypeVirtual:
        case kAudioDeviceTransportTypeAggregate:
            d->is_virtual = 1;
            break;
        case kAudioDeviceTransportTypeBuiltIn:
        case kAudioDeviceTransportTypePCI:
            d->is_internal = 1;
            break;
        default:
            break;  /* AirPlay/AVB/Thunderbolt/… 归为 unknown */
        }

        if (d->is_bt)         ao_copy(d->desc, sizeof(d->desc), "Bluetooth");
        else if (d->is_hdmi)  ao_copy(d->desc, sizeof(d->desc), "HDMI");
        else if (d->is_usb)   ao_copy(d->desc, sizeof(d->desc), "USB");

        g_mac_count++;
    }
    free(ids);
}

static const ao_mac_dev *ao_mac_find(const char *id)
{
    int i;
    if (!id || g_mac_count <= 0) return NULL;
    for (i = 0; i < g_mac_count; ++i) {
        if (strcmp(g_mac[i].id, id) == 0) return &g_mac[i];
    }
    return NULL;
}

static int macos_begin(ma_context *ctx)
{
    (void)ctx;
    ao_mac_refresh();
    return 0;
}

static void macos_classify(const ma_context *ctx, audio_output *io)
{
    const ao_mac_dev *d;
    int low;

    (void)ctx;
    d = ao_mac_find(io->id);
    if (!d) {
        ao_classify_by_name(io, 0);
        return;
    }

    low = io->has_native && (io->sample_rate < 44100u || io->channels < 2u);
    if (d->is_bt) {
        io->cls = low ? AUDIO_OUTPUT_CLASS_HFP : AUDIO_OUTPUT_CLASS_A2DP;
    } else if (d->is_hdmi) {
        io->cls = AUDIO_OUTPUT_CLASS_HDMI;
    } else if (d->is_usb) {
        io->cls = AUDIO_OUTPUT_CLASS_USB;
    } else if (low) {
        io->cls = AUDIO_OUTPUT_CLASS_LOW;
    } else if (d->is_virtual) {
        io->cls = AUDIO_OUTPUT_CLASS_VIRTUAL;
    } else if (d->is_internal) {
        io->cls = AUDIO_OUTPUT_CLASS_INTERNAL;
    } else {
        io->cls = AUDIO_OUTPUT_CLASS_UNKNOWN;
    }

    if (d->is_virtual) io->flags |= AUDIO_OUTPUT_F_VIRTUAL;
    if (!d->available) {
        io->flags &= ~(uint32_t)AUDIO_OUTPUT_F_AVAILABLE;
        io->flags &= ~(uint32_t)AUDIO_OUTPUT_F_PLUGGED;
    }
    if (d->desc[0]) ao_copy(io->description, sizeof(io->description), d->desc);
}

static const audio_output_provider kMacosProvider = {
    "macos", NULL, macos_begin, NULL, macos_classify, NULL
};

const audio_output_provider *audio_output_platform_provider(void)
{
    return &kMacosProvider;
}

#endif /* __APPLE__ */

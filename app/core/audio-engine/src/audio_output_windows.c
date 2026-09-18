// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output_windows.c — Windows 平台 provider（WASAPI 原生富化）
 *
 * miniaudio 默认后端（WASAPI）。用 IMMDeviceEnumerator 枚举 render endpoint，
 * 读取 PKEY_AudioEndpoint_FormFactor / PKEY_Device_EnumeratorName / 设备状态，
 * 做精确分类（蓝牙 HFP/A2DP、HDMI、USB、内置）与插拔/可用性判定。结果 3s 缓存。
 *
 * id 与 miniaudio `ma_device_id.wasapi`（endpoint id，宽字符转 UTF-8）一致，
 * 保证 Dart 回传 set_sink 可对上。
 *
 * 参考：Microsoft Docs —
 *   IMMDeviceEnumerator / IMMDevice / IPropertyStore / EndpointFormFactor /
 *   PKEY_AudioEndpoint_FormFactor / PKEY_Device_EnumeratorName。
 */
#if defined(_WIN32)

#include "audio_output_platform.h"

#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <propidl.h>

#include <stdlib.h>
#include <string.h>
#include <time.h>

/* 手动声明所需 GUID/属性键，避免引入 uuid.lib/propsys.lib 的符号依赖。 */
static const GUID kCLSID_MMDeviceEnumerator = {
    0xBCDE0395, 0xE52F, 0x467C, { 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E }
};
static const GUID kIID_IMMDeviceEnumerator = {
    0xA95664D2, 0x9614, 0x4F35, { 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 }
};

/* {1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E}, 0  — PKEY_AudioEndpoint_FormFactor */
static const PROPERTYKEY kPkeyFormFactor = {
    { 0x1DA5D803, 0xD492, 0x4EDD, { 0x8C, 0x23, 0xE0, 0xC0, 0xFF, 0xEE, 0x7F, 0x0E } }, 0
};
/* {A45C254E-DF1C-4EFD-8020-67D146A850E0}, 24 — PKEY_Device_EnumeratorName */
static const PROPERTYKEY kPkeyEnumeratorName = {
    { 0xA45C254E, 0xDF1C, 0x4EFD, { 0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0 } }, 24
};
/* {A45C254E-DF1C-4EFD-8020-67D146A850E0}, 14 — PKEY_Device_FriendlyName */
static const PROPERTYKEY kPkeyFriendlyName = {
    { 0xA45C254E, 0xDF1C, 0x4EFD, { 0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0 } }, 14
};

/* EndpointFormFactor（mmdeviceapi.h 的 tagEndpointFormFactor）关键值 */
#define AO_FF_SPEAKERS        1
#define AO_FF_HEADPHONES      3
#define AO_FF_HEADSET         5
#define AO_FF_HANDSET         6
#define AO_FF_SPDIF           8
#define AO_FF_HDMI            9  /* DigitalAudioDisplayDevice */

#define AO_WIN_MAX 64

typedef struct {
    char id[AUDIO_OUTPUT_ID_CAP];   /* UTF-8 endpoint id（= ma_device_id.wasapi） */
    int  available;
    int  is_bt, is_hfp, is_hdmi, is_usb, is_spdif, is_internal, is_virtual;
    char desc[64];
} ao_win_dev;

static ao_win_dev g_win[AO_WIN_MAX];
static int g_win_count;
static time_t g_win_ts;

static void ao_win_w2u(const wchar_t *w, char *out, size_t cap)
{
    int n;
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (!w) return;
    n = WideCharToMultiByte(CP_UTF8, 0, w, -1, out, (int)cap, NULL, NULL);
    if (n <= 0) out[0] = '\0';
}

static void ao_win_read_str(IPropertyStore *ps, const PROPERTYKEY *key,
                            char *out, size_t cap)
{
    PROPVARIANT pv;
    out[0] = '\0';
    PropVariantInit(&pv);
    if (ps && SUCCEEDED(ps->lpVtbl->GetValue(ps, key, &pv)) &&
        pv.vt == VT_LPWSTR && pv.pwszVal) {
        ao_win_w2u(pv.pwszVal, out, cap);
    }
    PropVariantClear(&pv);
}

static int ao_win_read_form_factor(IPropertyStore *ps)
{
    PROPVARIANT pv;
    int ff = -1;
    PropVariantInit(&pv);
    if (ps && SUCCEEDED(ps->lpVtbl->GetValue(ps, &kPkeyFormFactor, &pv))) {
        if (pv.vt == VT_UI4) ff = (int)pv.ulVal;
        else if (pv.vt == VT_UI2) ff = (int)pv.uiVal;
    }
    PropVariantClear(&pv);
    return ff;
}

/* 枚举 render endpoints（含未插拔/禁用，用于标记不可用）并缓存。 */
static void ao_win_refresh(void)
{
    HRESULT hr;
    IMMDeviceEnumerator *en = NULL;
    IMMDeviceCollection *coll = NULL;
    int com_inited = 0;
    time_t now = time(NULL);

    if (g_win_ts != 0 && now - g_win_ts < 3) return;
    g_win_ts = now;
    g_win_count = 0;

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr == S_OK || hr == S_FALSE) {
        com_inited = 1;
    } else if (hr == RPC_E_CHANGED_MODE) {
        com_inited = 0;   /* 已被初始化为其它 apartment：仍可用 COM */
    } else {
        return;
    }

    hr = CoCreateInstance(&kCLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &kIID_IMMDeviceEnumerator, (void **)&en);
    if (FAILED(hr) || !en) goto done;

    hr = en->lpVtbl->EnumAudioEndpoints(
        en, eRender,
        DEVICE_STATE_ACTIVE | DEVICE_STATE_DISABLED | DEVICE_STATE_UNPLUGGED,
        &coll);
    if (FAILED(hr) || !coll) goto done;

    {
        UINT count = 0, i;
        coll->lpVtbl->GetCount(coll, &count);
        for (i = 0; i < count && g_win_count < AO_WIN_MAX; ++i) {
            IMMDevice *dev = NULL;
            IPropertyStore *ps = NULL;
            wchar_t *wid = NULL;
            DWORD state = 0;
            ao_win_dev *d;
            char enumer[64];
            char fname[128];

            enumer[0] = '\0';
            fname[0] = '\0';

            if (FAILED(coll->lpVtbl->Item(coll, i, &dev)) || !dev) continue;

            dev->lpVtbl->GetId(dev, &wid);
            dev->lpVtbl->GetState(dev, &state);

            d = &g_win[g_win_count];
            memset(d, 0, sizeof(*d));
            ao_win_w2u(wid, d->id, sizeof(d->id));
            d->available = (state & DEVICE_STATE_ACTIVE) ? 1 : 0;

            if (SUCCEEDED(dev->lpVtbl->OpenPropertyStore(dev, STGM_READ, &ps)) && ps) {
                int ff = ao_win_read_form_factor(ps);
                ao_win_read_str(ps, &kPkeyEnumeratorName, enumer, sizeof(enumer));
                ao_win_read_str(ps, &kPkeyFriendlyName, fname, sizeof(fname));
                d->is_bt   = ao_contains_ci(enumer, "BTH") ||
                             ao_contains_ci(fname, "bluetooth");
                d->is_hfp  = ao_contains_ci(enumer, "BTHHF") ||
                             ff == AO_FF_HEADSET || ff == AO_FF_HANDSET ||
                             ao_contains_ci(fname, "hands-free");
                d->is_hdmi = ff == AO_FF_HDMI || ao_contains_ci(enumer, "HDMI");
                d->is_usb  = ao_contains_ci(enumer, "USB");
                d->is_spdif = (ff == AO_FF_SPDIF);
                d->is_virtual = ao_contains_ci(enumer, "SWD") ||
                                ao_contains_ci(enumer, "ROOT") ||
                                ao_contains_ci(enumer, "VIRTUAL");
                ps->lpVtbl->Release(ps);
            }
            d->is_internal = !d->is_bt && !d->is_hdmi && !d->is_usb &&
                             !d->is_spdif && !d->is_virtual;

            if (d->is_bt) {
                ao_copy(d->desc, sizeof(d->desc),
                        d->is_hfp ? "Bluetooth HFP" : "Bluetooth A2DP");
            } else if (d->is_hdmi) {
                ao_copy(d->desc, sizeof(d->desc), "HDMI");
            } else if (d->is_usb) {
                ao_copy(d->desc, sizeof(d->desc), "USB");
            } else if (d->is_spdif) {
                ao_copy(d->desc, sizeof(d->desc), "S/PDIF");
            }

            if (wid) CoTaskMemFree(wid);
            dev->lpVtbl->Release(dev);
            g_win_count++;
        }
    }

done:
    if (coll) coll->lpVtbl->Release(coll);
    if (en) en->lpVtbl->Release(en);
    if (com_inited) CoUninitialize();
}

static const ao_win_dev *ao_win_find(const char *id)
{
    int i;
    if (!id || g_win_count <= 0) return NULL;
    for (i = 0; i < g_win_count; ++i) {
        if (strcmp(g_win[i].id, id) == 0) return &g_win[i];
    }
    return NULL;
}

static int windows_begin(ma_context *ctx)
{
    (void)ctx;
    ao_win_refresh();
    return 0;
}

static void windows_classify(const ma_context *ctx, audio_output *io)
{
    const ao_win_dev *d;
    int low;

    (void)ctx;
    d = ao_win_find(io->id);
    if (!d) {
        ao_classify_by_name(io, 0);
        return;
    }

    low = io->has_native && (io->sample_rate < 44100u || io->channels < 2u);
    if (d->is_bt) {
        io->cls = (d->is_hfp || low) ? AUDIO_OUTPUT_CLASS_HFP
                                     : AUDIO_OUTPUT_CLASS_A2DP;
    } else if (d->is_hdmi) {
        io->cls = AUDIO_OUTPUT_CLASS_HDMI;
    } else if (d->is_usb) {
        io->cls = AUDIO_OUTPUT_CLASS_USB;
    } else if (d->is_spdif) {
        io->cls = AUDIO_OUTPUT_CLASS_INTERNAL;
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

static const audio_output_provider kWindowsProvider = {
    "windows", NULL, windows_begin, NULL, windows_classify, NULL
};

const audio_output_provider *audio_output_platform_provider(void)
{
    return &kWindowsProvider;
}

#endif /* _WIN32 */

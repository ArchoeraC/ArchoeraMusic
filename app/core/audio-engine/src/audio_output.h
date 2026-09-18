// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output.h — 输出设备枚举的统一接口（模块化）
 *
 * 设计动机（2026-09-18）：
 *   把「给 UI 的输出设备列表」从 player.c 的临时逻辑抽成独立模块，通用逻辑
 *   （枚举 / 默认标记 / native 格式 / flag 归纳）与平台差异（后端优先级 / 设备
 *   分类 / 可用性 / 去重）分离。平台差异经 [audio_output_provider] 函数指针表
 *   注入，按编译期选择实现（linux/windows/macos/stub）。
 *
 * 关键约束：枚举条目同时携带 UI 展示用的 [audio_output] 与真正打开设备用的
 *   [ma_device_id]，二者同源 → Dart 回传的 set_sink id 必然能被播放路径对上
 *   （解决「枚举在桥接层、播放id 无法通信」的问题）。
 *
 * miniaudio 实现仅由 player.c 的 MINIAUDIO_IMPLEMENTATION 提供一次；本头文件
 * 只引用其声明（被 player.c / audio_output.c 包含）。player.c 必须先 include
 * 带实现的 miniaudio.h，再 include 本头文件。
 */
#ifndef ARCHOERA_AUDIO_OUTPUT_H
#define ARCHOERA_AUDIO_OUTPUT_H

#include <stddef.h>
#include <stdint.h>

#include "miniaudio.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AUDIO_OUTPUT_ID_CAP   256
#define AUDIO_OUTPUT_NAME_CAP 256

/* 单次枚举条目上限（防极端多 sink 撑爆调用方缓冲） */
#define AUDIO_OUTPUT_MAX      64

/* 设备类别：与 Dart 侧 JSON `class` 字符串一一对应 */
enum {
    AUDIO_OUTPUT_CLASS_UNKNOWN = 0,
    AUDIO_OUTPUT_CLASS_INTERNAL,
    AUDIO_OUTPUT_CLASS_USB,
    AUDIO_OUTPUT_CLASS_HDMI,
    AUDIO_OUTPUT_CLASS_A2DP,
    AUDIO_OUTPUT_CLASS_HFP,
    AUDIO_OUTPUT_CLASS_LOW,
    AUDIO_OUTPUT_CLASS_VIRTUAL
};

/* 设备 flag 位 */
#define AUDIO_OUTPUT_F_DEFAULT     (1u << 0)  /* 系统当前默认 playback 设备 */
#define AUDIO_OUTPUT_F_AVAILABLE   (1u << 1)  /* 端口当前可用 */
#define AUDIO_OUTPUT_F_PLUGGED     (1u << 2)  /* 物理已插拔（未插 = 0）*/
#define AUDIO_OUTPUT_F_VIRTUAL     (1u << 3)  /* 虚拟/插件伪设备（null/dmix/monitor…）*/
#define AUDIO_OUTPUT_F_MONITOR     (1u << 4)  /* loopback/monitor 源 */
#define AUDIO_OUTPUT_F_LOW_QUALITY (1u << 5)  /* 通话/低质（HFP、<44.1kHz 或单声道）*/
#define AUDIO_OUTPUT_F_HIDDEN      (1u << 6)  /* 默认隐藏（KDE 风格，展开后可见）*/

/* 单个输出设备的自包含描述（不持有外部生命周期） */
typedef struct audio_output {
    char     id[AUDIO_OUTPUT_ID_CAP];    /* 后端原生 id（可回传 set_sink 选择） */
    char     name[AUDIO_OUTPUT_NAME_CAP];/* 展示名 */
    char     description[AUDIO_OUTPUT_NAME_CAP]; /* 副标题（类别/总线等，可空） */
    unsigned sample_rate;                /* nativeDataFormats[0].sampleRate（0=未知） */
    unsigned channels;                   /* nativeDataFormats[0].channels（0=未知） */
    int      has_native;                 /* native 格式已知 */
    uint32_t flags;                      /* AUDIO_OUTPUT_F_* 位组合 */
    int      cls;                        /* AUDIO_OUTPUT_CLASS_* */
} audio_output;

/* 枚举条目：info（给 UI）+ dev_id（给播放打开设备，二者同源） */
typedef struct audio_output_entry {
    audio_output info;
    ma_device_id  dev_id;
} audio_output_entry;

/**
 * 平台 provider 接口：平台差异集中于此，通用枚举逻辑在 audio_output.c。
 * 所有函数指针均可为 NULL（表示无平台特殊处理）。
 */
typedef struct audio_output_provider {
    const char *name;                        /* 诊断用平台名 */

    /* miniaudio 后端优先级数组（静态存储；*count 输出元素数）。
       NULL → 使用 miniaudio 平台默认后端顺序（Windows=WASAPI、macOS=CoreAudio、
       Linux=默认）。这是修复 Win/mac 枚举为空的关键。 */
    const ma_backend *(*backend_order)(int *count);

    /* 枚举前/后就绪钩子（如需打开平台服务，如 libpulse / WASAPI 属性表），可为 NULL。 */
    int  (*begin)(ma_context *ctx);
    void (*end)(ma_context *ctx);

    /* 逐设备分类/可用性/描述：读 info.id/name/rate/channels，写 cls/flags/description。 */
    void (*classify)(const ma_context *ctx, audio_output *io);

    /* 是否保留该条目（去重/剔除垃圾设备）。NULL = 全部保留。
       被 keep 剔除的设备不会返回给 Dart（连「展开显示」也不可见）。 */
    int  (*keep)(const audio_output *io);
} audio_output_provider;

/** 当前平台 provider（编译期选择，永不返回 NULL）。 */
const audio_output_provider *audio_output_provider_get(void);

/** 按 provider 的后端优先级打开一个枚举用 context。0=成功，<0=失败。 */
int  audio_output_context_open(ma_context *ctx);

/**
 * 枚举全部输出设备（自建 context 由调用方负责）。
 * @param out  输出：堆数组（calloc），调用方用 audio_output_free 释放
 * @return >0 条目数；0 无设备；<0 失败。*out 在 <=0 时为 NULL。
 */
int  audio_output_collect(ma_context *ctx, audio_output_entry **out);

/** 释放 audio_output_collect 返回的数组。 */
void audio_output_free(audio_output_entry *entries);

/** 类别枚举 → 稳定字符串（JSON/Dart 共用；未知返回 "unknown"）。 */
const char *audio_output_class_str(int cls);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_AUDIO_OUTPUT_H */

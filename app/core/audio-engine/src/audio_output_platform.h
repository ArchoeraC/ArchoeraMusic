// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output_platform.h — 平台 provider 内部共享（仅被 audio_output_*.c 使用）
 */
#ifndef ARCHOERA_AUDIO_OUTPUT_PLATFORM_H
#define ARCHOERA_AUDIO_OUTPUT_PLATFORM_H

#include "audio_output.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 通用小工具（实现见 audio_output_platform.c） */
int  ao_contains_ci(const char *haystack, const char *needle);
void ao_copy(char *dst, size_t cap, const char *src);

/* 名称启发式基线分类（平台原生数据不可用/未命中时使用） */
void ao_classify_by_name(audio_output *io, int allow_alsa_virtual);

/* 各平台实现：返回本平台 provider（编译期只链入一个） */
const audio_output_provider *audio_output_platform_provider(void);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_AUDIO_OUTPUT_PLATFORM_H */

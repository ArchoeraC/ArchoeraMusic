// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * audio_output_stub.c — 未覆盖平台兜底 provider
 *
 * 使用 miniaudio 平台默认后端顺序 + 名称启发式分类；无平台原生富化。
 */
#include "audio_output_platform.h"

static void stub_classify(const ma_context *ctx, audio_output *io)
{
    (void)ctx;
    ao_classify_by_name(io, 0);
}

static const audio_output_provider kStubProvider = {
    "stub", NULL, NULL, NULL, stub_classify, NULL
};

const audio_output_provider *audio_output_platform_provider(void)
{
    return &kStubProvider;
}

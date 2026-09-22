// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * dsp_ref/lim_ref.c — 测试专用「纯 C 参考」翻译单元（见 eq_ref.c 说明）
 */

#undef HAS_ARCHOERA_KERNEL

#define limiter_create        dspref_lim_create
#define limiter_set_enabled   dspref_lim_set_enabled
#define limiter_set_threshold dspref_lim_set_threshold
#define limiter_process       dspref_lim_process
#define limiter_get_threshold dspref_lim_get_threshold
#define limiter_destroy       dspref_lim_destroy

#include "../../src/limiter.c"

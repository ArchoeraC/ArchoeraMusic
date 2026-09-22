// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * dsp_ref/loud_ref.c — 测试专用「纯 C 参考」翻译单元（见 eq_ref.c 说明）
 */

#undef HAS_ARCHOERA_KERNEL

#define loudness_create       dspref_loud_create
#define loudness_set_enabled  dspref_loud_set_enabled
#define loudness_set_target   dspref_loud_set_target
#define loudness_set_gain     dspref_loud_set_gain
#define loudness_process      dspref_loud_process
#define loudness_destroy      dspref_loud_destroy

#include "../../src/loudness.c"

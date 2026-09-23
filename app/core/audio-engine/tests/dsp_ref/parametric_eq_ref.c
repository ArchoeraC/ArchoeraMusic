// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * dsp_ref/parametric_eq_ref.c — 测试专用「纯 C 参考」翻译单元（方向① D1）
 *
 * 以宏重命名方式，把 `src/parametric_eq.c` 的**原始 C 实现**再编译一份（符号
 * 前缀 `dspref_peq_`），与内核 `zk_dsp_peq_*` 逐块对照（复用生产线同一份源码，
 * 无复制漂移，且不与 audio_engine_static 中的内核路由版符号冲突）。
 *
 * 必须 `#undef HAS_ARCHOERA_KERNEL`——否则会同样路由内核，不再是纯 C 参考。
 */

#undef HAS_ARCHOERA_KERNEL

#define parametric_eq_create     dspref_peq_create
#define parametric_eq_set_bands  dspref_peq_set_bands
#define parametric_eq_set_enabled dspref_peq_set_enabled
#define parametric_eq_set_preamp dspref_peq_set_preamp
#define parametric_eq_process    dspref_peq_process
#define parametric_eq_destroy    dspref_peq_destroy

#include "../../src/parametric_eq.c"

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * dsp_ref/lowfreq_ref.c — 测试专用「纯 C 参考」翻译单元（方向① D2）
 *
 * 以宏重命名方式，把 `src/lowfreq.c` 的**原始 C 实现**再编译一份（符号前缀
 * `dspref_lf_`），与内核 `zk_dsp_lowfreq_*` 逐块对照（复用生产线同一份源码，
 * 无复制漂移，且不与 audio_engine_static 中的内核路由版符号冲突）。
 *
 * 必须 `#undef HAS_ARCHOERA_KERNEL`——否则会同样路由内核，不再是纯 C 参考。
 */

#undef HAS_ARCHOERA_KERNEL

#define lowfreq_create      dspref_lf_create
#define lowfreq_set_enabled dspref_lf_set_enabled
#define lowfreq_set_hpf     dspref_lf_set_hpf
#define lowfreq_set_bass    dspref_lf_set_bass
#define lowfreq_process     dspref_lf_process
#define lowfreq_destroy     dspref_lf_destroy

#include "../../src/lowfreq.c"

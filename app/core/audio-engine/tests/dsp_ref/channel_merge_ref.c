// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * dsp_ref/channel_merge_ref.c — 测试专用「纯 C 参考」翻译单元
 *
 * 以宏重命名方式，把 `src/channel_merge.c` 的**原始 C 实现**再编译一份（符号
 * 前缀 `dspref_cm_`），与内核 `zk_dsp_channel_merge_*` 逐块对照（复用生产线
 * 同一份源码，无复制漂移，且不与 audio_engine_static 中的内核路由版符号冲突）。
 *
 * 必须 `#undef HAS_ARCHOERA_KERNEL`——否则会同样路由内核，不再是纯 C 参考。
 */

#undef HAS_ARCHOERA_KERNEL

#define channel_merge_create      dspref_cm_create
#define channel_merge_set_enabled dspref_cm_set_enabled
#define channel_merge_process     dspref_cm_process
#define channel_merge_destroy     dspref_cm_destroy

#include "../../src/channel_merge.c"

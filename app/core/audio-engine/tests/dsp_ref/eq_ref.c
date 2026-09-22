// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * dsp_ref/eq_ref.c — 测试专用「纯 C 参考」翻译单元
 *
 * 以宏重命名方式，把 `src/equalizer.c` 的**原始 C 实现**再编译一份（符号
 * 前缀 `dspref_eq_`），与内核 `zk_dsp_eq_*` 逐块对照。这样既复用了生产线
 * 正在使用的同一份 C 源码（无复制漂移），又避免与 audio_engine_static 中的
 * 内核路由版 `equalizer_*` 符号冲突。
 *
 * 注意：必须 `#undef HAS_ARCHOERA_KERNEL`——否则 equalizer.c 会同样路由内核，
 * 参考实现就不再是纯 C。
 */

#undef HAS_ARCHOERA_KERNEL

#define equalizer_create     dspref_eq_create
#define equalizer_set_gains  dspref_eq_set_gains
#define equalizer_set_preamp dspref_eq_set_preamp
#define equalizer_process    dspref_eq_process
#define equalizer_destroy    dspref_eq_destroy

#include "../../src/equalizer.c"

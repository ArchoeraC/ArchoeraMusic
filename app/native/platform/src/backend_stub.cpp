// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 未实现平台的兜底后端：能力位图 0，所有调用返回 UNSUPPORTED。
//! 保证 ABI 在任意目标可链接、可运行（Dart 侧据此降级）。

#include "backend.h"

#include "core.h"

namespace archoera {

uint32_t caps() { return 0; }

int32_t init() { return OK; }
int32_t shutdown() { return OK; }

int32_t powerSetSleepInhibit(int32_t) { return ERR_UNSUPPORTED; }
int32_t powerSetScreenEvents(int32_t) { return ERR_UNSUPPORTED; }

int32_t windowSetEvents(int32_t) { return ERR_UNSUPPORTED; }

int32_t mediaSetTrack(const AplTrackMeta*) { return ERR_UNSUPPORTED; }
int32_t mediaSetPlayback(int32_t, int64_t, double, double, int32_t, int32_t) {
    return ERR_UNSUPPORTED;
}
int32_t mediaSetWindow(int64_t) { return ERR_UNSUPPORTED; }

int32_t appInstanceAcquire() { return 1; }

bool systemAccent(int32_t*, int32_t*, int32_t*) { return false; }
int32_t systemAccentSetEvents(bool) { return ERR_UNSUPPORTED; }
int32_t systemThemeSetEvents(bool) { return ERR_UNSUPPORTED; }

int32_t notify(const char*, const char*) { return ERR_UNSUPPORTED; }

}  // namespace archoera

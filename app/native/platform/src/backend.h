// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 平台后端契约：每个平台实现一份（backend_windows.cpp / backend_linux.cpp /
//! backend_macos.mm），构建期二选一；未实现的平台落 backend_stub.cpp。
//! 所有函数返回 core 错误码；未 init 时由 apl.cpp 拦截。

#ifndef ARCHOERA_BACKEND_H
#define ARCHOERA_BACKEND_H

#include "archoera_platform.h"

namespace archoera {

uint32_t caps();

int32_t init();
int32_t shutdown();

int32_t powerSetSleepInhibit(int32_t on);
int32_t powerSetScreenEvents(int32_t on);

int32_t windowSetEvents(int32_t on);

int32_t mediaSetTrack(const AplTrackMeta* track);
int32_t mediaSetPlayback(int32_t state, int64_t position_ms, double speed,
                         double volume, int32_t loop, int32_t shuffle);
int32_t mediaSetWindow(int64_t window);

int32_t appInstanceAcquire();

bool systemAccent(int32_t* r, int32_t* g, int32_t* b);
int32_t systemAccentSetEvents(bool on);

// 订阅系统深浅色（平台推送：订阅即推当前值，之后推变化）。
int32_t systemThemeSetEvents(bool on);

int32_t notify(const char* title, const char* body);

}  // namespace archoera

#endif  // ARCHOERA_BACKEND_H

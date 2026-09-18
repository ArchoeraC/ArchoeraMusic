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

// ArchoeraOS 会话：仅 Linux/Wayland 提供，其余平台恒不支持。
int32_t osSessionSetEvents(int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionSetBrightness(int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionSetVolume(int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionSetScreenEnabled(int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionPowerOff() { return ERR_UNSUPPORTED; }
int32_t osSessionReboot() { return ERR_UNSUPPORTED; }
int32_t osSessionSuspend() { return ERR_UNSUPPORTED; }
int32_t osSessionHibernate() { return ERR_UNSUPPORTED; }
int32_t osSessionSetOutputScale(int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionSetOutputMode(int32_t, int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionSetOutputTransform(int32_t) { return ERR_UNSUPPORTED; }
int32_t osSessionKey(int32_t, int32_t) { return ERR_UNSUPPORTED; }

}  // namespace archoera

// ── 系统资源 / 蓝牙：未覆盖平台返回 UNSUPPORTED ─────────────────────
namespace sysinfo {
bool statsAvailable() { return false; }
bool bluetoothAvailable() { return false; }
void probe() {}
int32_t stats(AplSysStats*) { return ERR_UNSUPPORTED; }
int32_t btState(AplBtState*) { return ERR_UNSUPPORTED; }
void shutdown() {}
}  // namespace sysinfo

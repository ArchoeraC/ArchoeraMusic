// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 平台能力桥接 core（C++）：错误码 / 事件结构 / 回调注册与分发。
//!
//! 线程模型：后端可在任意 OS 线程调 dispatch()；回调指针注册走互斥锁
//! （注册与注销线程安全），分发时取快照后在锁外调用，避免回调重入死锁。
//! Dart 侧回调必须用 NativeCallable.listener。

#ifndef ARCHOERA_CORE_H
#define ARCHOERA_CORE_H

#include <cstddef>
#include <cstdint>

#include "archoera_platform.h"

namespace archoera {

// ── 错误码（对齐 include/archoera_platform.h）─────────────────────
constexpr int32_t OK = 0;
constexpr int32_t ERR_UNSUPPORTED = -1;
constexpr int32_t ERR_BACKEND = -2;
constexpr int32_t ERR_STATE = -3;

// ── 能力位图 ──────────────────────────────────────────────────────
constexpr uint32_t CAP_POWER_INHIBIT = 1u << 0;
constexpr uint32_t CAP_POWER_SCREEN_STATE = 1u << 1;
constexpr uint32_t CAP_MEDIA_SESSION = 1u << 2;
constexpr uint32_t CAP_MEDIA_SEEK = 1u << 3;
constexpr uint32_t CAP_MEDIA_ARTWORK = 1u << 4;
constexpr uint32_t CAP_WINDOW_STATE = 1u << 5;
constexpr uint32_t CAP_APP_INSTANCE = 1u << 6;
constexpr uint32_t CAP_SYSTEM_ACCENT = 1u << 7;
constexpr uint32_t CAP_SYSTEM_THEME = 1u << 8;

// ── 事件类型 / 命令 ───────────────────────────────────────────────
constexpr int32_t EVENT_MEDIA_COMMAND = 1;
constexpr int32_t EVENT_MEDIA_SEEK = 2;
constexpr int32_t EVENT_SCREEN_STATE = 3;
constexpr int32_t EVENT_WINDOW_STATE = 4;
constexpr int32_t EVENT_BACKEND_STATE = 5;
constexpr int32_t EVENT_SYSTEM_ACCENT = 6;
constexpr int32_t EVENT_SYSTEM_THEME = 7;

constexpr int32_t CMD_PLAY = 0;
constexpr int32_t CMD_PAUSE = 1;
constexpr int32_t CMD_TOGGLE = 2;
constexpr int32_t CMD_STOP = 3;
constexpr int32_t CMD_NEXT = 4;
constexpr int32_t CMD_PREV = 5;

// ── 生命周期 ──────────────────────────────────────────────────────
bool isInitialized();
void setInitialized(bool v);

// 注册/注销（NULL）事件回调；线程安全、幂等。
void setEventCallback(AplEventCallback cb, void* user_data);

// 把事件投递给 Dart 回调（任意线程可调；回调期间不持锁）。
// 无回调 / 未注册时静默丢弃。事件写入进程级静态槽再传其地址：回调可能是
// 异步 NativeCallable.listener，Dart 稍后读取指针，故不能用栈内存。
void dispatch(const AplEvent& event);

// ── 便捷构造 ──────────────────────────────────────────────────────
AplEvent makeCommand(int32_t command);
AplEvent makeSeek(int64_t rel_ms, int64_t abs_ms);
AplEvent makeScreenState(bool active);
AplEvent makeWindowState(bool minimized, bool focused);
AplEvent makeBackendLost(bool lost);
AplEvent makeSystemAccent(int32_t r, int32_t g, int32_t b);
AplEvent makeSystemTheme(bool dark);

}  // namespace archoera

#endif  // ARCHOERA_CORE_H

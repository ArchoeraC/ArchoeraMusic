// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ArchoeraOS 会话（`archoera_shell_v1`）客户端契约。
//!
//! 仅 Linux/Wayland 实现（`os_session_linux.cpp`）：以**第二个** Wayland 连接
//! 绑定合成器的自定义全局对象，接收会话事件（媒体键/电源键/亮度/音量/电池/
//! 会话态/屏幕）并下发系统请求（关机/重启/挂起/休眠/亮度/音量/熄屏）。
//! 为了不新增链接与打包依赖，libwayland-client 经 `dlopen` 使用（同 GTK 处理），
//! 协议接口按 `os/protocol/archoera-shell-v1.xml` 手写映射。
//!
//! 未运行于 archoera-shell（如普通桌面）时 `probe()` 为假，能力位不置位，
//! 所有请求返回 `ERR_UNSUPPORTED`。

#ifndef ARCHOERA_OS_SESSION_H
#define ARCHOERA_OS_SESSION_H

#include <cstdint>

#include "archoera_platform.h"

namespace archoera {
namespace os_session {

// 进程启动时探测一次：连接 Wayland、查 `archoera_shell_v1` 全局是否存在。
// 结果供 caps() 决定是否置 CAP_OS_SESSION；不保持连接。
bool probe();

// 探测结果（init 前为 false）。
bool available();

// 订阅/退订会话事件。订阅成功时合成器会立即下发当前会话状态。
int32_t setEvents(bool on);

// 系统请求（内部按需自动连接）。
int32_t setBrightness(int32_t percent);
int32_t setVolume(int32_t percent);
int32_t setScreenEnabled(bool on);
int32_t powerOff();
int32_t reboot();
int32_t suspend();
int32_t hibernate();

// 显示设置（仅合成器置位 output 能力时生效）。
int32_t setOutputScale(int32_t scaleMilli);
int32_t setOutputMode(int32_t width, int32_t height);
int32_t setOutputTransform(int32_t transform);

// 断开连接、停止泵线程（apl_shutdown）。
void shutdown();

}  // namespace os_session
}  // namespace archoera

#endif  // ARCHOERA_OS_SESSION_H

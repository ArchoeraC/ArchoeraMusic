// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 系统资源与蓝牙状态（`apl_sys_stats` / `apl_bt_state`）契约。
//!
//! 只读快照、轮询式（无事件）：CPU/内存/磁盘/运行时长/温度取自 `/proc`、`statvfs`
//! 与 `/sys/class/thermal`；蓝牙经 **system bus** 的 BlueZ（`org.bluez`）读取适配器
//! 与设备状态。未覆盖平台返回 `ERR_UNSUPPORTED`。

#ifndef ARCHOERA_SYSINFO_H
#define ARCHOERA_SYSINFO_H

#include <cstdint>

#include "archoera_platform.h"

namespace archoera {
namespace sysinfo {

// 进程启动时探测一次：是否具备系统资源 / 蓝牙能力（供 caps() 置位）。
bool statsAvailable();
bool bluetoothAvailable();
void probe();

// 读取快照；成功返回 OK 并写 out。
int32_t stats(AplSysStats* out);
int32_t btState(AplBtState* out);

// 释放缓存（apl_shutdown）。
void shutdown();

}  // namespace sysinfo
}  // namespace archoera

#endif  // ARCHOERA_SYSINFO_H

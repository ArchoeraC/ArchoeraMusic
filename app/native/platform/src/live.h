// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Live 安装向导支持（`apl_live_*`）契约。
//!
//! 只在 Live 环境（存在 `/etc/archoera-live`）可用：
//! - 磁盘清单：读 `/run/archoera-install/devices`（由 Live 的 oneshot 单元
//!   `archoera-live-devices.service` 调 `archoera-install --list` 生成；lsblk 只在
//!   **我们自己的脚本**里用，桥接侧不做任何子进程）；
//! - 开始安装：写 `/run/archoera-install/plan` 与 `secrets`（0600），再经 system bus
//!   调 systemd 的 `StartUnit`（polkit 放行活动会话的 kiosk 用户）；
//! - 进度：读 `/run/archoera-install/{percent,message,done,failed}`。

#ifndef ARCHOERA_LIVE_H
#define ARCHOERA_LIVE_H

#include <cstdint>

#include "archoera_platform.h"

namespace archoera {
namespace live {

bool available();
int32_t diskList(AplLiveDisk* out, uint32_t max, uint32_t* count);
int32_t installStart(const AplLivePlan* plan);
int32_t installStatus(AplLiveInstallStatus* out);

}  // namespace live
}  // namespace archoera

#endif  // ARCHOERA_LIVE_H

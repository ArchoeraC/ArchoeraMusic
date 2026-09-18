// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 网络（WiFi）与蓝牙控制（`apl_wifi_*` / `apl_bt_*`）契约。
//!
//! Linux 走 system bus：WiFi 用 NetworkManager（`org.freedesktop.NetworkManager`），
//! 蓝牙用 BlueZ（`org.bluez`）。不引第三方客户端库（只用已有的 libdbus），
//! 也不启任何子进程；其余平台落 `ERR_UNSUPPORTED`。

#ifndef ARCHOERA_NETCTL_H
#define ARCHOERA_NETCTL_H

#include <cstdint>

#include "archoera_platform.h"

namespace archoera {
namespace netctl {

bool wifiAvailable();
bool bluetoothAvailable();

int32_t wifiState(AplWifiState* out);
int32_t wifiScan(AplWifiNetwork* out, uint32_t max, uint32_t* count);
int32_t wifiConnect(const char* ssid, const char* psk);
int32_t wifiDisconnect();
int32_t wifiSetEnabled(int32_t on);
int32_t wifiForget(const char* ssid);

int32_t btScanStart();
int32_t btScanStop();
int32_t btDevices(AplBtDevice* out, uint32_t max, uint32_t* count);
int32_t btPair(const char* address);
int32_t btConnect(const char* address);
int32_t btDisconnect(const char* address);
int32_t btForget(const char* address);
int32_t btSetEnabled(int32_t on);

void shutdown();

}  // namespace netctl
}  // namespace archoera

#endif  // ARCHOERA_NETCTL_H

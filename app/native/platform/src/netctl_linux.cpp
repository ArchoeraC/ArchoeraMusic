// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 网络（WiFi）与蓝牙控制（Linux 实现）。
//!
//! 全部走 system bus，不启子进程、不引第三方客户端库（只用已有的 libdbus）：
//! - WiFi：NetworkManager（`GetDevices` → 无线设备 → `ActiveAccessPoint` / `Ip4Config`
//!   / `GetAllAccessPoints` / `RequestScan`；总开关 `WirelessEnabled`；断开 `Device.Disconnect`）；
//! - 蓝牙：BlueZ（`ObjectManager.GetManagedObjects` 列 `Device1`；`Adapter1` 的
//!   `StartDiscovery` / `StopDiscovery` / `Powered`）。
//!
//! 连接/配对（`AddAndActivateConnection` 的设置字典、BlueZ 配对 agent）见后续切片。

#include "netctl.h"

#if defined(__linux__)

#include "core.h"

#include <dbus/dbus.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <strings.h>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace archoera {
namespace netctl {
namespace {

std::mutex g_mtx;
DBusConnection* g_bus = nullptr;

// 输出结构里的 AplString 指向这些缓冲；仅在该次调用后、下一次同类调用前有效。
std::vector<std::string> g_strs;
std::string g_wifi_ssid;
std::string g_wifi_ip;
std::string g_wifi_sec;

DBusConnection* busLocked() {
    if (g_bus != nullptr) return g_bus;
    DBusError err;
    dbus_error_init(&err);
    g_bus = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    return g_bus;
}

DBusMessage* callLocked(DBusConnection* bus, const char* dest, const char* path,
                        const char* iface, const char* method, int timeout_ms = 3000) {
    DBusMessage* msg = dbus_message_new_method_call(dest, path, iface, method);
    if (msg == nullptr) return nullptr;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, timeout_ms, &err);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    dbus_message_unref(msg);
    return reply;
}

// 直接构造 Properties.Get 调用（含 iface/name 参数）。
DBusMessage* getPropMsg(const char* dest, const char* path, const char* iface, const char* name) {
    DBusMessage* msg = dbus_message_new_method_call(
        dest, path, "org.freedesktop.DBus.Properties", "Get");
    if (msg == nullptr) return nullptr;
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &name,
                             DBUS_TYPE_INVALID);
    return msg;
}

bool readProp(DBusConnection* bus, const char* dest, const char* path, const char* iface,
              const char* name, int type, void* out, std::string* strOut) {
    DBusMessage* msg = getPropMsg(dest, path, iface, name);
    if (msg == nullptr) return false;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 3000, &err);
    dbus_message_unref(msg);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    if (reply == nullptr) return false;

    DBusMessageIter it;
    bool ok = false;
    if (dbus_message_iter_init(reply, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        DBusMessageIter var;
        dbus_message_iter_recurse(&it, &var);
        if (dbus_message_iter_get_arg_type(&var) == type) {
            if (type == DBUS_TYPE_STRING || type == DBUS_TYPE_OBJECT_PATH) {
                const char* s = nullptr;
                dbus_message_iter_get_basic(&var, &s);
                if (s != nullptr && strOut != nullptr) *strOut = s;
                ok = true;
            } else {
                dbus_message_iter_get_basic(&var, out);
                ok = true;
            }
        }
    }
    dbus_message_unref(reply);
    return ok;
}

// 读数组属性（对象路径数组）→ 列表。
bool readObjectPathArray(DBusConnection* bus, const char* dest, const char* path,
                         const char* iface, const char* name,
                         std::vector<std::string>* out) {
    DBusMessage* msg = getPropMsg(dest, path, iface, name);
    if (msg == nullptr) return false;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 3000, &err);
    dbus_message_unref(msg);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    if (reply == nullptr) return false;

    DBusMessageIter it;
    bool ok = false;
    if (dbus_message_iter_init(reply, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        DBusMessageIter var;
        dbus_message_iter_recurse(&it, &var);
        if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_ARRAY) {
            DBusMessageIter arr;
            for (dbus_message_iter_recurse(&var, &arr);
                 dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_OBJECT_PATH;
                 dbus_message_iter_next(&arr)) {
                const char* s = nullptr;
                dbus_message_iter_get_basic(&arr, &s);
                if (s != nullptr) out->emplace_back(s);
            }
            ok = true;
        }
    }
    dbus_message_unref(reply);
    return ok;
}

const char* kNm = "org.freedesktop.NetworkManager";
const char* kNmPath = "/org/freedesktop/NetworkManager";
const char* kNmDev = "org.freedesktop.NetworkManager.Device";
const char* kNmWireless = "org.freedesktop.NetworkManager.Device.Wireless";
const char* kNmAp = "org.freedesktop.NetworkManager.AccessPoint";

// NM 设备类型：2 = Wi-Fi。
constexpr uint32_t kDeviceTypeWifi = 2;

// 返回无线设备对象路径（无则空）。
std::string wirelessDeviceLocked(DBusConnection* bus) {
    std::vector<std::string> devices;
    if (!readObjectPathArray(bus, kNm, kNmPath, kNm, "Devices", &devices)) return "";
    for (const std::string& d : devices) {
        uint32_t type = 0;
        if (!readProp(bus, kNm, d.c_str(), kNmDev, "DeviceType", DBUS_TYPE_UINT32, &type, nullptr)) continue;
        if (type != kDeviceTypeWifi) continue;
        return d;
    }
    return "";
}

int32_t wifiSecurityFromAp(DBusConnection* bus, const std::string& ap) {
    uint32_t flags = 0;
    uint32_t wpa = 0;
    uint32_t rsn = 0;
    readProp(bus, kNm, ap.c_str(), kNmAp, "Flags", DBUS_TYPE_UINT32, &flags, nullptr);
    readProp(bus, kNm, ap.c_str(), kNmAp, "WpaFlags", DBUS_TYPE_UINT32, &wpa, nullptr);
    readProp(bus, kNm, ap.c_str(), kNmAp, "RsnFlags", DBUS_TYPE_UINT32, &rsn, nullptr);
    const bool privacy = (flags & 0x1u) != 0;  // NM_802_11_AP_FLAGS_PRIVACY
    if (!privacy) return APL_WIFI_SEC_OPEN;
    if (wpa == 0 && rsn == 0) return APL_WIFI_SEC_WEP;
    return APL_WIFI_SEC_PSK;
}

std::string readApSsid(DBusConnection* bus, const std::string& ap) {
    DBusMessage* msg = getPropMsg(kNm, ap.c_str(), kNmAp, "Ssid");
    if (msg == nullptr) return "";
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 3000, &err);
    dbus_message_unref(msg);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    if (reply == nullptr) return "";
    std::string ssid;
    DBusMessageIter it;
    if (dbus_message_iter_init(reply, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        DBusMessageIter var;
        dbus_message_iter_recurse(&it, &var);
        if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_ARRAY) {
            DBusMessageIter arr;
            for (dbus_message_iter_recurse(&var, &arr);
                 dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_BYTE;
                 dbus_message_iter_next(&arr)) {
                unsigned char b = 0;
                dbus_message_iter_get_basic(&arr, &b);
                ssid.push_back(static_cast<char>(b));
            }
        }
    }
    dbus_message_unref(reply);
    return ssid;
}

// ── 蓝牙常量 ────────────────────────────────────────────────────────
const char* kBlueZ = "org.bluez";
const char* kAdapter1 = "org.bluez.Adapter1";
const char* kDevice1 = "org.bluez.Device1";

// 从 GetManagedObjects 里取出第一块适配器路径。
std::string adapterPathLocked(DBusConnection* bus) {
    DBusMessage* reply = callLocked(bus, kBlueZ, "/", "org.freedesktop.DBus.ObjectManager",
                                    "GetManagedObjects", 5000);
    if (reply == nullptr) return "";
    std::string found;
    DBusMessageIter root;
    if (dbus_message_iter_init(reply, &root) && dbus_message_iter_get_arg_type(&root) == DBUS_TYPE_ARRAY) {
        DBusMessageIter obj;
        for (dbus_message_iter_recurse(&root, &obj);
             dbus_message_iter_get_arg_type(&obj) == DBUS_TYPE_DICT_ENTRY;
             dbus_message_iter_next(&obj)) {
            DBusMessageIter entry;
            dbus_message_iter_recurse(&obj, &entry);
            const char* path = nullptr;
            dbus_message_iter_get_basic(&entry, &path);
            dbus_message_iter_next(&entry);
            DBusMessageIter ifaces;
            dbus_message_iter_recurse(&entry, &ifaces);
            for (; dbus_message_iter_get_arg_type(&ifaces) == DBUS_TYPE_DICT_ENTRY;
                 dbus_message_iter_next(&ifaces)) {
                DBusMessageIter ie;
                dbus_message_iter_recurse(&ifaces, &ie);
                const char* iface = nullptr;
                dbus_message_iter_get_basic(&ie, &iface);
                if (iface != nullptr && path != nullptr && std::strcmp(iface, kAdapter1) == 0) {
                    found = path;
                    break;
                }
            }
            if (!found.empty()) break;
        }
    }
    dbus_message_unref(reply);
    return found;
}

}  // namespace

void shutdown() {
    std::lock_guard<std::mutex> lock(g_mtx);
    if (g_bus != nullptr) {
        dbus_connection_close(g_bus);
        dbus_connection_unref(g_bus);
        g_bus = nullptr;
    }
}

bool wifiAvailable() {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return false;
    return !wirelessDeviceLocked(bus).empty();
}

bool bluetoothAvailable() {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return false;
    DBusMessage* reply = callLocked(bus, kBlueZ, "/", "org.freedesktop.DBus.ObjectManager",
                                    "GetManagedObjects", 5000);
    if (reply == nullptr) return false;
    dbus_message_unref(reply);
    return true;
}

int32_t wifiState(AplWifiState* out) {
    if (out == nullptr) return ERR_STATE;
    *out = AplWifiState{};
    out->signal = -1;

    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;

    bool enabled = false;
    readProp(bus, kNm, kNmPath, kNm, "WirelessEnabled", DBUS_TYPE_BOOLEAN, &enabled, nullptr);
    const std::string dev = wirelessDeviceLocked(bus);
    if (dev.empty()) return ERR_UNSUPPORTED;
    out->present = 1;
    out->enabled = enabled ? 1 : 0;

    std::string ap;
    if (!readProp(bus, kNm, dev.c_str(), kNmWireless, "ActiveAccessPoint", DBUS_TYPE_OBJECT_PATH, nullptr, &ap)
        || ap.empty() || ap == "/") {
        return OK;  // 未连接
    }
    g_wifi_ssid = readApSsid(bus, ap);
    unsigned char strength = 0;
    readProp(bus, kNm, ap.c_str(), kNmAp, "Strength", DBUS_TYPE_BYTE, &strength, nullptr);
    out->connected = 1;
    out->signal = strength;
    g_wifi_sec = wifiSecurityFromAp(bus, ap) == APL_WIFI_SEC_OPEN ? "open" : "psk";
    out->security.data = g_wifi_sec.c_str();
    out->security.len = g_wifi_sec.size();

    // 清掉上一条连接的残留（断开后不应还显示旧地址）。
    g_wifi_ip.clear();

    // IPv4 地址：AddressData 的类型是 **aa{sv}**（每项是
    //   {'address': <'192.168.50.5'>, 'prefix': <u32>}），
    // 不是 aau —— 早期版本按 aau 解析 uint32，于是永远读不到、IP 恒为空。
    std::string ip4;
    if (readProp(bus, kNm, dev.c_str(), kNmDev, "Ip4Config", DBUS_TYPE_OBJECT_PATH, nullptr, &ip4) &&
        !ip4.empty() && ip4 != "/") {
        DBusMessage* msg = getPropMsg(kNm, ip4.c_str(), "org.freedesktop.NetworkManager.IP4Config",
                                     "AddressData");
        if (msg != nullptr) {
            DBusError err;
            dbus_error_init(&err);
            DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 3000, &err);
            dbus_message_unref(msg);
            if (dbus_error_is_set(&err)) dbus_error_free(&err);
            if (reply != nullptr) {
                DBusMessageIter it;
                if (dbus_message_iter_init(reply, &it) &&
                    dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter var;
                    dbus_message_iter_recurse(&it, &var);
                    if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_ARRAY) {
                        DBusMessageIter arr;
                        for (dbus_message_iter_recurse(&var, &arr);
                             dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_ARRAY;
                             dbus_message_iter_next(&arr)) {
                            // 每项是 a{sv}：找到 key "address"（variant 内为字符串）。
                            DBusMessageIter dict;
                            dbus_message_iter_recurse(&arr, &dict);
                            bool got = false;
                            for (;
                                 dbus_message_iter_get_arg_type(&dict) == DBUS_TYPE_DICT_ENTRY;
                                 dbus_message_iter_next(&dict)) {
                                DBusMessageIter entry;
                                dbus_message_iter_recurse(&dict, &entry);
                                if (dbus_message_iter_get_arg_type(&entry) != DBUS_TYPE_STRING) continue;
                                const char* key = nullptr;
                                dbus_message_iter_get_basic(&entry, &key);
                                if (key == nullptr || std::strcmp(key, "address") != 0) continue;
                                DBusMessageIter val;
                                dbus_message_iter_next(&entry);
                                dbus_message_iter_recurse(&entry, &val);  // 解开 variant
                                if (dbus_message_iter_get_arg_type(&val) == DBUS_TYPE_STRING) {
                                    const char* addr = nullptr;
                                    dbus_message_iter_get_basic(&val, &addr);
                                    if (addr != nullptr) {
                                        g_wifi_ip = addr;
                                        got = true;
                                    }
                                }
                                break;
                            }
                            if (got) break;  // 只需要第一个地址
                        }
                    }
                }
                dbus_message_unref(reply);
            }
        }
    }

    if (!g_wifi_ssid.empty()) {
        out->ssid.data = g_wifi_ssid.c_str();
        out->ssid.len = g_wifi_ssid.size();
    }
    if (!g_wifi_ip.empty()) {
        out->ip.data = g_wifi_ip.c_str();
        out->ip.len = g_wifi_ip.size();
    }
    return OK;
}

// 读一个连接 profile 的 (id, type)。
// ⚠ 新版 NetworkManager **不再暴露 Settings.Connection 的 Id/Type 属性**（对象上只剩
// GetSettings 方法与 VersionId），按属性读会拿到空值 —— 这正是「已保存」标记恒为 0
// 的原因。凡是要判断 profile 身份的地方都必须走 GetSettings。
bool readConnectionIdentity(DBusConnection* bus, const char* path, std::string* id,
                            std::string* type) {
    DBusMessage* msg = dbus_message_new_method_call(
        kNm, path, "org.freedesktop.NetworkManager.Settings.Connection", "GetSettings");
    if (msg == nullptr) return false;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* r = dbus_connection_send_with_reply_and_block(bus, msg, 5000, &err);
    dbus_message_unref(msg);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    if (r == nullptr) return false;

    bool seen = false;
    DBusMessageIter root;
    if (dbus_message_iter_init(r, &root) && dbus_message_iter_get_arg_type(&root) == DBUS_TYPE_ARRAY) {
        DBusMessageIter se;
        for (dbus_message_iter_recurse(&root, &se);
             dbus_message_iter_get_arg_type(&se) == DBUS_TYPE_DICT_ENTRY;
             dbus_message_iter_next(&se)) {
            DBusMessageIter secEntry;
            dbus_message_iter_recurse(&se, &secEntry);
            const char* secName = nullptr;
            dbus_message_iter_get_basic(&secEntry, &secName);
            if (secName == nullptr || std::strcmp(secName, "connection") != 0) continue;
            dbus_message_iter_next(&secEntry);
            DBusMessageIter props;
            dbus_message_iter_recurse(&secEntry, &props);
            for (; dbus_message_iter_get_arg_type(&props) == DBUS_TYPE_DICT_ENTRY;
                 dbus_message_iter_next(&props)) {
                DBusMessageIter pe;
                dbus_message_iter_recurse(&props, &pe);
                const char* key = nullptr;
                dbus_message_iter_get_basic(&pe, &key);
                if (key == nullptr) continue;
                dbus_message_iter_next(&pe);
                DBusMessageIter var;
                dbus_message_iter_recurse(&pe, &var);
                if (dbus_message_iter_get_arg_type(&var) != DBUS_TYPE_STRING) continue;
                const char* s = nullptr;
                dbus_message_iter_get_basic(&var, &s);
                if (s == nullptr) continue;
                if (std::strcmp(key, "id") == 0 && id != nullptr) *id = s;
                if (std::strcmp(key, "type") == 0 && type != nullptr) *type = s;
                seen = true;
            }
        }
    }
    dbus_message_unref(r);
    return seen;
}

int32_t wifiScan(AplWifiNetwork* out, uint32_t max, uint32_t* count) {
    if (out == nullptr || count == nullptr) return ERR_STATE;
    *count = 0;

    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string dev = wirelessDeviceLocked(bus);
    if (dev.empty()) return ERR_UNSUPPORTED;

    // 触发一次扫描（异步；这里不等待完成，直接读现有列表，UI 下次刷新即可）。
    DBusMessage* scan = dbus_message_new_method_call(kNm, dev.c_str(), kNmWireless, "RequestScan");
    if (scan != nullptr) {
        DBusMessageIter it;
        dbus_message_iter_init_append(scan, &it);
        DBusMessageIter dict;
        dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &dict);
        dbus_message_iter_close_container(&it, &dict);
        DBusError err;
        dbus_error_init(&err);
        DBusMessage* r = dbus_connection_send_with_reply_and_block(bus, scan, 2000, &err);
        if (r != nullptr) dbus_message_unref(r);
        if (dbus_error_is_set(&err)) dbus_error_free(&err);
        dbus_message_unref(scan);
    }

    std::vector<std::string> aps;
    readObjectPathArray(bus, kNm, dev.c_str(), kNmWireless, "AccessPoints", &aps);

    // 同一 SSID 只留信号最强的那条。
    std::map<std::string, int> best;       // ssid → 索引
    g_strs.clear();
    std::vector<AplWifiNetwork> list;
    std::vector<std::string> ssids;
    std::vector<int> secs;
    std::vector<int> strengths;
    std::vector<uint32_t> freqs;

    // 当前活动 AP（用于标 connected）与该适配器上「已保存」的无线 SSID 集合
    // （用于标 saved —— 之前这两项恒为 0，导致 UI 里「忘记」按钮永不出现）。
    std::string active_ap;
    readProp(bus, kNm, dev.c_str(), kNmWireless, "ActiveAccessPoint", DBUS_TYPE_OBJECT_PATH,
             nullptr, &active_ap);
    std::set<std::string> saved_ssids;
    {
        // 已保存的无线连接：Settings.Connections（ao）→ 每个 profile 经 GetSettings
        // 取 connection.type / connection.id（Id 惯例上等于 SSID，wifiForget 也按它匹配）。
        std::vector<std::string> profiles;
        if (readObjectPathArray(bus, kNm, "/org/freedesktop/NetworkManager/Settings",
                                "org.freedesktop.NetworkManager.Settings", "Connections",
                                &profiles)) {
            for (const std::string& p : profiles) {
                std::string id;
                std::string kind;
                if (!readConnectionIdentity(bus, p.c_str(), &id, &kind)) continue;
                if (kind != "802-11-wireless" || id.empty()) continue;
                saved_ssids.insert(id);
            }
        }
    }

    for (const std::string& ap : aps) {
        std::string ssid = readApSsid(bus, ap);
        if (ssid.empty()) continue;  // 隐藏网络跳过
        unsigned char strength = 0;
        readProp(bus, kNm, ap.c_str(), kNmAp, "Strength", DBUS_TYPE_BYTE, &strength, nullptr);
        uint32_t freq = 0;
        readProp(bus, kNm, ap.c_str(), kNmAp, "Frequency", DBUS_TYPE_UINT32, &freq, nullptr);
        const int sec = wifiSecurityFromAp(bus, ap);
        auto it = best.find(ssid);
        if (it == best.end()) {
            best[ssid] = static_cast<int>(ssids.size());
            ssids.push_back(ssid);
            secs.push_back(sec);
            strengths.push_back(strength);
            freqs.push_back(freq);
        } else if (strength > strengths[it->second]) {
            strengths[it->second] = strength;
            secs[it->second] = sec;
            freqs[it->second] = freq;
        }
    }

    uint32_t idx = 0;
    for (size_t i = 0; i < ssids.size() && idx < max; ++i) {
        AplWifiNetwork* n = &out[idx];
        *n = AplWifiNetwork{};
        n->signal = strengths[i];
        n->security = secs[i];
        n->frequency_mhz = static_cast<int32_t>(freqs[i]);
        n->saved = saved_ssids.count(ssids[i]) > 0 ? 1 : 0;
        n->connected = 1;  // 先置位，下面按需清掉
        g_strs.push_back(ssids[i]);
        n->ssid.data = g_strs.back().c_str();
        n->ssid.len = g_strs.back().size();
        ++idx;
    }
    // connected：只有与 ActiveAccessPoint 的 SSID 一致才算。
    if (!active_ap.empty()) {
        const std::string active_ssid = readApSsid(bus, active_ap);
        for (uint32_t i = 0; i < idx; ++i) {
            out[i].connected = (out[i].ssid.data != nullptr &&
                                active_ssid == std::string(out[i].ssid.data, out[i].ssid.len))
                                   ? 1
                                   : 0;
        }
    } else {
        for (uint32_t i = 0; i < idx; ++i) out[i].connected = 0;
    }
    *count = idx;
    return OK;
}

int32_t wifiSetEnabled(int32_t on) {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;

    DBusMessage* msg = dbus_message_new_method_call(
        kNm, kNmPath, "org.freedesktop.DBus.Properties", "Set");
    if (msg == nullptr) return ERR_BACKEND;
    const char* iface = kNm;
    const char* name = "WirelessEnabled";
    dbus_bool_t value = on ? 1 : 0;
    DBusMessageIter it;
    dbus_message_iter_init_append(msg, &it);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &iface);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &name);
    DBusMessageIter var;
    dbus_message_iter_open_container(&it, DBUS_TYPE_VARIANT, "b", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_BOOLEAN, &value);
    dbus_message_iter_close_container(&it, &var);

    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 3000, &err);
    const bool ok = reply != nullptr;
    if (reply != nullptr) dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    dbus_message_unref(msg);
    return ok ? OK : ERR_BACKEND;
}

int32_t wifiDisconnect() {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string dev = wirelessDeviceLocked(bus);
    if (dev.empty()) return ERR_UNSUPPORTED;
    DBusMessage* reply = callLocked(bus, kNm, dev.c_str(), kNmDev, "Disconnect");
    if (reply == nullptr) return ERR_BACKEND;
    dbus_message_unref(reply);
    return OK;
}


// ── 设置字典小工具（用于 AddAndActivateConnection）────────────────────
void putStr(DBusMessageIter* props, const char* key, const char* value) {
    DBusMessageIter entry, var;
    const char* k = key;
    dbus_message_iter_open_container(props, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_STRING, &value);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(props, &entry);
}

void putBytes(DBusMessageIter* props, const char* key, const char* data, int len) {
    DBusMessageIter entry, var, arr;
    const char* k = key;
    dbus_message_iter_open_container(props, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "ay", &var);
    dbus_message_iter_open_container(&var, DBUS_TYPE_ARRAY, "y", &arr);
    for (int i = 0; i < len; ++i) {
        const unsigned char b = static_cast<unsigned char>(data[i]);
        dbus_message_iter_append_basic(&arr, DBUS_TYPE_BYTE, &b);
    }
    dbus_message_iter_close_container(&var, &arr);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(props, &entry);
}

void openSection(DBusMessageIter* settings, const char* name, DBusMessageIter* sect) {
    const char* n = name;
    dbus_message_iter_open_container(settings, DBUS_TYPE_DICT_ENTRY, nullptr, sect);
    dbus_message_iter_append_basic(sect, DBUS_TYPE_STRING, &n);
}

// 找某个 SSID 对应的 AP 对象路径。
std::string findApBySsid(DBusConnection* bus, const std::string& dev, const std::string& ssid) {
    std::vector<std::string> aps;
    readObjectPathArray(bus, kNm, dev.c_str(), kNmWireless, "AccessPoints", &aps);
    for (const std::string& ap : aps) {
        if (readApSsid(bus, ap) == ssid) return ap;
    }
    return "";
}

std::string randomUuid() {
    FILE* f = std::fopen("/proc/sys/kernel/random/uuid", "r");
    if (f == nullptr) return "00000000-0000-4000-8000-000000000000";
    char buf[64] = {0};
    if (std::fgets(buf, sizeof(buf), f) == nullptr) buf[0] = '\0';
    std::fclose(f);
    std::string s(buf);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    return s.empty() ? "00000000-0000-4000-8000-000000000000" : s;
}

int32_t wifiConnect(const char* ssid, const char* psk) {
    if (ssid == nullptr || ssid[0] == '\0') return ERR_STATE;

    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string dev = wirelessDeviceLocked(bus);
    if (dev.empty()) return ERR_UNSUPPORTED;
    const std::string ap = findApBySsid(bus, dev, ssid);
    if (ap.empty()) return ERR_STATE;  // 还没扫到这个 SSID，UI 应先扫描

    const bool needPsk = (psk != nullptr && psk[0] != '\0');
    const std::string uuid = randomUuid();

    DBusMessage* msg = dbus_message_new_method_call(kNm, kNmPath, kNm,
                                                    "AddAndActivateConnection");
    if (msg == nullptr) return ERR_BACKEND;
    DBusMessageIter it, settings, sect, props;
    dbus_message_iter_init_append(msg, &it);
    const char* devPath = dev.c_str();
    const char* apPath = ap.c_str();
    dbus_message_iter_append_basic(&it, DBUS_TYPE_OBJECT_PATH, &devPath);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_OBJECT_PATH, &apPath);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sa{sv}}", &settings);

    // 「connection」
    openSection(&settings, "connection", &sect);
    dbus_message_iter_open_container(&sect, DBUS_TYPE_ARRAY, "{sv}", &props);
    putStr(&props, "id", ssid);
    putStr(&props, "type", "802-11-wireless");
    putStr(&props, "uuid", uuid.c_str());
    dbus_message_iter_close_container(&sect, &props);
    dbus_message_iter_close_container(&settings, &sect);

    // 「802-11-wireless」（ssid 是字节数组）
    openSection(&settings, "802-11-wireless", &sect);
    dbus_message_iter_open_container(&sect, DBUS_TYPE_ARRAY, "{sv}", &props);
    putBytes(&props, "ssid", ssid, static_cast<int>(std::strlen(ssid)));
    putStr(&props, "mode", "infrastructure");
    dbus_message_iter_close_container(&sect, &props);
    dbus_message_iter_close_container(&settings, &sect);

    // 「802-11-wireless-security」（仅加密网络）
    if (needPsk) {
        openSection(&settings, "802-11-wireless-security", &sect);
        dbus_message_iter_open_container(&sect, DBUS_TYPE_ARRAY, "{sv}", &props);
        putStr(&props, "key-mgmt", "wpa-psk");
        putStr(&props, "psk", psk);
        dbus_message_iter_close_container(&sect, &props);
        dbus_message_iter_close_container(&settings, &sect);
    }

    // 「ipv4」/「ipv6」都自动
    openSection(&settings, "ipv4", &sect);
    dbus_message_iter_open_container(&sect, DBUS_TYPE_ARRAY, "{sv}", &props);
    putStr(&props, "method", "auto");
    dbus_message_iter_close_container(&sect, &props);
    dbus_message_iter_close_container(&settings, &sect);
    openSection(&settings, "ipv6", &sect);
    dbus_message_iter_open_container(&sect, DBUS_TYPE_ARRAY, "{sv}", &props);
    putStr(&props, "method", "auto");
    dbus_message_iter_close_container(&sect, &props);
    dbus_message_iter_close_container(&settings, &sect);

    dbus_message_iter_close_container(&it, &settings);

    DBusError err;
    dbus_error_init(&err);
    // 连接可能较慢（扫描/关联/认证），给足超时。
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 30000, &err);
    const bool ok = reply != nullptr;
    if (reply != nullptr) dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) {
        if (std::strstr(err.message, "AlreadyExists") != nullptr) {
            dbus_error_free(&err);
            dbus_message_unref(msg);
            return OK;
        }
        dbus_error_free(&err);
    }
    dbus_message_unref(msg);
    return ok ? OK : ERR_BACKEND;
}

int32_t wifiForget(const char* ssid) {
    if (ssid == nullptr || ssid[0] == '\0') return ERR_STATE;
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;

    // Settings.ListConnections → 逐个读 GetSettings，匹配 connection.id 后 Delete。
    DBusMessage* listMsg = dbus_message_new_method_call(
        kNm, "/org/freedesktop/NetworkManager/Settings",
        "org.freedesktop.NetworkManager.Settings", "ListConnections");
    if (listMsg == nullptr) return ERR_BACKEND;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, listMsg, 5000, &err);
    dbus_message_unref(listMsg);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    if (reply == nullptr) return ERR_BACKEND;

    std::vector<std::string> conns;
    DBusMessageIter it;
    if (dbus_message_iter_init(reply, &it) && dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_ARRAY) {
        DBusMessageIter arr;
        for (dbus_message_iter_recurse(&it, &arr);
             dbus_message_iter_get_arg_type(&arr) == DBUS_TYPE_OBJECT_PATH;
             dbus_message_iter_next(&arr)) {
            const char* p = nullptr;
            dbus_message_iter_get_basic(&arr, &p);
            if (p != nullptr) conns.emplace_back(p);
        }
    }
    dbus_message_unref(reply);

    for (const std::string& c : conns) {
        DBusMessage* getMsg = dbus_message_new_method_call(
            kNm, c.c_str(), "org.freedesktop.NetworkManager.Settings.Connection", "GetSettings");
        if (getMsg == nullptr) continue;
        DBusError e2;
        dbus_error_init(&e2);
        DBusMessage* r = dbus_connection_send_with_reply_and_block(bus, getMsg, 5000, &e2);
        dbus_message_unref(getMsg);
        if (dbus_error_is_set(&e2)) dbus_error_free(&e2);
        if (r == nullptr) continue;

        // 解析 a{sa{sv}} 里的 connection.id
        std::string id;
        DBusMessageIter root;
        if (dbus_message_iter_init(r, &root) && dbus_message_iter_get_arg_type(&root) == DBUS_TYPE_ARRAY) {
            DBusMessageIter se;
            for (dbus_message_iter_recurse(&root, &se);
                 dbus_message_iter_get_arg_type(&se) == DBUS_TYPE_DICT_ENTRY;
                 dbus_message_iter_next(&se)) {
                DBusMessageIter secEntry;
                dbus_message_iter_recurse(&se, &secEntry);
                const char* secName = nullptr;
                dbus_message_iter_get_basic(&secEntry, &secName);
                dbus_message_iter_next(&secEntry);
                DBusMessageIter props;
                dbus_message_iter_recurse(&secEntry, &props);
                if (secName == nullptr || std::strcmp(secName, "connection") != 0) continue;
                for (; dbus_message_iter_get_arg_type(&props) == DBUS_TYPE_DICT_ENTRY;
                     dbus_message_iter_next(&props)) {
                    DBusMessageIter pe;
                    dbus_message_iter_recurse(&props, &pe);
                    const char* key = nullptr;
                    dbus_message_iter_get_basic(&pe, &key);
                    if (key == nullptr || std::strcmp(key, "id") != 0) continue;
                    dbus_message_iter_next(&pe);
                    DBusMessageIter var;
                    dbus_message_iter_recurse(&pe, &var);
                    if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_STRING) {
                        const char* s = nullptr;
                        dbus_message_iter_get_basic(&var, &s);
                        if (s != nullptr) id = s;
                    }
                }
            }
        }
        dbus_message_unref(r);
        if (id != ssid) continue;

        DBusMessage* del = dbus_message_new_method_call(
            kNm, c.c_str(), "org.freedesktop.NetworkManager.Settings.Connection", "Delete");
        if (del == nullptr) return ERR_BACKEND;
        DBusError e3;
        dbus_error_init(&e3);
        DBusMessage* rd = dbus_connection_send_with_reply_and_block(bus, del, 5000, &e3);
        const bool ok = rd != nullptr;
        if (rd != nullptr) dbus_message_unref(rd);
        if (dbus_error_is_set(&e3)) dbus_error_free(&e3);
        dbus_message_unref(del);
        return ok ? OK : ERR_BACKEND;
    }
    return ERR_STATE;  // 没有该 SSID 的已保存配置
}

int32_t btScanStart() {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string adapter = adapterPathLocked(bus);
    if (adapter.empty()) return ERR_UNSUPPORTED;
    DBusMessage* reply = callLocked(bus, kBlueZ, adapter.c_str(), kAdapter1, "StartDiscovery", 15000);
    if (reply == nullptr) return ERR_BACKEND;
    dbus_message_unref(reply);
    return OK;
}

int32_t btScanStop() {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string adapter = adapterPathLocked(bus);
    if (adapter.empty()) return ERR_UNSUPPORTED;
    DBusMessage* reply = callLocked(bus, kBlueZ, adapter.c_str(), kAdapter1, "StopDiscovery");
    if (reply == nullptr) return ERR_BACKEND;
    dbus_message_unref(reply);
    return OK;
}

int32_t btDevices(AplBtDevice* out, uint32_t max, uint32_t* count) {
    if (out == nullptr || count == nullptr) return ERR_STATE;
    *count = 0;

    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    DBusMessage* reply = callLocked(bus, kBlueZ, "/", "org.freedesktop.DBus.ObjectManager",
                                    "GetManagedObjects", 5000);
    if (reply == nullptr) return ERR_UNSUPPORTED;

    std::vector<std::string> addrs;
    std::vector<std::string> names;
    std::vector<int> paired;
    std::vector<int> connected;
    std::vector<int> rssi;

    DBusMessageIter root;
    if (dbus_message_iter_init(reply, &root) &&
        dbus_message_iter_get_arg_type(&root) == DBUS_TYPE_ARRAY) {
        DBusMessageIter obj;
        for (dbus_message_iter_recurse(&root, &obj);
             dbus_message_iter_get_arg_type(&obj) == DBUS_TYPE_DICT_ENTRY;
             dbus_message_iter_next(&obj)) {
            DBusMessageIter entry;
            dbus_message_iter_recurse(&obj, &entry);
            dbus_message_iter_next(&entry);  // 跳过对象路径
            DBusMessageIter ifaces;
            dbus_message_iter_recurse(&entry, &ifaces);
            for (; dbus_message_iter_get_arg_type(&ifaces) == DBUS_TYPE_DICT_ENTRY;
                 dbus_message_iter_next(&ifaces)) {
                DBusMessageIter ie;
                dbus_message_iter_recurse(&ifaces, &ie);
                const char* iface = nullptr;
                dbus_message_iter_get_basic(&ie, &iface);
                if (iface == nullptr || std::strcmp(iface, kDevice1) != 0) continue;

                std::string name;
                std::string alias;
                std::string addr;
                dbus_bool_t pairedV = 0;
                dbus_bool_t connectedV = 0;
                dbus_int16_t rssiV = 0;
                dbus_message_iter_next(&ie);
                DBusMessageIter props;
                dbus_message_iter_recurse(&ie, &props);
                for (; dbus_message_iter_get_arg_type(&props) == DBUS_TYPE_DICT_ENTRY;
                     dbus_message_iter_next(&props)) {
                    DBusMessageIter pe;
                    dbus_message_iter_recurse(&props, &pe);
                    const char* key = nullptr;
                    dbus_message_iter_get_basic(&pe, &key);
                    if (key == nullptr) continue;
                    dbus_message_iter_next(&pe);
                    DBusMessageIter var;
                    dbus_message_iter_recurse(&pe, &var);
                    const int vt = dbus_message_iter_get_arg_type(&var);
                    if (std::strcmp(key, "Address") == 0 && vt == DBUS_TYPE_STRING) {
                        const char* s = nullptr;
                        dbus_message_iter_get_basic(&var, &s);
                        if (s != nullptr) addr = s;
                    } else if (std::strcmp(key, "Alias") == 0 && vt == DBUS_TYPE_STRING) {
                        const char* s = nullptr;
                        dbus_message_iter_get_basic(&var, &s);
                        if (s != nullptr) alias = s;
                    } else if (std::strcmp(key, "Name") == 0 && vt == DBUS_TYPE_STRING) {
                        const char* s = nullptr;
                        dbus_message_iter_get_basic(&var, &s);
                        if (s != nullptr) name = s;
                    } else if (std::strcmp(key, "Paired") == 0 && vt == DBUS_TYPE_BOOLEAN) {
                        dbus_message_iter_get_basic(&var, &pairedV);
                    } else if (std::strcmp(key, "Connected") == 0 && vt == DBUS_TYPE_BOOLEAN) {
                        dbus_message_iter_get_basic(&var, &connectedV);
                    } else if (std::strcmp(key, "RSSI") == 0 && vt == DBUS_TYPE_INT16) {
                        dbus_message_iter_get_basic(&var, &rssiV);
                    }
                }
                // 只列有可读名的设备（过滤掉无名内部对象）。
                const std::string display = !alias.empty() ? alias : name;
                if (addr.empty() || display.empty()) continue;
                addrs.push_back(addr);
                names.push_back(display);
                paired.push_back(pairedV ? 1 : 0);
                connected.push_back(connectedV ? 1 : 0);
                rssi.push_back(rssiV);
            }
        }
    }
    dbus_message_unref(reply);

    // 已连接的排前面，其余按信号强度。
    std::vector<size_t> order(addrs.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        if (connected[a] != connected[b]) return connected[a] > connected[b];
        return rssi[a] > rssi[b];
    });

    g_strs.clear();
    g_strs.reserve(addrs.size() * 2);
    uint32_t idx = 0;
    for (size_t k = 0; k < order.size() && idx < max; ++k) {
        const size_t i = order[k];
        AplBtDevice* d = &out[idx];
        *d = AplBtDevice{};
        d->paired = paired[i];
        d->connected = connected[i];
        d->rssi = rssi[i];
        g_strs.push_back(addrs[i]);
        g_strs.push_back(names[i]);
        d->address.data = g_strs[g_strs.size() - 2].c_str();
        d->address.len = g_strs[g_strs.size() - 2].size();
        d->name.data = g_strs[g_strs.size() - 1].c_str();
        d->name.len = g_strs[g_strs.size() - 1].size();
        ++idx;
    }
    *count = idx;
    return OK;
}

int32_t btSetEnabled(int32_t on) {
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string adapter = adapterPathLocked(bus);
    if (adapter.empty()) return ERR_UNSUPPORTED;

    DBusMessage* msg = dbus_message_new_method_call(
        kBlueZ, adapter.c_str(), "org.freedesktop.DBus.Properties", "Set");
    if (msg == nullptr) return ERR_BACKEND;
    const char* iface = kAdapter1;
    const char* name = "Powered";
    dbus_bool_t value = on ? 1 : 0;
    DBusMessageIter it;
    dbus_message_iter_init_append(msg, &it);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &iface);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &name);
    DBusMessageIter var;
    dbus_message_iter_open_container(&it, DBUS_TYPE_VARIANT, "b", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_BOOLEAN, &value);
    dbus_message_iter_close_container(&it, &var);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 3000, &err);
    const bool ok = reply != nullptr;
    if (reply != nullptr) dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    dbus_message_unref(msg);
    return ok ? OK : ERR_BACKEND;
}

// 按 MAC 找 BlueZ 设备对象路径。
std::string btDevicePathLocked(DBusConnection* bus, const char* address) {
    if (address == nullptr) return "";
    DBusMessage* reply = callLocked(bus, kBlueZ, "/", "org.freedesktop.DBus.ObjectManager",
                                    "GetManagedObjects", 5000);
    if (reply == nullptr) return "";
    std::string found;
    DBusMessageIter root;
    if (dbus_message_iter_init(reply, &root) &&
        dbus_message_iter_get_arg_type(&root) == DBUS_TYPE_ARRAY) {
        DBusMessageIter obj;
        for (dbus_message_iter_recurse(&root, &obj);
             dbus_message_iter_get_arg_type(&obj) == DBUS_TYPE_DICT_ENTRY;
             dbus_message_iter_next(&obj)) {
            DBusMessageIter entry;
            dbus_message_iter_recurse(&obj, &entry);
            const char* path = nullptr;
            dbus_message_iter_get_basic(&entry, &path);
            dbus_message_iter_next(&entry);
            DBusMessageIter ifaces;
            dbus_message_iter_recurse(&entry, &ifaces);
            for (; dbus_message_iter_get_arg_type(&ifaces) == DBUS_TYPE_DICT_ENTRY;
                 dbus_message_iter_next(&ifaces)) {
                DBusMessageIter ie;
                dbus_message_iter_recurse(&ifaces, &ie);
                const char* iface = nullptr;
                dbus_message_iter_get_basic(&ie, &iface);
                if (iface == nullptr || path == nullptr || std::strcmp(iface, kDevice1) != 0) continue;
                dbus_message_iter_next(&ie);
                DBusMessageIter props;
                dbus_message_iter_recurse(&ie, &props);
                for (; dbus_message_iter_get_arg_type(&props) == DBUS_TYPE_DICT_ENTRY;
                     dbus_message_iter_next(&props)) {
                    DBusMessageIter pe;
                    dbus_message_iter_recurse(&props, &pe);
                    const char* key = nullptr;
                    dbus_message_iter_get_basic(&pe, &key);
                    if (key == nullptr || std::strcmp(key, "Address") != 0) continue;
                    dbus_message_iter_next(&pe);
                    DBusMessageIter var;
                    dbus_message_iter_recurse(&pe, &var);
                    const char* s = nullptr;
                    if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_STRING) {
                        dbus_message_iter_get_basic(&var, &s);
                    }
                    if (s != nullptr && strcasecmp(s, address) == 0) found = path;
                }
            }
            if (!found.empty()) break;
        }
    }
    dbus_message_unref(reply);
    return found;
}

int32_t btCallDevice(const char* address, const char* method, int timeout_ms) {
    if (address == nullptr || address[0] == '\0') return ERR_STATE;
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string path = btDevicePathLocked(bus, address);
    if (path.empty()) return ERR_STATE;
    DBusMessage* msg = dbus_message_new_method_call(kBlueZ, path.c_str(), kDevice1, method);
    if (msg == nullptr) return ERR_BACKEND;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, timeout_ms, &err);
    bool ok = reply != nullptr;
    // 已经处于目标状态（已配对/已连接）视为成功，避免 UI 报假错误。
    if (!ok && dbus_error_is_set(&err) && err.name != nullptr &&
        (std::strstr(err.name, "AlreadyExists") != nullptr ||
         std::strstr(err.name, "AlreadyConnected") != nullptr ||
         std::strstr(err.name, "InProgress") != nullptr)) {
        ok = true;
    }
    if (!ok && dbus_error_is_set(&err)) {
        std::fprintf(stderr, "[netctl] %s 失败: %s (%s)\n", method, err.name ? err.name : "?",
                     err.message ? err.message : "");
    }
    if (reply != nullptr) dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    dbus_message_unref(msg);
    return ok ? OK : ERR_BACKEND;
}

int32_t btPair(const char* address) {
    // 已配对设备会返回 AlreadyExists（视为成功）；**未配对**设备需要 BlueZ agent
    // （下一刀：NoInputNoOutput agent），当前会失败并如实返回错误。
    const int32_t rc = btCallDevice(address, "Pair", 60000);
    return rc;
}

int32_t btConnect(const char* address) { return btCallDevice(address, "Connect", 30000); }

int32_t btDisconnect(const char* address) { return btCallDevice(address, "Disconnect", 15000); }

int32_t btForget(const char* address) {
    if (address == nullptr || address[0] == '\0') return ERR_STATE;
    std::lock_guard<std::mutex> lock(g_mtx);
    DBusConnection* bus = busLocked();
    if (bus == nullptr) return ERR_BACKEND;
    const std::string adapter = adapterPathLocked(bus);
    const std::string path = btDevicePathLocked(bus, address);
    if (adapter.empty() || path.empty()) return ERR_STATE;
    DBusMessage* msg = dbus_message_new_method_call(kBlueZ, adapter.c_str(), kAdapter1,
                                                    "RemoveDevice");
    if (msg == nullptr) return ERR_BACKEND;
    const char* p = path.c_str();
    dbus_message_append_args(msg, DBUS_TYPE_OBJECT_PATH, &p, DBUS_TYPE_INVALID);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 10000, &err);
    const bool ok = reply != nullptr;
    if (reply != nullptr) dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    dbus_message_unref(msg);
    return ok ? OK : ERR_BACKEND;
}

}  // namespace netctl
}  // namespace archoera

#endif  // __linux__

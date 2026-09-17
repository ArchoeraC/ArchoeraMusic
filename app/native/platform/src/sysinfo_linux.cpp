// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 系统资源与蓝牙状态（Linux 实现）。
//!
//! - 资源：`/proc/stat`（CPU 占用，按两次采样差值）、`/proc/meminfo`、
//!   `/proc/uptime`、`/sys/class/thermal/*/temp`（毫摄氏度）、`statvfs("/")`（磁盘）。
//! - 蓝牙：**system bus** 上的 BlueZ，`org.freedesktop.DBus.ObjectManager.GetManagedObjects`
//!   一次取回全部对象，解析 `org.bluez.Adapter1` 属性与 `org.bluez.Device1` 连接数。
//!
//! 全部为只读快照、同步调用（Dart 轮询）；不需要 root。

#include "sysinfo.h"

#if defined(__linux__)

#include "core.h"

#include <dbus/dbus.h>
#include <sys/statvfs.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

namespace archoera {
namespace sysinfo {
namespace {

std::mutex g_mtx;

// ── 资源 ──────────────────────────────────────────────────────────

struct CpuSample {
    long long total = 0;
    long long idle = 0;
};
CpuSample g_prev;

CpuSample readCpu() {
    CpuSample s;
    FILE* f = std::fopen("/proc/stat", "r");
    if (f == nullptr) return s;
    char line[256];
    if (std::fgets(line, sizeof(line), f) != nullptr) {
        const char* p = line;
        while (*p != '\0' && *p != ' ') ++p;  // 跳过 "cpu"
        long long v[10] = {0};
        for (int i = 0; i < 10 && *p != '\0'; ++i) {
            while (*p == ' ') ++p;
            if (*p == '\0' || *p == '\n') break;
            v[i] = std::strtoll(p, const_cast<char**>(&p), 10);
            s.total += v[i];
        }
        // idle = idle + iowait（v[3] + v[4]）
        s.idle = v[3] + v[4];
    }
    std::fclose(f);
    return s;
}

int32_t cpuCount() {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? static_cast<int32_t>(n) : 1;
}

long long meminfoKb(const char* key) {
    FILE* f = std::fopen("/proc/meminfo", "r");
    if (f == nullptr) return 0;
    const size_t keyLen = std::strlen(key);
    char line[256];
    long long value = 0;
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        if (std::strncmp(line, key, keyLen) == 0) {
            const char* p = line + keyLen;
            while (*p == ' ' || *p == ':') ++p;
            value = std::strtoll(p, nullptr, 10);
            break;
        }
    }
    std::fclose(f);
    return value;
}

long long uptimeSec() {
    FILE* f = std::fopen("/proc/uptime", "r");
    if (f == nullptr) return 0;
    double sec = 0;
    const int n = std::fscanf(f, "%lf", &sec);
    std::fclose(f);
    return n == 1 ? static_cast<long long>(sec) : 0;
}

int32_t thermalMillic() {
    for (int i = 0; i < 8; ++i) {
        char path[64];
        std::snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", i);
        FILE* f = std::fopen(path, "r");
        if (f == nullptr) continue;
        long v = 0;
        const int n = std::fscanf(f, "%ld", &v);
        std::fclose(f);
        if (n == 1 && v > 0) {
            // 内核约定为毫摄氏度；个别平台给摄氏度，按量级兜底。
            return v >= 1000 ? static_cast<int32_t>(v) : static_cast<int32_t>(v * 1000);
        }
    }
    return -1;
}

// ── 蓝牙（BlueZ）──────────────────────────────────────────────────

std::atomic<bool> g_bluez{false};
std::mutex g_bus_mtx;
DBusConnection* g_bus = nullptr;
std::string g_adapter_name;

DBusConnection* systemBusLocked() {
    if (g_bus != nullptr) return g_bus;
    DBusError err;
    dbus_error_init(&err);
    g_bus = dbus_bus_get_private(DBUS_BUS_SYSTEM, &err);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    if (g_bus == nullptr) return nullptr;
    dbus_connection_set_exit_on_disconnect(g_bus, FALSE);
    return g_bus;
}

DBusMessage* managedObjects(DBusConnection* bus) {
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* msg = dbus_message_new_method_call("org.bluez", "/",
                                                    "org.freedesktop.DBus.ObjectManager",
                                                    "GetManagedObjects");
    if (msg == nullptr) return nullptr;
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 2000, &err);
    dbus_message_unref(msg);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    return reply;
}

// 读取一个 variant（仅处理 bool/string，够 BlueZ 属性用）。
void readVariant(DBusMessageIter* variant, bool* boolOut, std::string* strOut) {
    const int type = dbus_message_iter_get_arg_type(variant);
    if (type == DBUS_TYPE_BOOLEAN && boolOut != nullptr) {
        dbus_bool_t v = FALSE;
        dbus_message_iter_get_basic(variant, &v);
        *boolOut = v != FALSE;
    } else if (type == DBUS_TYPE_STRING && strOut != nullptr) {
        const char* v = nullptr;
        dbus_message_iter_get_basic(variant, &v);
        if (v != nullptr) *strOut = v;
    }
}

}  // namespace

bool statsAvailable() { return true; }

bool bluetoothAvailable() { return g_bluez.load(); }

void probe() {
    std::lock_guard<std::mutex> lock(g_bus_mtx);
    DBusConnection* bus = systemBusLocked();
    if (bus == nullptr) {
        g_bluez.store(false);
        return;
    }
    DBusMessage* reply = managedObjects(bus);
    // BlueZ 服务在总线上即认为具备蓝牙能力（可能暂时没有适配器）。
    g_bluez.store(reply != nullptr);
    if (reply != nullptr) dbus_message_unref(reply);
}

int32_t stats(AplSysStats* out) {
    if (out == nullptr) return ERR_STATE;
    *out = AplSysStats{};

    const CpuSample now = readCpu();
    std::lock_guard<std::mutex> lock(g_mtx);
    if (g_prev.total != 0 && now.total > g_prev.total) {
        const long long totalDelta = now.total - g_prev.total;
        const long long idleDelta = now.idle - g_prev.idle;
        const long long busy = totalDelta - idleDelta;
        out->cpu_percent = static_cast<int32_t>((busy * 100) / totalDelta);
    } else {
        out->cpu_percent = -1;
    }
    g_prev = now;

    out->cpu_count = cpuCount();
    out->mem_total_kb = meminfoKb("MemTotal");
    out->mem_available_kb = meminfoKb("MemAvailable");
    out->swap_total_kb = meminfoKb("SwapTotal");
    out->swap_free_kb = meminfoKb("SwapFree");
    out->uptime_sec = uptimeSec();
    out->temp_millic = thermalMillic();

    struct statvfs vfs {};
    if (statvfs("/", &vfs) == 0) {
        const long long unit = static_cast<long long>(vfs.f_frsize != 0 ? vfs.f_frsize : vfs.f_bsize);
        out->disk_total_kb = unit * static_cast<long long>(vfs.f_blocks) / 1024;
        out->disk_free_kb = unit * static_cast<long long>(vfs.f_bavail) / 1024;
    }
    return OK;
}

int32_t btState(AplBtState* out) {
    if (out == nullptr) return ERR_STATE;
    *out = AplBtState{};

    std::lock_guard<std::mutex> lock(g_bus_mtx);
    DBusConnection* bus = systemBusLocked();
    if (bus == nullptr) return ERR_UNSUPPORTED;
    DBusMessage* reply = managedObjects(bus);
    if (reply == nullptr) return ERR_UNSUPPORTED;

    DBusMessageIter root;
    if (!dbus_message_iter_init(reply, &root) ||
        dbus_message_iter_get_arg_type(&root) != DBUS_TYPE_ARRAY) {
        dbus_message_unref(reply);
        return ERR_BACKEND;
    }

    std::string name;
    DBusMessageIter obj;
    for (dbus_message_iter_recurse(&root, &obj);
         dbus_message_iter_get_arg_type(&obj) == DBUS_TYPE_DICT_ENTRY;
         dbus_message_iter_next(&obj)) {
        DBusMessageIter entry;
        dbus_message_iter_recurse(&obj, &entry);          // o
        dbus_message_iter_next(&entry);                   // a{sa{sv}}
        DBusMessageIter ifaces;
        dbus_message_iter_recurse(&entry, &ifaces);
        for (; dbus_message_iter_get_arg_type(&ifaces) == DBUS_TYPE_DICT_ENTRY;
             dbus_message_iter_next(&ifaces)) {
            DBusMessageIter ifaceEntry;
            dbus_message_iter_recurse(&ifaces, &ifaceEntry);
            const char* iface = nullptr;
            dbus_message_iter_get_basic(&ifaceEntry, &iface);
            DBusMessageIter props;
            dbus_message_iter_next(&ifaceEntry);
            dbus_message_iter_recurse(&ifaceEntry, &props);

            const bool isAdapter = iface != nullptr && std::strcmp(iface, "org.bluez.Adapter1") == 0;
            const bool isDevice = iface != nullptr && std::strcmp(iface, "org.bluez.Device1") == 0;
            if (!isAdapter && !isDevice) continue;

            bool powered = false;
            bool discoverable = false;
            bool pairable = false;
            bool connected = false;
            std::string alias;
            std::string pretty;
            for (; dbus_message_iter_get_arg_type(&props) == DBUS_TYPE_DICT_ENTRY;
                 dbus_message_iter_next(&props)) {
                DBusMessageIter propEntry;
                dbus_message_iter_recurse(&props, &propEntry);
                const char* key = nullptr;
                dbus_message_iter_get_basic(&propEntry, &key);
                DBusMessageIter variant;
                dbus_message_iter_next(&propEntry);
                dbus_message_iter_recurse(&propEntry, &variant);
                if (key == nullptr) continue;
                if (std::strcmp(key, "Powered") == 0) {
                    readVariant(&variant, &powered, nullptr);
                } else if (std::strcmp(key, "Discoverable") == 0) {
                    readVariant(&variant, &discoverable, nullptr);
                } else if (std::strcmp(key, "Pairable") == 0) {
                    readVariant(&variant, &pairable, nullptr);
                } else if (std::strcmp(key, "Connected") == 0) {
                    readVariant(&variant, &connected, nullptr);
                } else if (std::strcmp(key, "Alias") == 0) {
                    readVariant(&variant, nullptr, &alias);
                } else if (std::strcmp(key, "Name") == 0) {
                    readVariant(&variant, nullptr, &pretty);
                }
            }

            if (isAdapter) {
                out->present = 1;
                out->powered = powered ? 1 : 0;
                out->discoverable = discoverable ? 1 : 0;
                out->pairable = pairable ? 1 : 0;
                if (!alias.empty()) name = alias;
                else if (!pretty.empty()) name = pretty;
            } else if (connected) {
                out->devices_connected += 1;
            }
        }
    }
    dbus_message_unref(reply);

    g_adapter_name = name;
    if (!g_adapter_name.empty()) {
        out->adapter_name.data = g_adapter_name.c_str();
        out->adapter_name.len = g_adapter_name.size();
    }
    return OK;
}

void shutdown() {
    std::lock_guard<std::mutex> lock(g_bus_mtx);
    if (g_bus != nullptr) {
        dbus_connection_close(g_bus);
        dbus_connection_unref(g_bus);
        g_bus = nullptr;
    }
}

}  // namespace sysinfo
}  // namespace archoera

#endif  // __linux__

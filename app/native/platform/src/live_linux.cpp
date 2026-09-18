// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Live 安装向导支持（Linux 实现）。
//!
//! 设计原则：**本层不起任何子进程**。
//! - 磁盘清单由 Live 的 oneshot 单元（`archoera-install --list`）写到
//!   `/run/archoera-install/devices`，这里只解析文件；
//! - 启动安装把计划写进 `/run/archoera-install/{plan,secrets}`，再经 system bus
//!   调 systemd 的 `StartUnit("archoera-install.service")`；
//! - 进度读 `/run/archoera-install/{percent,message,done,failed}`。

#include "live.h"

#if defined(__linux__)

#include "core.h"

#include <dbus/dbus.h>
#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace archoera {
namespace live {
namespace {

constexpr const char* kStateDir = "/run/archoera-install";
constexpr const char* kLiveMarker = "/etc/archoera-live";

// AplString 指向这些缓冲；仅在该次调用后、下一次同类调用前有效。
std::vector<std::string> g_disk_names;
std::vector<std::string> g_disk_models;
std::vector<std::string> g_disk_trans;
std::string g_status_message;

std::string joinPath(const char* dir, const char* name) {
    std::string s(dir);
    s += '/';
    s += name;
    return s;
}

bool readFile(const std::string& path, std::string* out) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (f == nullptr) return false;
    std::string s;
    char buf[1024];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
    std::fclose(f);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    if (out != nullptr) *out = s;
    return true;
}

bool writeFile(const std::string& path, const std::string& data, mode_t mode) {
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) return false;
    size_t off = 0;
    while (off < data.size()) {
        const ssize_t w = ::write(fd, data.data() + off, data.size() - off);
        if (w <= 0) {
            ::close(fd);
            return false;
        }
        off += static_cast<size_t>(w);
    }
    ::close(fd);
    return true;
}

// 计划/口令文件是一行一条 key=value：值里不能有换行（否则会破坏格式）。
bool valueOk(const std::string& v) { return v.find_first_of("\n\r") == std::string::npos; }

std::string kv(const char* key, const AplString& value) {
    std::string s(key);
    s += '=';
    if (value.data != nullptr) s.append(value.data, value.len);
    s += '\n';
    return s;
}

std::string sv(const AplString& v) {
    return v.data != nullptr ? std::string(v.data, v.len) : std::string();
}

int32_t startUnit(const char* unit) {
    DBusError err;
    dbus_error_init(&err);
    DBusConnection* bus = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
    if (bus == nullptr) {
        dbus_error_free(&err);
        return ERR_BACKEND;
    }
    DBusMessage* msg = dbus_message_new_method_call("org.freedesktop.systemd1",
                                                    "/org/freedesktop/systemd1",
                                                    "org.freedesktop.systemd1.Manager",
                                                    "StartUnit");
    if (msg == nullptr) return ERR_BACKEND;
    const char* mode = "replace";
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &unit, DBUS_TYPE_STRING, &mode,
                             DBUS_TYPE_INVALID);
    DBusMessage* reply = dbus_connection_send_with_reply_and_block(bus, msg, 5000, &err);
    const bool ok = reply != nullptr;
    if (reply != nullptr) dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);
    dbus_message_unref(msg);
    dbus_connection_unref(bus);
    return ok ? OK : ERR_BACKEND;
}

}  // namespace

bool available() { return ::access(kLiveMarker, F_OK) == 0; }

int32_t diskList(AplLiveDisk* out, uint32_t max, uint32_t* count) {
    if (out == nullptr || count == nullptr) return ERR_STATE;
    *count = 0;

    std::string raw;
    if (!readFile(joinPath(kStateDir, "devices"), &raw)) return ERR_UNSUPPORTED;

    g_disk_names.clear();
    g_disk_models.clear();
    g_disk_trans.clear();

    size_t pos = 0;
    uint32_t idx = 0;
    while (pos <= raw.size() && idx < max) {
        const size_t nl = raw.find('\n', pos);
        std::string line = raw.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
        pos = (nl == std::string::npos) ? raw.size() + 1 : nl + 1;
        if (line.empty() || line[0] == '#') continue;

        std::vector<std::string> fields;
        size_t p = 0;
        while (true) {
            const size_t bar = line.find('|', p);
            if (bar == std::string::npos) {
                fields.push_back(line.substr(p));
                break;
            }
            fields.push_back(line.substr(p, bar - p));
            p = bar + 1;
        }
        if (fields.size() < 5) continue;

        AplLiveDisk* d = &out[idx];
        *d = AplLiveDisk{};
        d->size_bytes = std::strtoll(fields[1].c_str(), nullptr, 10);
        d->is_live = fields[4] == "1" ? 1 : 0;
        g_disk_names.push_back(fields[0]);
        g_disk_models.push_back(fields[2]);
        g_disk_trans.push_back(fields[3]);
        d->name.data = g_disk_names.back().c_str();
        d->name.len = g_disk_names.back().size();
        if (!g_disk_models.back().empty()) {
            d->model.data = g_disk_models.back().c_str();
            d->model.len = g_disk_models.back().size();
        }
        if (!g_disk_trans.back().empty()) {
            d->transport.data = g_disk_trans.back().c_str();
            d->transport.len = g_disk_trans.back().size();
        }
        ++idx;
    }

    *count = idx;
    return idx > 0 ? OK : ERR_UNSUPPORTED;
}

int32_t installStart(const AplLivePlan* plan) {
    if (plan == nullptr) return ERR_STATE;
    if (!available()) return ERR_UNSUPPORTED;

    const std::string disk = sv(plan->disk);
    if (disk.empty()) return ERR_STATE;

    std::string p;
    p += kv("disk", plan->disk);
    p += kv("hostname", plan->hostname);
    p += kv("username", plan->username);
    p += kv("locale", plan->locale);
    p += kv("timezone", plan->timezone);
    p += kv("keymap", plan->keymap);
    p += kv("fs", plan->fs);
    p += kv("swap", plan->swap);
    {
        char buf[8];
        std::snprintf(buf, sizeof(buf), "%d", plan->encrypt ? 1 : 0);
        std::string s = "encrypt=";
        s += buf;
        s += '\n';
        p += s;
        std::snprintf(buf, sizeof(buf), "%d", plan->autologin ? 1 : 0);
        s = "autologin=";
        s += buf;
        s += '\n';
        p += s;
    }
    if (!valueOk(p)) return ERR_STATE;

    std::string sec;
    sec += kv("luks_passphrase", plan->luks_passphrase);
    sec += kv("user_password", plan->user_password);
    sec += kv("root_password", plan->root_password);
    if (!valueOk(sec)) return ERR_STATE;

    if (!writeFile(joinPath(kStateDir, "plan"), p, 0644)) return ERR_BACKEND;
    if (!writeFile(joinPath(kStateDir, "secrets"), sec, 0600)) return ERR_BACKEND;
    // 清掉上一次的结束标记，避免向导把旧结果当成这次的。
    ::unlink(joinPath(kStateDir, "done").c_str());
    ::unlink(joinPath(kStateDir, "failed").c_str());

    return startUnit("archoera-install.service");
}

int32_t installStatus(AplLiveInstallStatus* out) {
    if (out == nullptr) return ERR_STATE;
    *out = AplLiveInstallStatus{};
    out->percent = -1;

    std::string s;
    if (readFile(joinPath(kStateDir, "percent"), &s) && !s.empty()) {
        out->percent = std::atoi(s.c_str());
    }
    if (readFile(joinPath(kStateDir, "message"), &s)) g_status_message = s;
    out->done = ::access(joinPath(kStateDir, "done").c_str(), F_OK) == 0 ? 1 : 0;
    out->failed = ::access(joinPath(kStateDir, "failed").c_str(), F_OK) == 0 ? 1 : 0;
    out->running = (!out->done && !out->failed) ? 1 : 0;
    if (!g_status_message.empty()) {
        out->message.data = g_status_message.c_str();
        out->message.len = g_status_message.size();
    }
    return OK;
}

}  // namespace live
}  // namespace archoera

#endif  // __linux__

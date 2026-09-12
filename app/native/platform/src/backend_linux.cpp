// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Linux 后端（C++ + libdbus）：MPRIS2 媒体会话（系统媒体键/蓝牙 AVRCP/桌面
//! 媒体面板）、ScreenSaver 防休眠抑制、熄屏/锁屏事件、系统主题色（DE accent）、
//! 单实例文件锁；窗口状态经 dlopen GTK/GDK 轻轮询（X11/Wayland 统一）。
//!
//! D-Bus 连接懒建立：首次需要时连会话总线、申请 MPRIS 服务名、注册 match；
//! 泵线程 `dbus_connection_read_write_dispatch` 分发信号与方法调用。
//! `dbus_threads_init_default()` 保证 Dart 线程 send 与泵线程 dispatch 并发安全。

#include "backend.h"

#include "core.h"

#include <dbus/dbus.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace archoera {
namespace {

// ── 常量 ──────────────────────────────────────────────────────────
constexpr const char* kObjectPath = "/org/mpris/MediaPlayer2";
constexpr const char* kIfaceRoot = "org.mpris.MediaPlayer2";
constexpr const char* kIfacePlayer = "org.mpris.MediaPlayer2.Player";
constexpr const char* kIfaceProps = "org.freedesktop.DBus.Properties";
constexpr const char* kIfaceIntrospect = "org.freedesktop.DBus.Introspectable";

constexpr const char* kSsFreedesktop = "org.freedesktop.ScreenSaver";
constexpr const char* kSsFreedesktopPath = "/org/freedesktop/ScreenSaver";
constexpr const char* kSsGnome = "org.gnome.ScreenSaver";
constexpr const char* kSsGnomePath = "/org/gnome/ScreenSaver";

constexpr const char* kIntrospectXml =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" "
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">"
    "<node><interface name=\"org.mpris.MediaPlayer2.Player\">"
    "<method name=\"Play\"/><method name=\"Pause\"/><method name=\"PlayPause\"/>"
    "<method name=\"Stop\"/><method name=\"Next\"/><method name=\"Previous\"/>"
    "<method name=\"Seek\"><arg direction=\"in\" type=\"x\"/></method>"
    "<method name=\"SetPosition\"><arg direction=\"in\" type=\"o\"/><arg direction=\"in\" type=\"x\"/></method>"
    "</interface><interface name=\"org.mpris.MediaPlayer2\">"
    "<method name=\"Raise\"/><method name=\"Quit\"/></interface></node>";

int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch())
        .count();
}

// ── 全局状态 ──────────────────────────────────────────────────────
std::mutex g_mtx;
DBusConnection* g_conn = nullptr;
std::atomic<bool> g_running{false};
// 堆指针：即使宿主未调 apl_shutdown 就退出，也不触发静态 std::thread 析构的
// std::terminate（仅泄漏，不崩）。
std::thread* g_pump = nullptr;

std::string g_service = "org.mpris.MediaPlayer2.archoera";
std::string g_ss_service = kSsFreedesktop;
std::string g_ss_path = kSsFreedesktopPath;

int g_state = 0;  // 0=stopped 1=playing 2=paused
int g_loop = 0;   // 0=Playlist 1=Track
bool g_shuffle = false;
double g_volume = 1.0;
int64_t g_position_ms = 0;
int64_t g_position_base = 0;
double g_rate = 1.0;

uint32_t g_track_serial = 0;
std::string g_title, g_artist, g_album, g_art;
int64_t g_duration_ms = -1;

uint32_t g_cookie = 0;
bool g_inhibit_on = false;

std::atomic<bool> g_screen_events{false};
std::atomic<bool> g_accent_events{false};

// ── 小工具 ────────────────────────────────────────────────────────
DBusConnection* conn() {
    std::lock_guard<std::mutex> lock(g_mtx);
    return g_conn;
}

void appendSvString(DBusMessageIter* arr, const char* key, const char* value) {
    DBusMessageIter entry, var;
    dbus_message_iter_open_container(arr, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_STRING, &value);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(arr, &entry);
}

void appendSvBool(DBusMessageIter* arr, const char* key, dbus_bool_t value) {
    DBusMessageIter entry, var;
    dbus_message_iter_open_container(arr, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_BOOLEAN, &value);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(arr, &entry);
}

void appendSvDouble(DBusMessageIter* arr, const char* key, double value) {
    DBusMessageIter entry, var;
    dbus_message_iter_open_container(arr, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "d", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_DOUBLE, &value);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(arr, &entry);
}

void appendSvInt64(DBusMessageIter* arr, const char* key, int64_t value) {
    DBusMessageIter entry, var;
    dbus_message_iter_open_container(arr, DBUS_TYPE_DICT_ENTRY, nullptr, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "x", &var);
    dbus_message_iter_append_basic(&var, DBUS_TYPE_INT64, &value);
    dbus_message_iter_close_container(&entry, &var);
    dbus_message_iter_close_container(arr, &entry);
}

int64_t currentPositionMs() {
    std::lock_guard<std::mutex> lock(g_mtx);
    if (g_state == 1) return g_position_ms + (nowMs() - g_position_base);
    return g_position_ms;
}

// ── 属性读写 ──────────────────────────────────────────────────────
const char* propSignature(const char* iface, const char* name) {
    if (std::strcmp(iface, kIfaceRoot) == 0) {
        if (std::strcmp(name, "CanQuit") == 0 ||
            std::strcmp(name, "CanRaise") == 0 ||
            std::strcmp(name, "HasTrackList") == 0) {
            return "b";
        }
        if (std::strcmp(name, "Identity") == 0 ||
            std::strcmp(name, "DesktopEntry") == 0) {
            return "s";
        }
        if (std::strcmp(name, "SupportedUriSchemes") == 0 ||
            std::strcmp(name, "SupportedMimeTypes") == 0) {
            return "as";
        }
        return nullptr;
    }
    if (std::strcmp(iface, kIfacePlayer) == 0) {
        if (std::strcmp(name, "PlaybackStatus") == 0 ||
            std::strcmp(name, "LoopStatus") == 0) {
            return "s";
        }
        if (std::strcmp(name, "Rate") == 0 || std::strcmp(name, "Volume") == 0 ||
            std::strcmp(name, "MinimumRate") == 0 ||
            std::strcmp(name, "MaximumRate") == 0) {
            return "d";
        }
        if (std::strcmp(name, "Shuffle") == 0 ||
            std::strcmp(name, "CanGoNext") == 0 ||
            std::strcmp(name, "CanGoPrevious") == 0 ||
            std::strcmp(name, "CanPlay") == 0 ||
            std::strcmp(name, "CanPause") == 0 ||
            std::strcmp(name, "CanSeek") == 0 ||
            std::strcmp(name, "CanControl") == 0) {
            return "b";
        }
        if (std::strcmp(name, "Metadata") == 0) return "a{sv}";
        if (std::strcmp(name, "Position") == 0) return "x";
        return nullptr;
    }
    return nullptr;
}

// 写属性值到 iter（不含外层 variant 包装）。
void writePropValue(DBusMessageIter* it, const char* iface, const char* name) {
    if (std::strcmp(iface, kIfaceRoot) == 0) {
        if (std::strcmp(name, "CanQuit") == 0) {
            dbus_bool_t v = FALSE;
            dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &v);
        } else if (std::strcmp(name, "CanRaise") == 0) {
            dbus_bool_t v = TRUE;
            dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &v);
        } else if (std::strcmp(name, "HasTrackList") == 0) {
            dbus_bool_t v = FALSE;
            dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &v);
        } else if (std::strcmp(name, "Identity") == 0) {
            const char* v = "ArchoeraMusic";
            dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v);
        } else if (std::strcmp(name, "DesktopEntry") == 0) {
            const char* v = "awa.archoera.betastudio2.archoera_music";
            dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v);
        } else {
            DBusMessageIter arr;
            dbus_message_iter_open_container(it, DBUS_TYPE_ARRAY, "s", &arr);
            dbus_message_iter_close_container(it, &arr);
        }
        return;
    }
    // Player
    if (std::strcmp(name, "PlaybackStatus") == 0) {
        const char* v = "Stopped";
        {
            std::lock_guard<std::mutex> lock(g_mtx);
            v = g_state == 1 ? "Playing" : (g_state == 2 ? "Paused" : "Stopped");
        }
        dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v);
    } else if (std::strcmp(name, "LoopStatus") == 0) {
        int loop;
        {
            std::lock_guard<std::mutex> lock(g_mtx);
            loop = g_loop;
        }
        const char* v = loop == 1 ? "Track" : "Playlist";
        dbus_message_iter_append_basic(it, DBUS_TYPE_STRING, &v);
    } else if (std::strcmp(name, "Rate") == 0 ||
               std::strcmp(name, "MinimumRate") == 0 ||
               std::strcmp(name, "MaximumRate") == 0) {
        double v = 1.0;
        dbus_message_iter_append_basic(it, DBUS_TYPE_DOUBLE, &v);
    } else if (std::strcmp(name, "Shuffle") == 0) {
        dbus_bool_t v;
        {
            std::lock_guard<std::mutex> lock(g_mtx);
            v = g_shuffle ? TRUE : FALSE;
        }
        dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &v);
    } else if (std::strcmp(name, "Volume") == 0) {
        double v;
        {
            std::lock_guard<std::mutex> lock(g_mtx);
            v = g_volume;
        }
        dbus_message_iter_append_basic(it, DBUS_TYPE_DOUBLE, &v);
    } else if (std::strcmp(name, "Position") == 0) {
        int64_t v = currentPositionMs() * 1000;
        dbus_message_iter_append_basic(it, DBUS_TYPE_INT64, &v);
    } else if (std::strcmp(name, "Metadata") == 0) {
        std::string title, artist, album, art;
        int64_t dur;
        uint32_t serial;
        {
            std::lock_guard<std::mutex> lock(g_mtx);
            title = g_title;
            artist = g_artist;
            album = g_album;
            art = g_art;
            dur = g_duration_ms;
            serial = g_track_serial;
        }
        char trackid[64];
        std::snprintf(trackid, sizeof(trackid),
                      "/org/mpris/MediaPlayer2/Track/%u", serial);
        DBusMessageIter arr;
        dbus_message_iter_open_container(it, DBUS_TYPE_ARRAY, "{sv}", &arr);
        const char* tid = trackid;
        {
            DBusMessageIter entry, var;
            dbus_message_iter_open_container(&arr, DBUS_TYPE_DICT_ENTRY, nullptr,
                                             &entry);
            const char* k = "mpris:trackid";
            dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k);
            dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "o", &var);
            dbus_message_iter_append_basic(&var, DBUS_TYPE_OBJECT_PATH, &tid);
            dbus_message_iter_close_container(&entry, &var);
            dbus_message_iter_close_container(&arr, &entry);
        }
        if (dur > 0) appendSvInt64(&arr, "mpris:length", dur * 1000);
        if (!title.empty()) appendSvString(&arr, "xesam:title", title.c_str());
        if (!artist.empty()) {
            DBusMessageIter entry, var, list;
            dbus_message_iter_open_container(&arr, DBUS_TYPE_DICT_ENTRY, nullptr,
                                             &entry);
            const char* k = "xesam:artist";
            dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k);
            dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "as",
                                             &var);
            dbus_message_iter_open_container(&var, DBUS_TYPE_ARRAY, "s", &list);
            const char* a = artist.c_str();
            dbus_message_iter_append_basic(&list, DBUS_TYPE_STRING, &a);
            dbus_message_iter_close_container(&var, &list);
            dbus_message_iter_close_container(&entry, &var);
            dbus_message_iter_close_container(&arr, &entry);
        }
        if (!album.empty()) appendSvString(&arr, "xesam:album", album.c_str());
        if (!art.empty()) appendSvString(&arr, "mpris:artUrl", art.c_str());
        dbus_message_iter_close_container(it, &arr);
    } else {
        // Can*：首期恒真
        dbus_bool_t v = TRUE;
        dbus_message_iter_append_basic(it, DBUS_TYPE_BOOLEAN, &v);
    }
}

const char* const kPlayerProps[] = {
    "PlaybackStatus", "LoopStatus", "Rate",  "Shuffle", "Metadata",
    "Volume",         "Position",   "MinimumRate", "MaximumRate",
    "CanGoNext",      "CanGoPrevious", "CanPlay", "CanPause", "CanSeek",
    "CanControl"};
const char* const kRootProps[] = {
    "CanQuit",      "CanRaise",           "HasTrackList",
    "Identity",     "DesktopEntry",       "SupportedUriSchemes",
    "SupportedMimeTypes"};

// ── 回复助手 ──────────────────────────────────────────────────────
void send(DBusConnection* c, DBusMessage* reply) {
    if (reply == nullptr) return;
    dbus_connection_send(c, reply, nullptr);
    dbus_connection_flush(c);
    dbus_message_unref(reply);
}

void replyEmpty(DBusConnection* c, DBusMessage* msg) {
    send(c, dbus_message_new_method_return(msg));
}

void replyError(DBusConnection* c, DBusMessage* msg, const char* name,
                const char* text) {
    send(c, dbus_message_new_error(msg, name, text));
}

void replyString(DBusConnection* c, DBusMessage* msg, const char* s) {
    DBusMessage* reply = dbus_message_new_method_return(msg);
    dbus_message_append_args(reply, DBUS_TYPE_STRING, &s, DBUS_TYPE_INVALID);
    send(c, reply);
}

// ── Properties ────────────────────────────────────────────────────
void propGet(DBusConnection* c, DBusMessage* msg) {
    DBusError err;
    dbus_error_init(&err);
    const char* iface = nullptr;
    const char* name = nullptr;
    if (!dbus_message_get_args(msg, &err, DBUS_TYPE_STRING, &iface,
                               DBUS_TYPE_STRING, &name, DBUS_TYPE_INVALID)) {
        dbus_error_free(&err);
        return replyError(c, msg, DBUS_ERROR_INVALID_ARGS, "Get");
    }
    const char* sig = propSignature(iface, name);
    if (sig == nullptr) {
        return replyError(c, msg, "org.freedesktop.DBus.Error.UnknownProperty",
                          name);
    }
    DBusMessage* reply = dbus_message_new_method_return(msg);
    DBusMessageIter it, var;
    dbus_message_iter_init_append(reply, &it);
    dbus_message_iter_open_container(&it, DBUS_TYPE_VARIANT, sig, &var);
    writePropValue(&var, iface, name);
    dbus_message_iter_close_container(&it, &var);
    send(c, reply);
}

void propGetAll(DBusConnection* c, DBusMessage* msg) {
    DBusError err;
    dbus_error_init(&err);
    const char* iface = nullptr;
    if (!dbus_message_get_args(msg, &err, DBUS_TYPE_STRING, &iface,
                               DBUS_TYPE_INVALID)) {
        dbus_error_free(&err);
        return replyError(c, msg, DBUS_ERROR_INVALID_ARGS, "GetAll");
    }
    const char* const* names = nullptr;
    size_t count = 0;
    if (std::strcmp(iface, kIfacePlayer) == 0) {
        names = kPlayerProps;
        count = sizeof(kPlayerProps) / sizeof(kPlayerProps[0]);
    } else if (std::strcmp(iface, kIfaceRoot) == 0) {
        names = kRootProps;
        count = sizeof(kRootProps) / sizeof(kRootProps[0]);
    } else {
        return replyError(c, msg, DBUS_ERROR_UNKNOWN_INTERFACE, iface);
    }
    DBusMessage* reply = dbus_message_new_method_return(msg);
    DBusMessageIter it, arr;
    dbus_message_iter_init_append(reply, &it);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &arr);
    for (size_t i = 0; i < count; i++) {
        const char* sig = propSignature(iface, names[i]);
        if (sig == nullptr) continue;
        DBusMessageIter entry, var;
        dbus_message_iter_open_container(&arr, DBUS_TYPE_DICT_ENTRY, nullptr,
                                         &entry);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &names[i]);
        dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, sig, &var);
        writePropValue(&var, iface, names[i]);
        dbus_message_iter_close_container(&entry, &var);
        dbus_message_iter_close_container(&arr, &entry);
    }
    dbus_message_iter_close_container(&it, &arr);
    send(c, reply);
}

void propSet(DBusConnection* c, DBusMessage* msg) {
    DBusMessageIter it;
    if (!dbus_message_iter_init(msg, &it)) {
        return replyError(c, msg, DBUS_ERROR_INVALID_ARGS, "Set");
    }
    if (dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_STRING) {
        return replyError(c, msg, DBUS_ERROR_INVALID_ARGS, "Set");
    }
    const char* name = nullptr;
    dbus_message_iter_get_basic(&it, &name);
    dbus_message_iter_next(&it);
    if (dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_STRING) {
        return replyError(c, msg, DBUS_ERROR_INVALID_ARGS, "Set");
    }
    dbus_message_iter_next(&it);
    if (dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_VARIANT) {
        return replyError(c, msg, DBUS_ERROR_INVALID_ARGS, "Set");
    }
    DBusMessageIter var;
    dbus_message_iter_recurse(&it, &var);
    const int type = dbus_message_iter_get_arg_type(&var);
    bool read_only = false;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        if (std::strcmp(name, "Volume") == 0 && type == DBUS_TYPE_DOUBLE) {
            double v = 0;
            dbus_message_iter_get_basic(&var, &v);
            g_volume = v;
        } else if (std::strcmp(name, "LoopStatus") == 0 &&
                   type == DBUS_TYPE_STRING) {
            const char* v = nullptr;
            dbus_message_iter_get_basic(&var, &v);
            g_loop = (v != nullptr && std::strcmp(v, "Track") == 0) ? 1 : 0;
        } else if (std::strcmp(name, "Shuffle") == 0 &&
                   type == DBUS_TYPE_BOOLEAN) {
            dbus_bool_t v = FALSE;
            dbus_message_iter_get_basic(&var, &v);
            g_shuffle = v != FALSE;
        } else {
            read_only = true;
        }
    }
    if (read_only) {
        return replyError(c, msg, "org.freedesktop.DBus.Error.PropertyReadOnly",
                          name);
    }
    replyEmpty(c, msg);
}

// ── PropertiesChanged 推送 ────────────────────────────────────────
void emitChanged(DBusConnection* c,
                 const std::vector<const char*>& changed) {
    if (c == nullptr) return;
    DBusMessage* sig = dbus_message_new_signal(kObjectPath, kIfaceProps,
                                               "PropertiesChanged");
    DBusMessageIter it, arr, invalid;
    dbus_message_iter_init_append(sig, &it);
    const char* iface = kIfacePlayer;
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &iface);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &arr);
    for (const char* name : changed) {
        const char* psig = propSignature(kIfacePlayer, name);
        if (psig == nullptr) continue;
        DBusMessageIter entry, var;
        dbus_message_iter_open_container(&arr, DBUS_TYPE_DICT_ENTRY, nullptr,
                                         &entry);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &name);
        dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, psig, &var);
        writePropValue(&var, kIfacePlayer, name);
        dbus_message_iter_close_container(&entry, &var);
        dbus_message_iter_close_container(&arr, &entry);
    }
    dbus_message_iter_close_container(&it, &arr);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &invalid);
    dbus_message_iter_close_container(&it, &invalid);
    send(c, sig);
}

// ── MPRIS 方法分发 ────────────────────────────────────────────────
void playerCommand(DBusConnection* c, DBusMessage* msg, int32_t command) {
    dispatch(makeCommand(command));
    replyEmpty(c, msg);
}

void handleMethodCall(DBusConnection* c, DBusMessage* msg) {
    const char* path = dbus_message_get_path(msg);
    if (path == nullptr || std::strcmp(path, kObjectPath) != 0) {
        return replyError(c, msg, DBUS_ERROR_UNKNOWN_OBJECT,
                          path != nullptr ? path : "");
    }
    const char* iface = dbus_message_get_interface(msg);
    const char* member = dbus_message_get_member(msg);
    if (iface == nullptr || member == nullptr) {
        return replyError(c, msg, DBUS_ERROR_UNKNOWN_METHOD, "");
    }
    if (std::strcmp(iface, kIfaceProps) == 0) {
        if (std::strcmp(member, "Get") == 0) return propGet(c, msg);
        if (std::strcmp(member, "GetAll") == 0) return propGetAll(c, msg);
        if (std::strcmp(member, "Set") == 0) return propSet(c, msg);
        return replyError(c, msg, DBUS_ERROR_UNKNOWN_METHOD, member);
    }
    if (std::strcmp(iface, kIfaceIntrospect) == 0) {
        return replyString(c, msg, kIntrospectXml);
    }
    if (std::strcmp(iface, kIfaceRoot) == 0) {
        if (std::strcmp(member, "Raise") == 0) return replyEmpty(c, msg);
        if (std::strcmp(member, "Quit") == 0) {
            dispatch(makeCommand(CMD_STOP));
            return replyEmpty(c, msg);
        }
        return replyError(c, msg, DBUS_ERROR_UNKNOWN_METHOD, member);
    }
    if (std::strcmp(iface, kIfacePlayer) == 0) {
        if (std::strcmp(member, "Play") == 0) return playerCommand(c, msg, CMD_PLAY);
        if (std::strcmp(member, "Pause") == 0) return playerCommand(c, msg, CMD_PAUSE);
        if (std::strcmp(member, "PlayPause") == 0) return playerCommand(c, msg, CMD_TOGGLE);
        if (std::strcmp(member, "Stop") == 0) return playerCommand(c, msg, CMD_STOP);
        if (std::strcmp(member, "Next") == 0) return playerCommand(c, msg, CMD_NEXT);
        if (std::strcmp(member, "Previous") == 0) return playerCommand(c, msg, CMD_PREV);
        if (std::strcmp(member, "Seek") == 0) {
            DBusError err;
            dbus_error_init(&err);
            int64_t offset = 0;
            if (dbus_message_get_args(msg, &err, DBUS_TYPE_INT64, &offset,
                                      DBUS_TYPE_INVALID)) {
                dispatch(makeSeek(offset / 1000, 0));
            }
            dbus_error_free(&err);
            return replyEmpty(c, msg);
        }
        if (std::strcmp(member, "SetPosition") == 0) {
            DBusMessageIter it;
            if (dbus_message_iter_init(msg, &it)) {
                dbus_message_iter_next(&it);  // 跳过 trackid
                if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_INT64) {
                    int64_t pos = 0;
                    dbus_message_iter_get_basic(&it, &pos);
                    dispatch(makeSeek(0, pos / 1000));
                }
            }
            return replyEmpty(c, msg);
        }
        if (std::strcmp(member, "OpenUri") == 0) return replyEmpty(c, msg);
        return replyError(c, msg, DBUS_ERROR_UNKNOWN_METHOD, member);
    }
    return replyError(c, msg, DBUS_ERROR_UNKNOWN_INTERFACE, iface);
}

// ── 信号过滤 ──────────────────────────────────────────────────────
DBusHandlerResult filter(DBusConnection* c, DBusMessage* msg, void*) {
    const int type = dbus_message_get_type(msg);
    if (type == DBUS_MESSAGE_TYPE_METHOD_CALL) {
        handleMethodCall(c, msg);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (type == DBUS_MESSAGE_TYPE_SIGNAL) {
        const char* member = dbus_message_get_member(msg);
        if (member == nullptr) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (g_screen_events.load(std::memory_order_acquire)) {
            if (std::strcmp(member, "ActiveChanged") == 0) {
                dbus_bool_t active = FALSE;
                if (dbus_message_get_args(msg, nullptr, DBUS_TYPE_BOOLEAN,
                                          &active, DBUS_TYPE_INVALID)) {
                    dispatch(makeScreenState(active != FALSE));
                }
                return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            }
            if (std::strcmp(member, "Lock") == 0) {
                dispatch(makeScreenState(true));
                return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            }
            if (std::strcmp(member, "Unlock") == 0) {
                dispatch(makeScreenState(false));
                return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            }
        }
        if (g_accent_events.load(std::memory_order_acquire) &&
            (std::strcmp(member, "SettingChanged") == 0 ||
             std::strcmp(member, "notifyChange") == 0)) {
            dispatch(makeSystemAccent());
        }
    }
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

// ── 连接管理 ──────────────────────────────────────────────────────
void addMatch(DBusConnection* c, const char* rule) {
    DBusError err;
    dbus_error_init(&err);
    dbus_bus_add_match(c, rule, &err);
    dbus_error_free(&err);
}

bool tryRequestName(DBusConnection* c, const char* name) {
    DBusError err;
    dbus_error_init(&err);
    const int rc = dbus_bus_request_name(c, name, DBUS_NAME_FLAG_DO_NOT_QUEUE,
                                         &err);
    dbus_error_free(&err);
    return rc == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER ||
           rc == DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER;
}

void pickScreensaver(DBusConnection* c) {
    const struct {
        const char* name;
        const char* path;
    } candidates[] = {{kSsFreedesktop, kSsFreedesktopPath},
                      {kSsGnome, kSsGnomePath}};
    for (const auto& cand : candidates) {
        DBusError err;
        dbus_error_init(&err);
        DBusMessage* msg = dbus_message_new_method_call(
            "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "GetNameOwner");
        dbus_message_append_args(msg, DBUS_TYPE_STRING, &cand.name,
                                 DBUS_TYPE_INVALID);
        DBusMessage* reply =
            dbus_connection_send_with_reply_and_block(c, msg, 3000, &err);
        dbus_message_unref(msg);
        if (reply != nullptr) {
            std::lock_guard<std::mutex> lock(g_mtx);
            g_ss_service = cand.name;
            g_ss_path = cand.path;
            dbus_message_unref(reply);
            dbus_error_free(&err);
            return;
        }
        dbus_error_free(&err);
    }
}

DBusConnection* ensureConn() {
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        if (g_conn != nullptr) return g_conn;
    }
    DBusError err;
    dbus_error_init(&err);
    DBusConnection* c = dbus_bus_get(DBUS_BUS_SESSION, &err);
    if (c == nullptr) {
        dbus_error_free(&err);
        return nullptr;
    }
    dbus_error_free(&err);
    dbus_connection_set_exit_on_disconnect(c, FALSE);

    if (!tryRequestName(c, "org.mpris.MediaPlayer2.archoera")) {
        char fallback[96];
        std::snprintf(fallback, sizeof(fallback),
                      "org.mpris.MediaPlayer2.archoera.instance%d",
                      static_cast<int>(::getpid()));
        if (tryRequestName(c, fallback)) {
            std::lock_guard<std::mutex> lock(g_mtx);
            g_service = fallback;
        }
    }

    pickScreensaver(c);
    addMatch(c,
             "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'");
    addMatch(c,
             "type='signal',interface='org.gnome.ScreenSaver',member='ActiveChanged'");
    addMatch(c,
             "type='signal',interface='org.freedesktop.login1.Session',member='Lock'");
    addMatch(c,
             "type='signal',interface='org.freedesktop.login1.Session',member='Unlock'");
    addMatch(c,
             "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'");
    addMatch(c,
             "type='signal',interface='org.kde.KGlobalSettings',member='notifyChange'");
    dbus_connection_add_filter(c, filter, nullptr, nullptr);

    {
        std::lock_guard<std::mutex> lock(g_mtx);
        g_conn = c;
    }
    return c;
}

void pumpLoop() {
    while (g_running.load(std::memory_order_acquire)) {
        DBusConnection* c = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_mtx);
            c = g_conn;
        }
        if (c != nullptr) {
            dbus_connection_read_write_dispatch(c, 50);
        } else {
            if (g_screen_events.load(std::memory_order_acquire) || g_inhibit_on) {
                ensureConn();
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
        }
    }
}

// ── 防休眠抑制 ────────────────────────────────────────────────────
DBusMessage* inhibitCall(DBusConnection* c, const char* method,
                         const char* a, const char* b, uint32_t cookie) {
    std::string svc, path;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        svc = g_ss_service;
        path = g_ss_path;
    }
    DBusMessage* msg = dbus_message_new_method_call(svc.c_str(), path.c_str(),
                                                    svc.c_str(), method);
    if (std::strcmp(method, "Inhibit") == 0) {
        dbus_message_append_args(msg, DBUS_TYPE_STRING, &a, DBUS_TYPE_STRING, &b,
                                 DBUS_TYPE_INVALID);
    } else {
        dbus_message_append_args(msg, DBUS_TYPE_UINT32, &cookie,
                                 DBUS_TYPE_INVALID);
    }
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply =
        dbus_connection_send_with_reply_and_block(c, msg, 5000, &err);
    dbus_message_unref(msg);
    dbus_error_free(&err);
    return reply;
}

// ── 单实例（文件锁）───────────────────────────────────────────────
int g_instance_fd = -1;

// ── 窗口状态（dlopen GTK/GDK 轻轮询）──────────────────────────────
namespace gtkwin {

constexpr int kGdkStateIconified = 1 << 1;

void* g_gtk = nullptr;
void* g_gdk = nullptr;
void* g_glib = nullptr;
bool g_loaded = false;

void* (*g_main_context_default)() = nullptr;
void (*g_main_context_invoke)(void*, void (*)(void*), void*) = nullptr;
unsigned (*g_timeout_add)(unsigned, int (*)(void*), void*) = nullptr;
int (*g_source_remove)(unsigned) = nullptr;
void* (*gtk_window_list_toplevels)() = nullptr;
int (*gtk_widget_get_visible)(void*) = nullptr;
int (*gtk_window_is_active)(void*) = nullptr;
void* (*gtk_widget_get_window)(void*) = nullptr;
int (*gdk_window_get_state)(void*) = nullptr;

void* g_win = nullptr;
unsigned g_timer = 0;
std::atomic<bool> g_enabled{false};
std::atomic<bool> g_minimized{false};
std::atomic<bool> g_focused{true};

template <typename T>
T sym(void* handle, const char* name) {
    return reinterpret_cast<T>(dlsym(handle, name));
}

bool load() {
    if (g_loaded) return true;
    g_gtk = dlopen("libgtk-3.so.0", RTLD_NOW);
    if (g_gtk == nullptr) g_gtk = dlopen(nullptr, RTLD_NOW);
    g_gdk = dlopen("libgdk-3.so.0", RTLD_NOW);
    if (g_gdk == nullptr) g_gdk = g_gtk;
    g_glib = dlopen("libglib-2.0.so.0", RTLD_NOW);
    if (g_glib == nullptr) g_glib = g_gtk;
    if (g_gtk == nullptr || g_glib == nullptr) return false;
    g_main_context_default = sym<decltype(g_main_context_default)>(
        g_glib, "g_main_context_default");
    g_main_context_invoke = sym<decltype(g_main_context_invoke)>(
        g_glib, "g_main_context_invoke");
    g_timeout_add = sym<decltype(g_timeout_add)>(g_glib, "g_timeout_add");
    g_source_remove = sym<decltype(g_source_remove)>(g_glib, "g_source_remove");
    gtk_window_list_toplevels = sym<decltype(gtk_window_list_toplevels)>(
        g_gtk, "gtk_window_list_toplevels");
    gtk_widget_get_visible = sym<decltype(gtk_widget_get_visible)>(
        g_gtk, "gtk_widget_get_visible");
    gtk_window_is_active = sym<decltype(gtk_window_is_active)>(
        g_gtk, "gtk_window_is_active");
    gtk_widget_get_window = sym<decltype(gtk_widget_get_window)>(
        g_gtk, "gtk_widget_get_window");
    gdk_window_get_state = sym<decltype(gdk_window_get_state)>(
        g_gdk, "gdk_window_get_state");
    g_loaded = g_main_context_default != nullptr &&
               g_main_context_invoke != nullptr && g_timeout_add != nullptr &&
               g_source_remove != nullptr &&
               gtk_window_list_toplevels != nullptr &&
               gtk_widget_get_visible != nullptr &&
               gtk_window_is_active != nullptr &&
               gtk_widget_get_window != nullptr &&
               gdk_window_get_state != nullptr;
    return g_loaded;
}

bool available() { return load(); }

void emit() {
    if (!g_enabled.load(std::memory_order_acquire)) return;
    dispatch(makeWindowState(g_minimized.load(std::memory_order_acquire),
                             g_focused.load(std::memory_order_acquire)));
}

int poll(void*) {
    if (g_win == nullptr) return 1;  // G_SOURCE_CONTINUE
    const bool active = gtk_window_is_active(g_win) != 0;
    bool minimized = false;
    void* gdkwin = gtk_widget_get_window(g_win);
    if (gdkwin != nullptr) {
        minimized = (gdk_window_get_state(gdkwin) & kGdkStateIconified) != 0;
    }
    if (active != g_focused.load(std::memory_order_acquire) ||
        minimized != g_minimized.load(std::memory_order_acquire)) {
        g_focused.store(active, std::memory_order_release);
        g_minimized.store(minimized, std::memory_order_release);
        emit();
    }
    return 1;
}

void setupOnMainThread(void*) {
    struct GList {
        void* data;
        GList* next;
        GList* prev;
    };
    auto* it = static_cast<GList*>(gtk_window_list_toplevels());
    while (it != nullptr) {
        void* win = it->data;
        if (win != nullptr && gtk_widget_get_visible(win) != 0) {
            g_win = win;
            break;
        }
        it = it->next;
    }
    if (g_win == nullptr) return;
    poll(nullptr);
    if (g_timer == 0) g_timer = g_timeout_add(500, poll, nullptr);
}

int32_t setEvents(bool on) {
    if (!load()) return ERR_UNSUPPORTED;
    if (on) {
        g_enabled.store(true, std::memory_order_release);
        g_main_context_invoke(g_main_context_default(), setupOnMainThread,
                              nullptr);
        return OK;
    }
    g_enabled.store(false, std::memory_order_release);
    if (g_timer != 0) {
        g_source_remove(g_timer);
        g_timer = 0;
    }
    return OK;
}

}  // namespace gtkwin

// ── 系统提示 ──────────────────────────────────────────────────────
bool notifyViaDbus(const char* title, const char* body) {
    DBusConnection* c = ensureConn();
    if (c == nullptr) return false;
    DBusMessage* msg = dbus_message_new_method_call(
        "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "Notify");
    DBusMessageIter it, actions, hints;
    dbus_message_iter_init_append(msg, &it);
    const char* app = "ArchoeraMusic";
    uint32_t replaces = 0;
    const char* icon = "";
    const char* summary = title;
    const char* text = body;
    int32_t timeout = -1;
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &app);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &replaces);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &icon);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &summary);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &text);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &actions);
    dbus_message_iter_close_container(&it, &actions);
    dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &hints);
    dbus_message_iter_close_container(&it, &hints);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_INT32, &timeout);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply =
        dbus_connection_send_with_reply_and_block(c, msg, 3000, &err);
    dbus_message_unref(msg);
    const bool ok = reply != nullptr;
    if (reply != nullptr) dbus_message_unref(reply);
    dbus_error_free(&err);
    return ok;
}

}  // namespace

// ── 后端接口 ──────────────────────────────────────────────────────
uint32_t caps() {
    uint32_t c = CAP_POWER_INHIBIT | CAP_POWER_SCREEN_STATE | CAP_MEDIA_SESSION |
                 CAP_MEDIA_SEEK | CAP_MEDIA_ARTWORK | CAP_APP_INSTANCE |
                 CAP_SYSTEM_ACCENT;
    const bool hasDisplay = std::getenv("WAYLAND_DISPLAY") != nullptr ||
                            std::getenv("DISPLAY") != nullptr;
    if (hasDisplay && gtkwin::available()) c |= CAP_WINDOW_STATE;
    return c;
}

int32_t init() {
    dbus_threads_init_default();
    g_running.store(true, std::memory_order_release);
    g_pump = new std::thread(pumpLoop);
    return OK;
}

int32_t shutdown() {
    g_running.store(false, std::memory_order_release);
    if (g_pump != nullptr) {
        if (g_pump->joinable()) g_pump->join();
        delete g_pump;
        g_pump = nullptr;
    }
    gtkwin::setEvents(false);
    std::lock_guard<std::mutex> lock(g_mtx);
    if (g_conn != nullptr) {
        dbus_connection_remove_filter(g_conn, filter, nullptr);
        dbus_connection_unref(g_conn);
        g_conn = nullptr;
    }
    g_cookie = 0;
    g_inhibit_on = false;
    g_screen_events.store(false, std::memory_order_release);
    g_accent_events.store(false, std::memory_order_release);
    return OK;
}

int32_t powerSetSleepInhibit(int32_t on) {
    if (on != 0) {
        if (g_inhibit_on) return OK;
        DBusConnection* c = ensureConn();
        if (c == nullptr) return ERR_BACKEND;
        DBusMessage* reply = inhibitCall(c, "Inhibit", "ArchoeraMusic",
                                         "playback", 0);
        if (reply == nullptr) return ERR_BACKEND;
        uint32_t cookie = 0;
        const bool ok = dbus_message_get_args(reply, nullptr, DBUS_TYPE_UINT32,
                                              &cookie, DBUS_TYPE_INVALID);
        dbus_message_unref(reply);
        if (!ok || cookie == 0) return ERR_BACKEND;
        std::lock_guard<std::mutex> lock(g_mtx);
        g_cookie = cookie;
        g_inhibit_on = true;
        return OK;
    }
    if (!g_inhibit_on || g_cookie == 0) return OK;
    DBusConnection* c = ensureConn();
    if (c == nullptr) return ERR_BACKEND;
    uint32_t cookie;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        cookie = g_cookie;
    }
    DBusMessage* reply = inhibitCall(c, "UnInhibit", nullptr, nullptr, cookie);
    if (reply == nullptr) return ERR_BACKEND;
    dbus_message_unref(reply);
    std::lock_guard<std::mutex> lock(g_mtx);
    g_cookie = 0;
    g_inhibit_on = false;
    return OK;
}

int32_t powerSetScreenEvents(int32_t on) {
    if (ensureConn() == nullptr) return ERR_BACKEND;
    g_screen_events.store(on != 0, std::memory_order_release);
    return OK;
}

int32_t windowSetEvents(int32_t on) { return gtkwin::setEvents(on != 0); }

int32_t mediaSetTrack(const AplTrackMeta* meta) {
    DBusConnection* c = ensureConn();
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        g_title.clear();
        g_artist.clear();
        g_album.clear();
        g_art.clear();
        g_track_serial++;
        g_duration_ms = -1;
        if (meta != nullptr) {
            auto str = [](const AplString& s) {
                return (s.data != nullptr && s.len > 0)
                           ? std::string(s.data, s.len)
                           : std::string();
            };
            g_title = str(meta->title);
            g_artist = str(meta->artist);
            g_album = str(meta->album);
            g_art = str(meta->art_url);
            g_duration_ms = meta->duration_ms;
            g_position_ms = 0;
            g_position_base = nowMs();
        }
    }
    emitChanged(c, {"Metadata"});
    return OK;
}

int32_t mediaSetPlayback(int32_t state, int64_t position_ms, double speed,
                         double volume, int32_t loop, int32_t shuffle) {
    DBusConnection* c = ensureConn();
    bool state_changed;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        const int new_state = ((state % 3) + 3) % 3;
        state_changed = new_state != g_state;
        g_state = new_state;
        g_position_ms = position_ms;
        g_position_base = nowMs();
        g_rate = speed;
        g_volume = volume;
        g_loop = loop;
        g_shuffle = shuffle != 0;
    }
    std::vector<const char*> changed;
    if (state_changed) changed.push_back("PlaybackStatus");
    changed.push_back("Position");
    changed.push_back("Volume");
    changed.push_back("LoopStatus");
    changed.push_back("Shuffle");
    emitChanged(c, changed);
    return OK;
}

int32_t mediaSetWindow(int64_t) { return OK; }

int32_t appInstanceAcquire() {
    if (g_instance_fd >= 0) return 1;
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    std::string dir = runtime != nullptr ? runtime : "/tmp";
    std::string path = dir + "/archoera_music.lock";
    const int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return ERR_BACKEND;
    if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        ::close(fd);
        return 0;
    }
    g_instance_fd = fd;
    return 1;
}

// 系统主题色（DE accent）：优先 **XDG Desktop Portal**（跨 DE 标准）：
//   org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop
//   org.freedesktop.portal.Settings.ReadOne("org.freedesktop.appearance","accent-color")
//   → v 内含 (ddd)（sRGB，[0,1]）。失败回退 KDE/GNOME 命令（旧环境）。
bool accentViaPortal(int32_t* r, int32_t* g, int32_t* b) {
    DBusConnection* c = ensureConn();
    if (c == nullptr) return false;
    DBusMessage* msg = dbus_message_new_method_call(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings", "ReadOne");
    if (msg == nullptr) return false;
    const char* ns = "org.freedesktop.appearance";
    const char* key = "accent-color";
    dbus_message_append_args(msg, DBUS_TYPE_STRING, &ns, DBUS_TYPE_STRING, &key,
                             DBUS_TYPE_INVALID);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage* reply =
        dbus_connection_send_with_reply_and_block(c, msg, 3000, &err);
    dbus_message_unref(msg);
    bool ok = false;
    double rr = 0, gg = 0, bb = 0;
    if (reply != nullptr) {
        DBusMessageIter it, var, st;
        if (dbus_message_iter_init(reply, &it) &&
            dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
            dbus_message_iter_recurse(&it, &var);
            if (dbus_message_iter_get_arg_type(&var) == DBUS_TYPE_STRUCT) {
                dbus_message_iter_recurse(&var, &st);
                if (dbus_message_iter_get_arg_type(&st) == DBUS_TYPE_DOUBLE) {
                    dbus_message_iter_get_basic(&st, &rr);
                    dbus_message_iter_next(&st);
                    dbus_message_iter_get_basic(&st, &gg);
                    dbus_message_iter_next(&st);
                    dbus_message_iter_get_basic(&st, &bb);
                    ok = true;
                }
            }
        }
        dbus_message_unref(reply);
    }
    dbus_error_free(&err);
    if (!ok) return false;
    auto toU8 = [](double v) -> int32_t {
        if (v <= 0.0) return 0;
        if (v >= 1.0) return 255;
        return static_cast<int32_t>(v * 255.0 + 0.5);
    };
    if (r != nullptr) *r = toU8(rr);
    if (g != nullptr) *g = toU8(gg);
    if (b != nullptr) *b = toU8(bb);
    return true;
}

bool systemAccent(int32_t* r, int32_t* g, int32_t* b) {
    // 仅走 XDG Desktop Portal（零子进程）；无 portal / 无 accent-color 时返回 false。
    return accentViaPortal(r, g, b);
}

int32_t systemAccentSetEvents(bool on) {
    g_accent_events.store(on, std::memory_order_release);
    if (on) ensureConn();
    return OK;
}

int32_t notify(const char* title, const char* body) {
    // 仅走 D-Bus org.freedesktop.Notifications（零子进程）。
    return notifyViaDbus(title, body) ? OK : ERR_BACKEND;
}

}  // namespace archoera

// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ArchoeraOS 会话客户端（Linux/Wayland）——绑定 `archoera_shell_v1`。
//!
//! 设计要点：
//!  - **dlopen libwayland-client**（同 GTK 处理）：不新增链接依赖，因而打包/CI
//!    无需声明 libwayland-client；头文件仅用核心类型，协议接口手写。
//!  - **独立连接**：应用已是 Wayland 客户端（GTK），这里再开一条连接专门做会话
//!    控制，互不干扰。
//!  - **专用泵线程 + 事件 fd 唤醒**：所有 Wayland 调用（marshal/dispatch）都在泵
//!    线程执行；Dart 线程只把请求压入队列并写 eventfd，避免 libwayland 的线程
//!    安全问题。
//!  - 手写接口与 `os/protocol/archoera-shell-v1.xml`（version 5）逐字段对应；
//!    事件/请求的 opcode 顺序必须与 XML 一致。

#include "os_session.h"

#if defined(__linux__)

#include "core.h"

#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <wayland-client-core.h>

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace archoera {
namespace os_session {
namespace {

using wl_display = struct wl_display;
using wl_proxy = struct wl_proxy;

// ── archoera_shell_v1（对齐 os/protocol/archoera-shell-v1.xml v5）──────
constexpr uint32_t kInterfaceVersion = 5;

// 请求 opcode（顺序即 XML 中 <request> 出现顺序）。
enum Op : uint32_t {
    OP_DESTROY = 0,
    OP_POWER_OFF,
    OP_REBOOT,
    OP_SET_BRIGHTNESS,
    OP_SET_VOLUME,
    OP_SUSPEND,
    OP_HIBERNATE,
    OP_SET_SCREEN_ENABLED,
    OP_SET_OUTPUT_SCALE,
    OP_SET_OUTPUT_MODE,
    OP_SET_OUTPUT_TRANSFORM,
    // v5：per-output 精确设置（按 output_info 下发的 output id）。
    OP_OUTPUT_SET_MODE,
    OP_OUTPUT_SET_SCALE,
    OP_OUTPUT_SET_TRANSFORM,
    OP_KEY,
};

// 事件 opcode。
enum Ev : uint32_t {
    EV_CAPABILITIES = 0,
    EV_BRIGHTNESS_CHANGED,
    EV_VOLUME_CHANGED,
    EV_MEDIA_KEY,
    EV_BATTERY,
    EV_SESSION,
    EV_POWER_KEY,
    EV_SCREEN_ENABLED_CHANGED,
    EV_OUTPUT_STATE,
    // v5：per-output 描述（info/current/mode…/modes_end）。
    EV_OUTPUT_INFO,
    EV_OUTPUT_CURRENT,
    EV_OUTPUT_MODE,
    EV_OUTPUT_MODES_END,
};

constexpr uint32_t kMarshalFlagDestroy = 1;

const struct wl_message kRequests[] = {
    {"destroy", "", nullptr},
    {"power_off", "", nullptr},
    {"reboot", "", nullptr},
    {"set_brightness", "u", nullptr},
    {"set_volume", "u", nullptr},
    {"suspend", "", nullptr},
    {"hibernate", "", nullptr},
    {"set_screen_enabled", "u", nullptr},
    {"set_output_scale", "u", nullptr},
    {"set_output_mode", "uu", nullptr},
    {"set_output_transform", "u", nullptr},
    {"output_set_mode", "uu", nullptr},
    {"output_set_scale", "uu", nullptr},
    {"output_set_transform", "uu", nullptr},
    {"key", "uu", nullptr},
};

const struct wl_message kEvents[] = {
    {"capabilities", "u", nullptr},
    {"brightness_changed", "u", nullptr},
    {"volume_changed", "u", nullptr},
    {"media_key", "u", nullptr},
    {"battery", "uuu", nullptr},
    {"session", "u", nullptr},
    {"power_key", "u", nullptr},
    {"screen_enabled_changed", "u", nullptr},
    {"output_state", "uuuuu", nullptr},
    {"output_info", "usu", nullptr},
    {"output_current", "uuuuuu", nullptr},
    {"output_mode", "uuuuuu", nullptr},
    {"output_modes_end", "uu", nullptr},
};

const struct wl_interface kShellInterface = {
    "archoera_shell_v1",
    static_cast<int>(kInterfaceVersion),
    15,
    kRequests,
    13,
    kEvents,
};

// ── libwayland-client 动态符号 ────────────────────────────────────
struct WlApi {
    wl_display* (*display_connect)(const char*);
    void (*display_disconnect)(wl_display*);
    int (*display_get_fd)(wl_display*);
    int (*display_roundtrip)(wl_display*);
    int (*display_flush)(wl_display*);
    int (*display_dispatch_pending)(wl_display*);
    int (*display_prepare_read)(wl_display*);
    int (*display_read_events)(wl_display*);
    void (*display_cancel_read)(wl_display*);
    const wl_interface* registry_interface;  // libwayland-client 导出的数据符号
    wl_proxy* (*proxy_marshal_flags)(wl_proxy*, uint32_t, const wl_interface*,
                                     uint32_t, uint32_t, ...);
    int (*proxy_add_listener)(wl_proxy*, void (**)(void), void*);
    uint32_t (*proxy_get_version)(wl_proxy*);
    void (*proxy_destroy)(wl_proxy*);
};

const WlApi* g_api = nullptr;  // dlopen 一次，进程内不变

bool loadApi() {
    if (g_api != nullptr) return true;
    void* lib = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) {
        fprintf(stderr, "[os] dlopen libwayland-client 失败: %s\n", dlerror());
        return false;
    }
    auto* api = new WlApi{};
    bool ok = true;
    auto sym = [&](const char* name) -> void* {
        void* p = dlsym(lib, name);
        if (p == nullptr) {
            fprintf(stderr, "[os] dlsym 缺失: %s\n", name);
            ok = false;
        }
        return p;
    };
    api->display_connect = reinterpret_cast<decltype(api->display_connect)>(sym("wl_display_connect"));
    api->display_disconnect =
        reinterpret_cast<decltype(api->display_disconnect)>(sym("wl_display_disconnect"));
    api->display_get_fd = reinterpret_cast<decltype(api->display_get_fd)>(sym("wl_display_get_fd"));
    api->display_roundtrip =
        reinterpret_cast<decltype(api->display_roundtrip)>(sym("wl_display_roundtrip"));
    api->display_flush = reinterpret_cast<decltype(api->display_flush)>(sym("wl_display_flush"));
    api->display_dispatch_pending = reinterpret_cast<decltype(api->display_dispatch_pending)>(
        sym("wl_display_dispatch_pending"));
    api->display_prepare_read =
        reinterpret_cast<decltype(api->display_prepare_read)>(sym("wl_display_prepare_read"));
    api->display_read_events =
        reinterpret_cast<decltype(api->display_read_events)>(sym("wl_display_read_events"));
    api->display_cancel_read =
        reinterpret_cast<decltype(api->display_cancel_read)>(sym("wl_display_cancel_read"));
    api->registry_interface =
        reinterpret_cast<const wl_interface*>(sym("wl_registry_interface"));
    api->proxy_marshal_flags = reinterpret_cast<decltype(api->proxy_marshal_flags)>(
        sym("wl_proxy_marshal_flags"));
    api->proxy_add_listener =
        reinterpret_cast<decltype(api->proxy_add_listener)>(sym("wl_proxy_add_listener"));
    api->proxy_get_version =
        reinterpret_cast<decltype(api->proxy_get_version)>(sym("wl_proxy_get_version"));
    api->proxy_destroy = reinterpret_cast<decltype(api->proxy_destroy)>(sym("wl_proxy_destroy"));
    if (!ok) {
        delete api;
        return false;
    }
    g_api = api;
    return true;
}

// 「无 public symbol」：wl_display.get_registry 是 header inline，等价手写。
wl_proxy* getRegistry(wl_display* display) {
    auto* display_proxy = reinterpret_cast<wl_proxy*>(display);
    const uint32_t version = g_api->proxy_get_version(display_proxy);
    return g_api->proxy_marshal_flags(display_proxy, 1 /*WL_DISPLAY_GET_REGISTRY*/,
                                      g_api->registry_interface, version, 0, nullptr);
}

// ── 状态 ──────────────────────────────────────────────────────────
std::atomic<bool> g_available{false};

std::mutex g_state_mtx;          // 保护 start/stop 与连接指针
wl_display* g_display = nullptr; // 泵线程启动后只读（start/stop 用 happens-before 保证）
wl_proxy* g_registry = nullptr;
wl_proxy* g_shell = nullptr;
int g_wake_fd = -1;
std::thread* g_thread = nullptr;  // 堆指针：避免静态析构 std::terminate
std::atomic<bool> g_running{false};

// 探测期记录全局对象。
uint32_t g_seen_name = 0;
uint32_t g_seen_version = 0;
bool g_seen = false;

// 输出注册表（协议 v5）：由泵线程在 output_info/current/mode/modes_end 中写入，
// Dart 线程经 outputList/outputModes 读取（快照式，不走事件回调）。
struct OutputModeEntry {
    uint32_t index = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t refresh = 0;  // mHz
    uint32_t flags = 0;    // protocol output_flag
};
struct OutputEntry {
    uint32_t id = 0;
    std::string name;
    uint32_t flags = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t scale_milli = 1000;
    uint32_t transform = 0;
    uint32_t refresh = 0;  // mHz
    std::vector<OutputModeEntry> modes;
};
std::mutex g_outputs_mtx;  // 保护 g_outputs
std::vector<OutputEntry> g_outputs;

// 取（或新建）某 id 的条目；调用方须持有 g_outputs_mtx。
OutputEntry& outputFor(uint32_t id) {
    for (auto& o : g_outputs) {
        if (o.id == id) return o;
    }
    g_outputs.push_back(OutputEntry{});
    g_outputs.back().id = id;
    return g_outputs.back();
}

void clearOutputs() {
    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    g_outputs.clear();
}

// 请求队列（marshal 只在泵线程做）。
struct Request {
    uint32_t op;
    uint32_t arg;
    uint32_t arg2;
};
std::mutex g_queue_mtx;
std::vector<Request> g_queue;

// ── 事件监听器 ────────────────────────────────────────────────────
void on_capabilities(void*, wl_proxy*, uint32_t flags) {
    dispatch(makeOsCapabilities(flags));
}
void on_brightness(void*, wl_proxy*, uint32_t percent) {
    dispatch(makeOsBrightness(static_cast<int32_t>(percent)));
}
void on_volume(void*, wl_proxy*, uint32_t percent) {
    dispatch(makeOsVolume(static_cast<int32_t>(percent)));
}
void on_media_key(void*, wl_proxy*, uint32_t key) {
    // XML media_key：0=play_pause 1=next 2=previous 3=stop 4=volume_up 5=volume_down 6=mute
    switch (key) {
        case 0: dispatch(makeCommand(CMD_TOGGLE)); break;
        case 1: dispatch(makeCommand(CMD_NEXT)); break;
        case 2: dispatch(makeCommand(CMD_PREV)); break;
        case 3: dispatch(makeCommand(CMD_STOP)); break;
        case 4: dispatch(makeCommand(CMD_VOLUME_UP)); break;
        case 5: dispatch(makeCommand(CMD_VOLUME_DOWN)); break;
        case 6: dispatch(makeCommand(CMD_VOLUME_MUTE)); break;
        default: break;
    }
}
void on_battery(void*, wl_proxy*, uint32_t present, uint32_t percent, uint32_t charging) {
    dispatch(makeOsBattery(static_cast<int32_t>(present), static_cast<int32_t>(percent),
                           static_cast<int32_t>(charging)));
}
void on_session(void*, wl_proxy*, uint32_t state) {
    dispatch(makeOsSession(static_cast<int32_t>(state)));
}
void on_power_key(void*, wl_proxy*, uint32_t key) {
    dispatch(makeOsPowerKey(static_cast<int32_t>(key)));
}
void on_screen_enabled(void*, wl_proxy*, uint32_t enabled) {
    dispatch(makeOsScreen(enabled != 0));
}
void on_output_state(void*, wl_proxy*, uint32_t width, uint32_t height, uint32_t scale_milli,
                     uint32_t transform, uint32_t refresh_millihz) {
    dispatch(makeOsOutput(static_cast<int32_t>(width), static_cast<int32_t>(height),
                          static_cast<int32_t>(scale_milli), static_cast<int32_t>(transform),
                          static_cast<int32_t>(refresh_millihz)));
}

void on_output_info(void*, wl_proxy*, uint32_t id, const char* name, uint32_t flags) {
    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    OutputEntry& o = outputFor(id);
    o.name = (name != nullptr) ? name : "";
    o.flags = flags;
}
void on_output_current(void*, wl_proxy*, uint32_t id, uint32_t width, uint32_t height,
                       uint32_t scale_milli, uint32_t transform, uint32_t refresh) {
    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    OutputEntry& o = outputFor(id);
    o.width = width;
    o.height = height;
    o.scale_milli = scale_milli;
    o.transform = transform;
    o.refresh = refresh;
}
void on_output_mode(void*, wl_proxy*, uint32_t id, uint32_t index, uint32_t width, uint32_t height,
                    uint32_t refresh, uint32_t flags) {
    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    OutputEntry& o = outputFor(id);
    // 按事件里的 index 落位：该下标必须与合成器的模式表一致，
    // 因为 output_set_mode 就是按同一下标寻址的。
    if (index >= o.modes.size()) o.modes.resize(index + 1);
    OutputModeEntry& m = o.modes[index];
    m.index = index;
    m.width = width;
    m.height = height;
    m.refresh = refresh;
    m.flags = flags;
}
void on_output_modes_end(void*, wl_proxy*, uint32_t id, uint32_t count) {
    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    OutputEntry& o = outputFor(id);
    // count 是权威条数：清掉可能残留的旧尾项。
    if (o.modes.size() > count) o.modes.resize(count);
}

struct ShellEvents {
    void (*capabilities)(void*, wl_proxy*, uint32_t);
    void (*brightness_changed)(void*, wl_proxy*, uint32_t);
    void (*volume_changed)(void*, wl_proxy*, uint32_t);
    void (*media_key)(void*, wl_proxy*, uint32_t);
    void (*battery)(void*, wl_proxy*, uint32_t, uint32_t, uint32_t);
    void (*session)(void*, wl_proxy*, uint32_t);
    void (*power_key)(void*, wl_proxy*, uint32_t);
    void (*screen_enabled_changed)(void*, wl_proxy*, uint32_t);
    void (*output_state)(void*, wl_proxy*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
    void (*output_info)(void*, wl_proxy*, uint32_t, const char*, uint32_t);
    void (*output_current)(void*, wl_proxy*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                           uint32_t);
    void (*output_mode)(void*, wl_proxy*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                        uint32_t);
    void (*output_modes_end)(void*, wl_proxy*, uint32_t, uint32_t);
};

const ShellEvents kShellEvents = {
    on_capabilities,  on_brightness,     on_volume,      on_media_key,
    on_battery,       on_session,        on_power_key,   on_screen_enabled,
    on_output_state,  on_output_info,    on_output_current,
    on_output_mode,   on_output_modes_end,
};

// ── registry 监听器（探测与正式连接共用）──────────────────────────
void on_registry_global(void*, wl_proxy*, uint32_t name, const char* interface,
                        uint32_t version) {
    if (interface != nullptr && std::strcmp(interface, "archoera_shell_v1") == 0) {
        g_seen = true;
        g_seen_name = name;
        g_seen_version = std::min<uint32_t>(version, kInterfaceVersion);
    }
}
void on_registry_global_remove(void*, wl_proxy*, uint32_t) {}

struct RegistryEvents {
    void (*global)(void*, wl_proxy*, uint32_t, const char*, uint32_t);
    void (*global_remove)(void*, wl_proxy*, uint32_t);
};
const RegistryEvents kRegistryEvents = {on_registry_global, on_registry_global_remove};

// ── 请求发送（仅泵线程调用）───────────────────────────────────────
// 注：`wl_proxy_marshal_flags` 的 interface 参数是**新对象接口**，仅构造型请求
// （bind/sync 等）才传；普通请求必须传 NULL，否则 libwayland 会当作建对象而丢弃。
void sendRequest(const Request& r) {
    if (g_shell == nullptr || g_api == nullptr) return;
    const uint32_t flags = (r.op == OP_DESTROY) ? kMarshalFlagDestroy : 0u;
    const uint32_t version = g_api->proxy_get_version(g_shell);
    switch (r.op) {
        case OP_SET_BRIGHTNESS:
        case OP_SET_VOLUME:
        case OP_SET_SCREEN_ENABLED:
        case OP_SET_OUTPUT_SCALE:
        case OP_SET_OUTPUT_TRANSFORM:
            g_api->proxy_marshal_flags(g_shell, r.op, nullptr, version, flags, r.arg);
            break;
        case OP_SET_OUTPUT_MODE:
        case OP_OUTPUT_SET_MODE:
        case OP_OUTPUT_SET_SCALE:
        case OP_OUTPUT_SET_TRANSFORM:
        case OP_KEY:
            g_api->proxy_marshal_flags(g_shell, r.op, nullptr, version, flags, r.arg, r.arg2);
            break;
        default:
            g_api->proxy_marshal_flags(g_shell, r.op, nullptr, version, flags);
            break;
    }
}

void drainQueue() {
    std::vector<Request> pending;
    {
        std::lock_guard<std::mutex> lock(g_queue_mtx);
        pending.swap(g_queue);
    }
    if (pending.empty()) return;
    for (const auto& r : pending) sendRequest(r);
    g_api->display_flush(g_display);
}

void onLost() {
    dispatch(makeBackendLost(true));
    g_running.store(false);
}

// ── 泵线程 ────────────────────────────────────────────────────────
void pumpLoop() {
    const WlApi* api = g_api;
    wl_display* display = g_display;
    const int display_fd = api->display_get_fd(display);

    while (g_running.load()) {
        drainQueue();

        while (api->display_prepare_read(display) != 0) {
            if (api->display_dispatch_pending(display) < 0) {
                onLost();
                return;
            }
        }
        api->display_flush(display);

        struct pollfd fds[2] = {
            {display_fd, POLLIN, 0},
            {g_wake_fd, POLLIN, 0},
        };
        const int rc = poll(fds, 2, -1);
        if (rc < 0) {
            api->display_cancel_read(display);
            if (errno == EINTR) continue;
            onLost();
            return;
        }

        bool read_ok = true;
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            if (api->display_read_events(display) < 0 && errno != EAGAIN) read_ok = false;
        } else {
            api->display_cancel_read(display);
        }
        if (fds[1].revents & POLLIN) {
            uint64_t v = 0;
            while (read(g_wake_fd, &v, sizeof(v)) == static_cast<ssize_t>(sizeof(v))) {
            }
        }
        if (!read_ok) {
            onLost();
            return;
        }
        if (api->display_dispatch_pending(display) < 0) {
            onLost();
            return;
        }
    }
}

// 回收已退出的泵线程（须在持 g_state_mtx 时调用）。
void joinStaleLocked() {
    if (g_thread != nullptr && !g_running.load()) {
        g_thread->join();
        delete g_thread;
        g_thread = nullptr;
    }
}

void teardownLocked() {
    clearOutputs();  // 连接重建后由 bind 重新下发
    if (g_thread != nullptr) {
        g_running.store(false);
        if (g_wake_fd >= 0) {
            uint64_t one = 1;
            ssize_t ignored = write(g_wake_fd, &one, sizeof(one));
            (void)ignored;
        }
        g_thread->join();
        delete g_thread;
        g_thread = nullptr;
    }
    if (g_api != nullptr) {
        if (g_shell != nullptr) {
            g_api->proxy_destroy(g_shell);
            g_shell = nullptr;
        }
        if (g_registry != nullptr) {
            g_api->proxy_destroy(g_registry);
            g_registry = nullptr;
        }
        if (g_display != nullptr) {
            g_api->display_disconnect(g_display);
            g_display = nullptr;
        }
    }
    if (g_wake_fd >= 0) {
        close(g_wake_fd);
        g_wake_fd = -1;
    }
}

// 连接 + 绑定（须在持 g_state_mtx 时调用）。
int32_t startLocked() {
    if (g_display != nullptr && g_running.load()) return OK;
    joinStaleLocked();
    teardownLocked();
    if (!g_available.load() || g_api == nullptr) return ERR_UNSUPPORTED;

    wl_display* display = g_api->display_connect(nullptr);
    if (display == nullptr) return ERR_BACKEND;

    wl_proxy* registry = getRegistry(display);
    g_api->proxy_add_listener(registry, reinterpret_cast<void (**)(void)>(const_cast<RegistryEvents*>(&kRegistryEvents)),
                              nullptr);
    g_seen = false;
    if (g_api->display_roundtrip(display) < 0) {
        g_api->proxy_destroy(registry);
        g_api->display_disconnect(display);
        return ERR_BACKEND;
    }
    if (!g_seen) {
        g_api->proxy_destroy(registry);
        g_api->display_disconnect(display);
        return ERR_UNSUPPORTED;
    }

    // wl_registry.bind(name, interface, version, new_id) → opcode 0。
    wl_proxy* shell = g_api->proxy_marshal_flags(
        registry, 0, &kShellInterface, g_seen_version, 0, g_seen_name, "archoera_shell_v1",
        g_seen_version, nullptr);
    if (shell == nullptr) {
        g_api->proxy_destroy(registry);
        g_api->display_disconnect(display);
        return ERR_BACKEND;
    }
    g_api->proxy_add_listener(
        shell, reinterpret_cast<void (**)(void)>(const_cast<ShellEvents*>(&kShellEvents)),
        nullptr);
    // 首次 roundtrip：合成器在 bind 后立即下发初始状态，直接转发给 Dart。
    if (g_api->display_roundtrip(display) < 0) {
        g_api->proxy_destroy(shell);
        g_api->proxy_destroy(registry);
        g_api->display_disconnect(display);
        return ERR_BACKEND;
    }

    g_display = display;
    g_registry = registry;
    g_shell = shell;
    g_wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (g_wake_fd < 0) {
        teardownLocked();
        return ERR_BACKEND;
    }
    g_running.store(true);
    g_thread = new std::thread(pumpLoop);
    return OK;
}

int32_t enqueue(uint32_t op, uint32_t arg, uint32_t arg2 = 0) {
    if (!g_available.load()) return ERR_UNSUPPORTED;
    {
        std::lock_guard<std::mutex> lock(g_state_mtx);
        if (!g_running.load()) {
            const int32_t rc = startLocked();
            if (rc != OK) return rc;
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_queue_mtx);
        g_queue.push_back(Request{op, arg, arg2});
    }
    const int wake = g_wake_fd;
    if (wake >= 0) {
        uint64_t one = 1;
        ssize_t ignored = write(wake, &one, sizeof(one));
        (void)ignored;
    }
    return OK;
}

}  // namespace

bool probe() {
    if (!loadApi()) {
        g_available.store(false);
        return false;
    }
    wl_display* display = g_api->display_connect(nullptr);
    if (display == nullptr) {
        g_available.store(false);
        return false;
    }
    wl_proxy* registry = getRegistry(display);
    g_api->proxy_add_listener(
        registry, reinterpret_cast<void (**)(void)>(const_cast<RegistryEvents*>(&kRegistryEvents)),
        nullptr);
    g_seen = false;
    const int rc = g_api->display_roundtrip(display);
    const bool found = (rc >= 0) && g_seen;
    g_api->proxy_destroy(registry);
    g_api->display_disconnect(display);
    g_available.store(found);
    return found;
}

bool available() { return g_available.load(); }

int32_t setEvents(bool on) {
    std::lock_guard<std::mutex> lock(g_state_mtx);
    if (!on) {
        teardownLocked();
        return OK;
    }
    return startLocked();
}

int32_t setBrightness(int32_t percent) { return enqueue(OP_SET_BRIGHTNESS, static_cast<uint32_t>(std::max(0, percent))); }
int32_t setVolume(int32_t percent) { return enqueue(OP_SET_VOLUME, static_cast<uint32_t>(std::max(0, percent))); }
int32_t setScreenEnabled(bool on) { return enqueue(OP_SET_SCREEN_ENABLED, on ? 1u : 0u); }
int32_t powerOff() { return enqueue(OP_POWER_OFF, 0); }
int32_t reboot() { return enqueue(OP_REBOOT, 0); }
int32_t suspend() { return enqueue(OP_SUSPEND, 0); }
int32_t hibernate() { return enqueue(OP_HIBERNATE, 0); }
int32_t setOutputScale(int32_t scaleMilli) {
    return enqueue(OP_SET_OUTPUT_SCALE, static_cast<uint32_t>(std::max(0, scaleMilli)));
}
int32_t setOutputMode(int32_t width, int32_t height) {
    return enqueue(OP_SET_OUTPUT_MODE, static_cast<uint32_t>(std::max(0, width)),
                   static_cast<uint32_t>(std::max(0, height)));
}
int32_t setOutputTransform(int32_t transform) {
    return enqueue(OP_SET_OUTPUT_TRANSFORM, static_cast<uint32_t>(std::max(0, transform)));
}
int32_t key(int32_t keycode, bool pressed) {
    return enqueue(OP_KEY, static_cast<uint32_t>(std::max(0, keycode)), pressed ? 1u : 0u);
}

namespace {
// 读取快照前确保会话连接已建立（与 enqueue 同策略：按需自动连接）。
// 返回 OK 或负值错误。
int32_t ensureConnected() {
    if (!g_available.load()) return ERR_UNSUPPORTED;
    std::lock_guard<std::mutex> lock(g_state_mtx);
    if (g_running.load()) return OK;
    return startLocked();
}
}  // namespace

int32_t outputList(AplOsOutput* out, uint32_t max, uint32_t* count) {
    if (out == nullptr || count == nullptr) return ERR_STATE;
    *count = 0;
    const int32_t rc = ensureConnected();
    if (rc != OK) return rc;

    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    *count = static_cast<uint32_t>(g_outputs.size());
    const uint32_t n = std::min<uint32_t>(max, *count);
    for (uint32_t i = 0; i < n; ++i) {
        const OutputEntry& o = g_outputs[i];
        AplOsOutput& dst = out[i];
        std::memset(&dst, 0, sizeof(dst));
        dst.id = o.id;
        std::snprintf(dst.name, sizeof(dst.name), "%s", o.name.c_str());
        dst.flags = o.flags;
        dst.width = o.width;
        dst.height = o.height;
        dst.scale_milli = o.scale_milli;
        dst.transform = o.transform;
        dst.refresh_millihz = o.refresh;
        dst.mode_count = static_cast<uint32_t>(o.modes.size());
    }
    return static_cast<int32_t>(*count);
}

int32_t outputModes(uint32_t outputId, AplOsOutputMode* out, uint32_t max, uint32_t* count) {
    if (out == nullptr || count == nullptr) return ERR_STATE;
    *count = 0;
    const int32_t rc = ensureConnected();
    if (rc != OK) return rc;

    std::lock_guard<std::mutex> lock(g_outputs_mtx);
    for (const OutputEntry& o : g_outputs) {
        if (o.id != outputId) continue;
        *count = static_cast<uint32_t>(o.modes.size());
        const uint32_t n = std::min<uint32_t>(max, *count);
        for (uint32_t i = 0; i < n; ++i) {
            const OutputModeEntry& m = o.modes[i];
            AplOsOutputMode& dst = out[i];
            dst.index = m.index;
            dst.width = m.width;
            dst.height = m.height;
            dst.refresh_millihz = m.refresh;
            dst.flags = m.flags;
        }
        return static_cast<int32_t>(*count);
    }
    return ERR_STATE;  // 没有这个输出
}

int32_t setOutputModeIndex(uint32_t outputId, uint32_t index) {
    return enqueue(OP_OUTPUT_SET_MODE, outputId, index);
}
int32_t setOutputScaleFor(uint32_t outputId, uint32_t scaleMilli) {
    return enqueue(OP_OUTPUT_SET_SCALE, outputId, scaleMilli);
}
int32_t setOutputTransformFor(uint32_t outputId, uint32_t transform) {
    return enqueue(OP_OUTPUT_SET_TRANSFORM, outputId, transform);
}

void shutdown() {
    std::lock_guard<std::mutex> lock(g_state_mtx);
    teardownLocked();
}

}  // namespace os_session
}  // namespace archoera

#endif  // __linux__

// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "core.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace archoera {
namespace {

std::mutex g_mutex;
bool g_initialized = false;
AplEventCallback g_callback = nullptr;
void* g_user_data = nullptr;

// 进程级事件槽**环形数组**：回调可能是异步 NativeCallable.listener，Dart 稍后读取
// 指针，若指向栈内存届时已失效；单个槽又会在初值突发（capabilities/亮度/音量/
// 电池/会话一次性下发）时互相覆盖。环形槽保证同一突发的每条事件各占一个槽，
// Dart 读到的是各自的值（极端积压时最多读到较新的一条，绝不读垃圾）。
constexpr size_t kEventSlots = 64;
AplEvent g_event_slots[kEventSlots]{};
std::atomic<uint32_t> g_event_slot_next{0};

}  // namespace

bool isInitialized() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_initialized;
}

void setInitialized(bool v) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_initialized = v;
}

void setEventCallback(AplEventCallback cb, void* user_data) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_callback = cb;
    g_user_data = user_data;
}

void dispatch(const AplEvent& event) {
    AplEventCallback cb;
    void* user;
    AplEvent* slot;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        const uint32_t index =
            g_event_slot_next.fetch_add(1, std::memory_order_relaxed) % kEventSlots;
        slot = &g_event_slots[index];
        *slot = event;
        cb = g_callback;
        user = g_user_data;
    }
    if (cb == nullptr) return;
    cb(slot, user);
}

AplEvent makeCommand(int32_t command) {
    AplEvent e{};
    e.type = APL_EVENT_MEDIA_COMMAND;
    e.u.command = command;
    return e;
}

AplEvent makeSeek(int64_t rel_ms, int64_t abs_ms) {
    AplEvent e{};
    e.type = APL_EVENT_MEDIA_SEEK;
    e.u.seek.rel_ms = rel_ms;
    e.u.seek.abs_ms = abs_ms;
    return e;
}

AplEvent makeScreenState(bool active) {
    AplEvent e{};
    e.type = APL_EVENT_SCREEN_STATE;
    e.u.active = active ? 1 : 0;
    return e;
}

AplEvent makeWindowState(bool minimized, bool focused) {
    AplEvent e{};
    e.type = APL_EVENT_WINDOW_STATE;
    e.u.window.minimized = minimized ? 1 : 0;
    e.u.window.focused = focused ? 1 : 0;
    return e;
}

AplEvent makeBackendLost(bool lost) {
    AplEvent e{};
    e.type = APL_EVENT_BACKEND_STATE;
    e.u.backend_lost = lost ? 1 : 0;
    return e;
}

AplEvent makeSystemAccent(int32_t r, int32_t g, int32_t b) {
    AplEvent e{};
    e.type = APL_EVENT_SYSTEM_ACCENT;
    e.u.accent.r = r;
    e.u.accent.g = g;
    e.u.accent.b = b;
    return e;
}

AplEvent makeSystemTheme(bool dark) {
    AplEvent e{};
    e.type = APL_EVENT_SYSTEM_THEME;
    e.u.theme.dark = dark ? 1 : 0;
    return e;
}

AplEvent makeOsCapabilities(uint32_t caps) {
    AplEvent e{};
    e.type = APL_EVENT_OS_CAPABILITIES;
    e.u.os_caps.caps = static_cast<int32_t>(caps);
    return e;
}

AplEvent makeOsBrightness(int32_t percent) {
    AplEvent e{};
    e.type = APL_EVENT_OS_BRIGHTNESS;
    e.u.os_value.value = percent;
    return e;
}

AplEvent makeOsVolume(int32_t percent) {
    AplEvent e{};
    e.type = APL_EVENT_OS_VOLUME;
    e.u.os_value.value = percent;
    return e;
}

AplEvent makeOsBattery(int32_t present, int32_t percent, int32_t charging) {
    AplEvent e{};
    e.type = APL_EVENT_OS_BATTERY;
    e.u.os_battery.present = present;
    e.u.os_battery.percent = percent;
    e.u.os_battery.charging = charging;
    return e;
}

AplEvent makeOsSession(int32_t state) {
    AplEvent e{};
    e.type = APL_EVENT_OS_SESSION;
    e.u.os_session.state = state;
    return e;
}

AplEvent makeOsScreen(bool enabled) {
    AplEvent e{};
    e.type = APL_EVENT_OS_SCREEN;
    e.u.os_screen.screen = enabled ? 1 : 0;
    return e;
}

AplEvent makeOsPowerKey(int32_t key) {
    AplEvent e{};
    e.type = APL_EVENT_OS_POWER_KEY;
    e.u.os_power_key.key = key;
    return e;
}

AplEvent makeOsOutput(int32_t width, int32_t height, int32_t scaleMilli, int32_t transform,
                      int32_t refreshMillihz) {
    AplEvent e{};
    e.type = APL_EVENT_OS_OUTPUT;
    e.u.os_output.width = width;
    e.u.os_output.height = height;
    e.u.os_output.scale_milli = scaleMilli;
    e.u.os_output.transform = transform;
    e.u.os_output.refresh_millihz = refreshMillihz;
    return e;
}

AplEvent makeBtPairPrompt(int32_t kind, int32_t passkey, int32_t entered, const char* text) {
    AplEvent e{};
    e.type = APL_EVENT_BT_PAIR_PROMPT;
    e.u.bt_pair_prompt.kind = kind;
    e.u.bt_pair_prompt.passkey = passkey;
    e.u.bt_pair_prompt.entered = entered;
    if (text != nullptr && text[0] != '\0') {
        std::snprintf(e.u.bt_pair_prompt.text, sizeof(e.u.bt_pair_prompt.text), "%s", text);
        e.u.bt_pair_prompt.has_text = 1;
    } else {
        e.u.bt_pair_prompt.text[0] = '\0';
        e.u.bt_pair_prompt.has_text = 0;
    }
    return e;
}

AplEvent makeBtPairResult(bool ok, int32_t err) {
    AplEvent e{};
    e.type = APL_EVENT_BT_PAIR_RESULT;
    e.u.bt_pair_result.ok = ok ? 1 : 0;
    e.u.bt_pair_result.err = err;
    return e;
}

}  // namespace archoera

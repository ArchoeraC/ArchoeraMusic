// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! archoera_platform —— C ABI 导出根（apl_*，契约见 include/archoera_platform.h）。
//! Dart（app/lib/services/platform/）仅依赖本 ABI；平台探测、转发、事件回传
//! 全部在 backend_* 内完成。零 JSON、零子进程、同进程动态链接。

#include "archoera_platform.h"

#include "backend.h"
#include "core.h"

namespace {
constexpr int32_t kAbiVersion = 3;
}  // namespace

extern "C" {

int32_t apl_abi_version(void) { return kAbiVersion; }

int32_t apl_init(void) {
    archoera::setInitialized(true);
    const int32_t rc = archoera::init();
    if (rc != archoera::OK) {
        archoera::setInitialized(false);
        return rc;
    }
    return archoera::OK;
}

int32_t apl_shutdown(void) {
    if (!archoera::isInitialized()) return archoera::OK;
    const int32_t rc = archoera::shutdown();
    archoera::setInitialized(false);
    return rc;
}

uint32_t apl_capabilities(void) { return archoera::caps(); }

int32_t apl_set_event_callback(AplEventCallback cb, void* user_data) {
    archoera::setEventCallback(cb, user_data);
    return archoera::OK;
}

void apl_set_log_sink(AplLogFn fn) { archoera::setLogSink(fn); }

int32_t apl_power_set_sleep_inhibit(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::powerSetSleepInhibit(on);
}

int32_t apl_power_set_screen_events(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::powerSetScreenEvents(on);
}

int32_t apl_window_set_events(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::windowSetEvents(on);
}

int32_t apl_media_set_track(const AplTrackMeta* track) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::mediaSetTrack(track);
}

int32_t apl_media_set_playback(int32_t state, int64_t position_ms, double speed,
                               double volume, int32_t loop, int32_t shuffle) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::mediaSetPlayback(state, position_ms, speed, volume, loop,
                                      shuffle);
}

int32_t apl_media_set_window(int64_t window) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::mediaSetWindow(window);
}

int32_t apl_instance_acquire(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::appInstanceAcquire();
}

int32_t apl_protocol_register(const char* scheme) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (scheme == nullptr || *scheme == '\0') return archoera::ERR_STATE;
    return archoera::protocolRegister(scheme);
}

int32_t apl_protocol_unregister(const char* scheme) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (scheme == nullptr || *scheme == '\0') return archoera::ERR_STATE;
    return archoera::protocolUnregister(scheme);
}

int32_t apl_deep_link_take(AplString* out) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (out == nullptr) return archoera::ERR_STATE;
    return archoera::deepLinkTake(out);
}

int32_t apl_deep_link_forward(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::deepLinkForward();
}

int32_t apl_window_activate(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::windowActivate();
}

int32_t apl_system_accent(int32_t* r, int32_t* g, int32_t* b) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (!archoera::systemAccent(r, g, b)) return archoera::ERR_BACKEND;
    return archoera::OK;
}

int32_t apl_system_accent_set_events(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::systemAccentSetEvents(on != 0);
}

int32_t apl_system_theme_set_events(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::systemThemeSetEvents(on != 0);
}

int32_t apl_notify(const char* title, const char* body) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (title == nullptr) return archoera::ERR_BACKEND;
    return archoera::notify(title, body != nullptr ? body : "");
}

int32_t apl_reveal_path(const char* path) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (path == nullptr || *path == '\0') return archoera::ERR_STATE;
    return archoera::revealPath(path);
}

int32_t apl_tray_create(const char* icon_path) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (icon_path == nullptr || *icon_path == '\0') return archoera::ERR_STATE;
    return archoera::trayCreate(icon_path);
}

int32_t apl_tray_destroy(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::trayDestroy();
}

int32_t apl_tray_set_icon(const char* icon_path) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (icon_path == nullptr || *icon_path == '\0') return archoera::ERR_STATE;
    return archoera::traySetIcon(icon_path);
}

int32_t apl_tray_set_tooltip(const char* tooltip) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::traySetTooltip(tooltip != nullptr ? tooltip : "");
}

int32_t apl_tray_set_visible(int32_t visible) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::traySetVisible(visible != 0);
}

int32_t apl_tray_set_menu(const AplTrayMenuItem* items, int32_t count) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (count < 0 || (count > 0 && items == nullptr)) return archoera::ERR_STATE;
    return archoera::traySetMenu(items, count);
}

int32_t apl_tray_set_menu_trigger(int32_t trigger) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::traySetMenuTrigger(trigger);
}

}  // extern "C"

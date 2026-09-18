// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! archoera_platform —— C ABI 导出根（apl_*，契约见 include/archoera_platform.h）。
//! Dart（app/lib/services/platform/）仅依赖本 ABI；平台探测、转发、事件回传
//! 全部在 backend_* 内完成。零 JSON、零子进程、同进程动态链接。

#include "archoera_platform.h"

#include "backend.h"
#include "core.h"
#include "sysinfo.h"

namespace {
constexpr int32_t kAbiVersion = 1;
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

/* ── ArchoeraOS 会话 ── */
int32_t apl_os_set_events(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetEvents(on);
}

int32_t apl_os_set_brightness(int32_t percent) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetBrightness(percent);
}

int32_t apl_os_set_volume(int32_t percent) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetVolume(percent);
}

int32_t apl_os_set_screen_enabled(int32_t on) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetScreenEnabled(on);
}

int32_t apl_os_power_off(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionPowerOff();
}

int32_t apl_os_reboot(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionReboot();
}

int32_t apl_os_suspend(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSuspend();
}

int32_t apl_os_hibernate(void) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionHibernate();
}

int32_t apl_os_set_output_scale(int32_t scale_milli) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetOutputScale(scale_milli);
}

int32_t apl_os_set_output_mode(int32_t width, int32_t height) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetOutputMode(width, height);
}

int32_t apl_os_set_output_transform(int32_t transform) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionSetOutputTransform(transform);
}

int32_t apl_os_key(int32_t keycode, int32_t state) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::osSessionKey(keycode, state);
}

int32_t apl_sys_stats(AplSysStats* out) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::sysinfo::stats(out);
}

int32_t apl_bt_state(AplBtState* out) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    return archoera::sysinfo::btState(out);
}

int32_t apl_notify(const char* title, const char* body) {
    if (!archoera::isInitialized()) return archoera::ERR_STATE;
    if (title == nullptr) return archoera::ERR_BACKEND;
    return archoera::notify(title, body != nullptr ? body : "");
}

}  // extern "C"

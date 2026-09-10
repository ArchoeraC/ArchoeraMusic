// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! archoera_platform —— C ABI 导出根（apl_*，契约见 include/archoera_platform.h）
//!
//! Dart（app/lib/services/platform/）仅依赖本 ABI；平台探测、转发、事件回传
//! 全部在本模块内完成（docs/platform-native-bridge.md 决策 #2）。零 JSON、
//! 零子进程、同进程动态链接。

const std = @import("std");
const core = @import("core.zig");
const backend = @import("backend.zig");

const ABI_VERSION: i32 = 1;

// ── 生命周期 ──────────────────────────────────────────────────────

export fn apl_abi_version() callconv(.c) i32 {
    return ABI_VERSION;
}

export fn apl_init() callconv(.c) i32 {
    core.setInitialized(true);
    return core.OK;
}

export fn apl_shutdown() callconv(.c) i32 {
    if (!core.isInitialized()) return core.OK;
    const rc = backend.shutdown();
    core.setInitialized(false);
    return rc;
}

export fn apl_capabilities() callconv(.c) u32 {
    return backend.caps();
}

// ── 反向事件回调 ──────────────────────────────────────────────────

export fn apl_set_event_callback(cb: ?core.Callback, user_data: ?*anyopaque) callconv(.c) i32 {
    core.setEventCallback(cb, user_data);
    return core.OK;
}

// ── SystemPower ───────────────────────────────────────────────────

export fn apl_power_set_sleep_inhibit(on: i32) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.powerSetSleepInhibit(on);
}

export fn apl_power_set_screen_events(on: i32) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.powerSetScreenEvents(on);
}

// ── SystemWindow ──────────────────────────────────────────────────

export fn apl_window_set_events(on: i32) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.windowSetEvents(on);
}

// ── SystemMedia ───────────────────────────────────────────────────

export fn apl_media_set_track(meta: ?*const core.TrackMeta) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.mediaSetTrack(meta);
}

export fn apl_media_set_playback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.mediaSetPlayback(state, position_ms, speed, volume, loop, shuffle);
}

export fn apl_media_set_window(win: i64) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.mediaSetWindow(win);
}

// ── 单实例 ────────────────────────────────────────────────────────

/// 单实例仲裁（进程级）：1=首实例（继续）；0=已有实例（调用方应退出）。
export fn apl_instance_acquire() callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.appInstanceAcquire();
}

/// 系统主题色（DE accent）：0=成功并写 r/g/b；<0=不可得/错误。
export fn apl_system_accent(r: ?*i32, g: ?*i32, b: ?*i32) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    const rgb = backend.systemAccent() orelse return core.ERR_BACKEND;
    if (r) |p| p.* = rgb[0];
    if (g) |p| p.* = rgb[1];
    if (b) |p| p.* = rgb[2];
    return core.OK;
}

/// 订阅系统主题色变更（0=关）。变更时回调 EVENT_SYSTEM_ACCENT（无载荷，
/// 收到后重读 apl_system_accent 并自行去重）。
export fn apl_system_accent_set_events(on: i32) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    return backend.systemAccentSetEvents(on != 0);
}

/// 系统提示（UTF-8）。用于“已有实例”等无需 UI 框架的场景。
export fn apl_notify(title: ?[*:0]const u8, body: ?[*:0]const u8) callconv(.c) i32 {
    if (!core.isInitialized()) return core.ERR_STATE;
    const t = std.mem.span(title orelse return core.ERR_BACKEND);
    const b = std.mem.span(body orelse "");
    return backend.notify(t, b);
}

// ── 测试 ──────────────────────────────────────────────────────────

test "abi version and lifecycle" {
    try std.testing.expectEqual(@as(i32, 1), apl_abi_version());
    try std.testing.expectEqual(core.OK, apl_shutdown()); // 未 init 幂等
    try std.testing.expectEqual(core.OK, apl_init());
    defer _ = apl_shutdown();
    // Linux 后端置位 Power 能力（P1）；其他目标为 stub（0）
    const caps = apl_capabilities();
    if (@import("builtin").os.tag == .linux) {
        try std.testing.expect(caps & core.CAP_POWER_INHIBIT != 0);
        try std.testing.expect(caps & core.CAP_POWER_SCREEN_STATE != 0);
    }
    // 窗口状态恒 OK（句柄注册）；媒体未接管返回 UNSUPPORTED（P2 前）
    try std.testing.expectEqual(core.OK, apl_media_set_window(0));
    // 未 init 返回 STATE
    _ = apl_shutdown();
    try std.testing.expectEqual(core.ERR_STATE, apl_power_set_sleep_inhibit(1));
}

test "callback registration via export" {
    try std.testing.expectEqual(core.OK, apl_set_event_callback(null, null));
}

// live：本机有会话总线时真调 ScreenSaver Inhibit/UnInhibit（P1 验收；
// 无总线/无 ScreenSaver 服务时跳过——后者由 ERR_BACKEND 语义覆盖）。
test "live: linux sleep inhibit" {
    if (@import("builtin").os.tag != .linux) return;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return;
    _ = apl_init();
    defer _ = apl_shutdown();
    const rc = apl_power_set_sleep_inhibit(1);
    if (rc == core.ERR_BACKEND) return; // 极简 WM 无 ScreenSaver：跳过
    try std.testing.expectEqual(core.OK, rc);
    try std.testing.expectEqual(core.OK, apl_power_set_sleep_inhibit(0));
}

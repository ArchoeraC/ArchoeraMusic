//! 后端选择：按编译目标平台启用对应实现（backend.zig 统一接口面）。
//!
//! 每个平台后端必须提供（P0 骨架阶段均为 stub，随 P1–P5 逐项落地）：
//!   caps() u32                       —— 能力位图（恒置位见 bridge §3.1）
//!   init() i32 / shutdown() i32
//!   powerSetSleepInhibit(on) i32
//!   powerSetScreenEvents(on) i32
//!   windowSetEvents(on) i32
//!   mediaSetTrack(?*const core.TrackMeta) i32
//!   mediaSetPlayback(state, pos_ms, speed, volume, loop, shuffle) i32
//!   mediaSetWindow(win: i64) i32

const std = @import("std");
const core = @import("core.zig");

const linux = @import("backend/backend_linux.zig");
const windows = @import("backend/backend_windows.zig");
const macos = @import("backend/backend_macos.zig");
const stub = @import("backend/backend_stub.zig");

const Active = switch (@import("builtin").os.tag) {
    .linux => linux,
    .windows => windows,
    .macos => macos,
    else => stub.Backend,
};

pub fn caps() u32 {
    return Active.caps();
}

pub fn init() i32 {
    return Active.init();
}

pub fn shutdown() i32 {
    return Active.shutdown();
}

pub fn powerSetSleepInhibit(on: i32) i32 {
    return Active.powerSetSleepInhibit(on);
}

pub fn powerSetScreenEvents(on: i32) i32 {
    return Active.powerSetScreenEvents(on);
}

pub fn windowSetEvents(on: i32) i32 {
    return Active.windowSetEvents(on);
}

pub fn mediaSetTrack(meta: ?*const core.TrackMeta) i32 {
    return Active.mediaSetTrack(meta);
}

pub fn mediaSetPlayback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) i32 {
    return Active.mediaSetPlayback(state, position_ms, speed, volume, loop, shuffle);
}

pub fn mediaSetWindow(win: i64) i32 {
    return Active.mediaSetWindow(win);
}

/// 单实例仲裁：1=首实例；0=已有实例（调用方退出）；<0=错误。
pub fn appInstanceAcquire() i32 {
    return Active.appInstanceAcquire();
}

/// 系统主题色（DE accent）→ ?[3]u8 RGB；不支持/不可得返回 null。
pub fn systemAccent() ?[3]u8 {
    return Active.systemAccent();
}

pub fn notify(title: []const u8, body: []const u8) i32 {
    return Active.notify(title, body);
}

// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows SMTC（SystemMediaTransportControls）——**薄转发层**。
//!
//! 真正的 SMTC 由 C++/WinRT 实现（`win_smtc.cpp`，对齐 Chromium
//! `components/system_media_controls/win/system_media_controls_win.cc`）：C++/WinRT
//! 标准委托投影注册 `ButtonPressed`，规避此前 Zig 手写 4 槽 COM 委托 + 自研
//! IMarshal 在真机上「`add_ButtonPressed` 成功但事件永不回调」的问题。
//!
//! 本文件只做两件事：
//!   1. 正向：把 `init/setTrack/setPlayback/deinit` 转发给 C++（`apl_smtc_win_*`）；
//!   2. 反向：导出 `apl_smtc_on_button`，把 C++ 回调的按钮事件经 `core.dispatch`
//!      转发给 Dart（保持「Flutter 桥接层 + Zig 转发」架构）。
//!
//! **编译期二选一**（`build_options.win_cpp`）：有 cppwinrt → 调用 C++ 符号；
//! 否则 → Zig 兜底（SMTC 静默禁用）。
//!
//! ⚠️ 历史坑：曾用「同名弱符号兜底（`@export` weak）+ `extern` 调用」——实测
//! **Zig 会把弱兜底内联**，导致 C++ 强符号永远不被调用（SMTC 永不初始化、
//! 控件消失）。故这里不再用弱符号，改编译期开关。

const std = @import("std");
const core = @import("../core.zig");
const win = @import("win_common.zig").c;
const use_cpp = @import("build_options").win_cpp;

// ── C++/WinRT 实现（win_smtc.cpp）或 Zig 兜底 ──────────────────────

const Cpp = if (use_cpp) struct {
    extern "c" fn apl_smtc_win_init(hwnd: ?*anyopaque) c_int;
    extern "c" fn apl_smtc_win_set_track(
        title: ?[*]const u8,
        title_len: i32,
        artist: ?[*]const u8,
        artist_len: i32,
        album: ?[*]const u8,
        album_len: i32,
        duration_ms: i64,
        art_url: ?[*]const u8,
        art_url_len: i32,
        art_bytes: ?[*]const u8,
        art_bytes_len: i32,
    ) void;
    extern "c" fn apl_smtc_win_set_playback(state: i32, position_ms: i64, speed: f64) void;
    extern "c" fn apl_smtc_win_deinit() void;
    extern "c" fn apl_smtc_win_debug_playback_status() c_int;
    extern "c" fn apl_smtc_win_debug_is_enabled() c_int;
    extern "c" fn apl_smtc_win_debug_button_registered() c_int;
    extern "c" fn apl_smtc_win_probe() void;
} else struct {
    fn apl_smtc_win_init(hwnd: ?*anyopaque) callconv(.c) c_int {
        _ = hwnd;
        return -1;
    }
    fn apl_smtc_win_set_track(
        title: ?[*]const u8,
        title_len: i32,
        artist: ?[*]const u8,
        artist_len: i32,
        album: ?[*]const u8,
        album_len: i32,
        duration_ms: i64,
        art_url: ?[*]const u8,
        art_url_len: i32,
        art_bytes: ?[*]const u8,
        art_bytes_len: i32,
    ) callconv(.c) void {
        _ = .{ title, title_len, artist, artist_len, album, album_len, duration_ms, art_url, art_url_len, art_bytes, art_bytes_len };
    }
    fn apl_smtc_win_set_playback(state: i32, position_ms: i64, speed: f64) callconv(.c) void {
        _ = .{ state, position_ms, speed };
    }
    fn apl_smtc_win_deinit() callconv(.c) void {}
    fn apl_smtc_win_debug_playback_status() callconv(.c) c_int {
        return -1;
    }
    fn apl_smtc_win_debug_is_enabled() callconv(.c) c_int {
        return -1;
    }
    fn apl_smtc_win_debug_button_registered() callconv(.c) c_int {
        return 0;
    }
    fn apl_smtc_win_probe() callconv(.c) void {}
};

// ── 反向：C++ 按钮回调 → Zig → Dart ────────────────────────────────

/// C++/WinRT `ButtonPressed` 回调（Windows.Media 按钮枚举值）→ 统一命令 → Dart。
/// Windows 枚举：Play=0 Pause=1 Stop=2 Record=3 FF=4 Rew=5 Next=6 Previous=7。
export fn apl_smtc_on_button(button: i32) callconv(.c) void {
    const cmd: i32 = switch (button) {
        0 => core.CMD_PLAY,
        1 => core.CMD_PAUSE,
        2 => core.CMD_STOP,
        6 => core.CMD_NEXT,
        7 => core.CMD_PREV,
        else => return,
    };
    core.dispatch(.{ .type = core.EVENT_MEDIA_COMMAND, .u = .{ .command = cmd } });
}

// ── 正向：Zig → C++ ───────────────────────────────────────────────

/// 加载探针：桥接初始化时调用一次，确认 DLL 已加载、C++ 代码在跑（写日志）。
pub fn probe() void {
    Cpp.apl_smtc_win_probe();
}

pub fn init(findWindow: *const fn () ?win.HWND) i32 {
    const hwnd = findWindow() orelse return core.ERR_BACKEND;
    if (Cpp.apl_smtc_win_init(hwnd) != 0) return core.ERR_BACKEND;
    return core.OK;
}

const StrArg = struct { ptr: ?[*]const u8 = null, len: i32 = 0 };

fn strArg(s: ?[]const u8) StrArg {
    if (s) |v| {
        if (v.len > 0) return .{ .ptr = v.ptr, .len = @intCast(v.len) };
    }
    return .{};
}

pub fn setTrack(
    title: ?[]const u8,
    artist: ?[]const u8,
    album: ?[]const u8,
    art_url: ?[]const u8,
    duration_ms: i64,
    art_bytes: ?[]const u8,
) void {
    const t = strArg(title);
    const a = strArg(artist);
    const al = strArg(album);
    const u = strArg(art_url);
    const b = strArg(art_bytes);
    Cpp.apl_smtc_win_set_track(
        t.ptr,
        t.len,
        a.ptr,
        a.len,
        al.ptr,
        al.len,
        duration_ms,
        u.ptr,
        u.len,
        b.ptr,
        b.len,
    );
}

pub fn setPlayback(state: i32, position_ms: i64) void {
    Cpp.apl_smtc_win_set_playback(state, position_ms, if (state == 1) 1.0 else 0.0);
}

pub fn deinit() void {
    Cpp.apl_smtc_win_deinit();
}

// ── 诊断（win_smoke 读回校验）─────────────────────────────────────

pub fn debugGetPlaybackStatus() i32 {
    return Cpp.apl_smtc_win_debug_playback_status();
}

pub fn debugGetIsEnabled() i32 {
    return Cpp.apl_smtc_win_debug_is_enabled();
}

pub fn debugIsButtonRegistered() bool {
    return Cpp.apl_smtc_win_debug_button_registered() != 0;
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 内核统一日志（与 C/C++/Rust/Dart 同一 `[HH:mm:ss LEVEL] msg` 契约）。
//!
//! 内核不直接落盘：宿主（C 壳）把 libarchoera_log 的 archoera_log_write 指针经
//! `zk_set_log_sink` 注入，本模块把消息格式化后回调；未注入时回退
//! `std.debug.print`（stderr）。无内存驻留（单行栈缓冲）。
//!
//! 级别数值对齐 archoera_log.h：0=DEBUG 1=INFO 2=WARN 3=ERROR 4=FATAL。

const std = @import("std");

/// 宿主日志函数指针（同 C `ArchoeraLogFn`）。
pub const Sink = *const fn (c_int, [*:0]const u8, [*:0]const u8) callconv(.c) void;

var sink_ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var min_level: std.atomic.Value(usize) = std.atomic.Value(usize).init(1); // INFO

/// 注入/注销 sink（fn_ptr=null 注销）；level 为最小级别。
pub fn setSink(fn_ptr: ?Sink, level: c_int) void {
    const lv: usize = if (level < 0) 0 else @intCast(@min(level, 4));
    min_level.store(lv, .release);
    sink_ptr.store(if (fn_ptr) |f| @intFromPtr(f) else 0, .release);
}

/// 写一条日志（格式化在栈缓冲内完成，超长截断）。
pub fn emit(level: c_int, tag: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
    if (level < 0) return;
    if (@as(usize, @intCast(level)) < min_level.load(.acquire)) return;

    const p = sink_ptr.load(.acquire);
    if (p == 0) {
        std.debug.print(fmt, args);
        if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') std.debug.print("\n", .{});
        return;
    }
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return;
    buf[msg.len] = 0;
    const sink: Sink = @ptrFromInt(p);
    sink(level, tag, @ptrCast(&buf));
}

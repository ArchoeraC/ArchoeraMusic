// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 轻量「恰好一次」初始化原语（线程安全）。
//!
//! 用于并发解码 worker 首次触达时才生成的全局只读表：无同步写 `undefined`
//! 全局属数据竞争（首个（半）初始化状态可被其它 worker 读到）。Zig 0.16 已无
//! `std.once`，故自备：双重检查 + 互斥，热路径命中即返回（acquire 读）。
//!
//! 纪律：只用于**只读派生表**（初始化后不再写）；不用于任何可变状态。
const std = @import("std");
const Io = std.Io;

pub const Once = struct {
    mutex: Io.Mutex = .init,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 至多执行一次 [f]；并发调用者阻塞至初始化完成后返回。
    pub fn call(self: *Once, comptime f: fn () void) void {
        if (self.done.load(.acquire)) return;
        const io = Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.done.load(.acquire)) return;
        f();
        self.done.store(true, .release);
    }
};

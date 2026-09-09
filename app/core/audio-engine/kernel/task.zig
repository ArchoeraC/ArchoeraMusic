// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Task 提交/完工层（进程内雏形；docs/engine-master-pool-design.md §6.1）
//!
//! 宿主最终形态 = `submit(Task)→Handle` + wait_event 推 `Event{handle, kind: done|error|fatal}`。
//! 本文件实现**进程内等价物**（用户定 2026-09-09：可测不接生产线）：
//!   - `Task`：调用方持有的完工槽——`outcome(done|error|fatal)` + `err` + 完工事件；
//!   - `spawnInto(rt, task)`：把用户函数体经 runtime.Job 投进池（完成即领）；
//!   - `wait(task)`：阻塞等完工（wait_event 推模式的进程内版）；
//!   - 错误/致命回传：体函数置 `task.err`（→error）或 `task.fatal()`（→fatal，§5.2
//!     FATAL 逃生舱：不可预知输入 → 会话级收尾）；默认无错 = done。
//!
//! 隔离：每个 task 私有状态；跨线程移交经完工事件 release/acquire（Event.set 为 release，
//! wait 返回后读 task 字段无竞争）。固定容量的 Task 表 / Handle / Master 簿记（§5.4）
//! 属 kernel_init 定容面，接线时并入。

const std = @import("std");
const runtime = @import("runtime.zig");
const kerr = @import("error.zig");

pub const Outcome = enum(u8) {
    pending,
    done,
    failed,
    fatal,
};

/// 用户任务体：在池 worker 内执行；完成后经 task 上报 error/fatal（或默认 done）
pub const TaskFn = *const fn (task: *Task) void;

pub const Task = struct {
    run: TaskFn,
    outcome: Outcome = .pending,
    err: ?kerr.Error = null,
    event: std.Io.Event = .unset,

    /// 体函数内调用：报可分类错误（→ error）
    pub fn fail(self: *Task, e: kerr.Error) void {
        self.err = e;
        self.outcome = .failed;
    }

    /// 体函数内调用：FATAL 逃生舱（§5.2 层1）——不可预知输入，会话级收尾
    pub fn fatal(self: *Task) void {
        self.outcome = .fatal;
    }

    pub fn isDone(self: *const Task) bool {
        return self.outcome != .pending;
    }
};

/// 公开执行体：跑任务体并做默认收尾（体可复用同一 Task：先清残留再跑）。
/// 供桥（bridge）与常驻内核 Host（khost）共用；**不发完工事件**（各自负责）。
pub fn runBody(task: *Task) void {
    if (task.outcome == .pending and task.err == null) {
        task.run(task);
    }
    // 默认：无 err、未显式 fatal → done
    if (task.outcome == .pending) {
        if (task.err != null) {
            task.outcome = .failed;
        } else {
            task.outcome = .done;
        }
    }
}

/// 执行体 + 发完工事件（release：完工字段先于事件可见）
pub fn runAndSignal(task: *Task) void {
    runBody(task);
    signal(task);
}

/// 只发完工事件（供 Host 等在清理后显式触发：清槽先行 → wait 返回即确定）
pub fn signal(task: *Task) void {
    std.Io.Event.set(&task.event, std.Io.Threaded.global_single_threaded.io());
}

/// 把任务投进池（非阻塞；OOM/队列满返回 false）。worker 完成即领（run-to-completion）。
pub fn spawnInto(rt: *runtime.Runtime, task: *Task) bool {
    return rt.submit(.{ .run = bridge, .ctx = task });
}

/// 阻塞等完工（wait_event 推模式的进程内等待形态）。
pub fn wait(task: *Task) void {
    std.Io.Event.waitUncancelable(&task.event, std.Io.Threaded.global_single_threaded.io());
}

/// 保证可用的带超时等待（供停机看门狗 / §5.1 next_check 等低频兜底；热路径不用）。
/// 事件在超时内被 set → true；超时 → false。
pub fn waitEventTimeout(event: *std.Io.Event, io: std.Io, timeout_ns: u64) bool {
    const dur = std.Io.Clock.Duration{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake, // Linux CLOCK_MONOTONIC（单调，不含挂起）
    };
    std.Io.Event.waitTimeout(event, io, .{ .duration = dur }) catch |e| switch (e) {
        error.Timeout => return false,
        error.Canceled => return false,
    };
    return true;
}

/// Task 带超时等完工；超时返回 false（调用方决定取消/继续等）
pub fn waitTimeout(task: *Task, timeout_ns: u64) bool {
    return waitEventTimeout(&task.event, std.Io.Threaded.global_single_threaded.io(), timeout_ns);
}

fn bridge(ctx: *anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(ctx));
    runAndSignal(task);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "task: 体函数完工（默认 done）→ wait 读到 done" {
    var rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 2 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const Ctx = struct {
        fn body(t: *Task) void {
            _ = t;
        }
    };
    var task = Task{ .run = Ctx.body };
    try testing.expect(spawnInto(rt, &task));
    wait(&task);
    try testing.expectEqual(Outcome.done, task.outcome);
}

test "task: 带超时等待被保证（set 前 → true；永未 set → false）" {
    // set 在超时前 → true
    var ev = std.Io.Event.unset;
    const io = std.Io.Threaded.global_single_threaded.io();
    const Setter = struct {
        fn setLater(e: *std.Io.Event) void {
            var i: usize = 0;
            while (i < 100_000) : (i += 1) {}
            std.Io.Event.set(e, std.Io.Threaded.global_single_threaded.io());
        }
    };
    var th = try std.Thread.spawn(.{ .allocator = std.heap.c_allocator }, Setter.setLater, .{&ev});
    try testing.expect(waitEventTimeout(&ev, io, 5 * std.time.ns_per_s));
    th.join();

    // 永未 set → 短超时返回 false（保证超时路径真实可用）
    var never = std.Io.Event.unset;
    try testing.expect(!waitEventTimeout(&never, io, 20 * std.time.ns_per_ms));
    // 清等待者残留（无等待者时无需 reset；此处 never 从未被 set，直接丢弃即可）
}

test "task: waitTimeout 完工任务返回 true" {
    var rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 1 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const Ctx = struct {
        fn body(t: *Task) void {
            _ = t;
        }
    };
    var task = Task{ .run = Ctx.body };
    try testing.expect(spawnInto(rt, &task));
    try testing.expect(waitTimeout(&task, 5 * std.time.ns_per_s));
    try testing.expectEqual(Outcome.done, task.outcome);
}

test "task: 体函数报 error / fatal → wait 读到对应 outcome" {
    var rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 2 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    const Ctx = struct {
        fn errBody(t: *Task) void {
            t.fail(error.Corrupt);
        }
        fn fatalBody(t: *Task) void {
            t.fatal();
        }
    };
    var t_err = Task{ .run = Ctx.errBody };
    var t_fatal = Task{ .run = Ctx.fatalBody };
    try testing.expect(spawnInto(rt, &t_err));
    try testing.expect(spawnInto(rt, &t_fatal));
    wait(&t_err);
    wait(&t_fatal);
    try testing.expectEqual(Outcome.failed, t_err.outcome);
    try testing.expect(t_err.err != null);
    try testing.expect(t_err.err.? == error.Corrupt);
    try testing.expectEqual(Outcome.fatal, t_fatal.outcome);
}


// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 常驻内核 Host（进程入口面；docs/engine-master-pool-design.md §3 宿主 → kernel_init/submit）
//!
//! 把 runtime（池）+ task（完工）收口为单一常驻内核对象：
//!   - `init(cfg)`：bootstrap（线程按 cfg.eager/懒就绪，§3 启动预算）；
//!   - `submit(&Task) → Handle`：定容任务槽（cap = cfg.cap_tasks，§5.4 满即拒 =
//!     `InstanceLimit`，返回 null）；worker 完成即领并自动释放槽（完工事件先发、槽后清）；
//!   - `wait(task)`：wait_event 推的进程内形态（完工事件，无轮询）；
//!   - `shutdown()` / `deinit()`：排空 + join + 释放。
//!
//! 关键路径无堆分配：槽与 NodeCtx 均 `kernel_init` 时定容预分配（§5.4 no-alloc）。
//! 仍不接 C 壳生产线。

const std = @import("std");
const runtime = @import("runtime.zig");
const task = @import("task.zig");

pub const Cfg = struct {
    min_workers: u16 = 1,
    max_workers: u16 = 64,
    /// 任务槽上限（并发实例上限 S；满即拒 InstanceLimit，§5.4）
    cap_tasks: u16 = 128,
    stack_size: usize = 16 * 1024 * 1024,

    pub fn rtCfg(self: Cfg) runtime.Cfg {
        return .{
            .min_workers = self.min_workers,
            .max_workers = self.max_workers,
            .stack_size = self.stack_size,
        };
    }
};

pub const Handle = u32;

const NodeCtx = struct {
    host: *Host,
    idx: usize,

    fn run(ctx: *anyopaque) void {
        const nc: *NodeCtx = @ptrCast(@alignCast(ctx));
        const host = nc.host;
        const io = std.Io.Threaded.global_single_threaded.io();
        const t = host.entries[nc.idx].?;
        task.runBody(t); // 体函数 + 默认收尾
        // 先清槽、后发事件：wait 返回时槽必已空（active 确定性）
        host.mutex.lockUncancelable(io);
        host.entries[nc.idx] = null;
        host.mutex.unlock(io);
        task.signal(t);
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    cap: usize,
    entries: []?*task.Task = &.{},
    nodes: []NodeCtx = &.{},
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, cfg: Cfg) !*Host {
        const h = try allocator.create(Host);
        errdefer allocator.destroy(h);
        h.* = .{ .allocator = allocator, .rt = undefined, .cap = cfg.cap_tasks };
        h.rt = try runtime.Runtime.init(allocator, cfg.rtCfg());
        errdefer {
            h.rt.shutdown();
            h.rt.deinit();
        }
        h.entries = try allocator.alloc(?*task.Task, cfg.cap_tasks);
        errdefer allocator.free(h.entries);
        @memset(h.entries, null);
        h.nodes = try allocator.alloc(NodeCtx, cfg.cap_tasks);
        errdefer allocator.free(h.nodes);
        for (h.nodes, 0..) |*nc, i| {
            nc.* = .{ .host = h, .idx = i };
        }
        return h;
    }

    /// 提交任务；满 → null（InstanceLimit，§5.4 满即拒，不扩容）
    pub fn submit(self: *Host, t: *task.Task) ?Handle {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        var slot: ?usize = null;
        for (self.entries, 0..) |e, i| {
            if (e == null) {
                slot = i;
                break;
            }
        }
        if (slot) |i| self.entries[i] = t;
        self.mutex.unlock(io);
        const i = slot orelse return null;

        if (!self.rt.submit(.{ .run = NodeCtx.run, .ctx = &self.nodes[i] })) {
            // 停机竞态入队失败：归还槽
            self.mutex.lockUncancelable(io);
            self.entries[i] = null;
            self.mutex.unlock(io);
            return null;
        }
        return @intCast(i);
    }

    /// 已占用槽数（active 任务）
    pub fn active(self: *Host) usize {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        var n: usize = 0;
        for (self.entries) |e| {
            if (e != null) n += 1;
        }
        self.mutex.unlock(io);
        return n;
    }

    pub fn shutdown(self: *Host) void {
        self.rt.shutdown();
    }

    pub fn deinit(self: *Host) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.nodes);
        self.rt.deinit();
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const Holder = struct {
    task: task.Task,
    counter: *std.atomic.Value(u32),

    fn bump(t: *task.Task) void {
        const hd: *Holder = @fieldParentPtr("task", t);
        _ = hd.counter.fetchAdd(1, .monotonic);
    }
};

test "khost: cap 满即拒（InstanceLimit），完工自动释放槽后可再提交" {
    const h = try Host.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4, .cap_tasks = 4 });
    defer {
        h.shutdown();
        h.deinit();
    }
    var counter = std.atomic.Value(u32).init(0);
    var holders: [4]Holder = undefined;
    for (&holders) |*x| x.* = .{ .task = .{ .run = Holder.bump }, .counter = &counter };

    var ok: usize = 0;
    for (&holders) |*x| {
        if (h.submit(&x.task) != null) ok += 1;
    }
    try testing.expectEqual(@as(usize, 4), ok);
    try testing.expect(h.active() <= 4);

    // 第 5 个 → InstanceLimit（null）
    var extra = Holder{ .task = .{ .run = Holder.bump }, .counter = &counter };
    try testing.expect(h.submit(&extra.task) == null);

    for (&holders) |*x| task.wait(&x.task);
    try testing.expect(h.submit(&extra.task) != null); // 槽已自动释放
    task.wait(&extra.task);
    try testing.expectEqual(@as(u32, @intCast(ok + 1)), counter.load(.acquire));
}

test "khost: 128 任务（cap 128）全部排空；active 回落 0" {
    const h = try Host.init(std.heap.c_allocator, .{ .min_workers = 0, .max_workers = 8, .cap_tasks = 128 });
    defer {
        h.shutdown();
        h.deinit();
    }
    var counter = std.atomic.Value(u32).init(0);
    var holders: [128]Holder = undefined;
    for (&holders) |*x| x.* = .{ .task = .{ .run = Holder.bump }, .counter = &counter };

    var ok: usize = 0;
    for (&holders) |*x| {
        if (h.submit(&x.task) != null) ok += 1;
    }
    try testing.expectEqual(@as(usize, 128), ok);
    for (&holders) |*x| task.wait(&x.task);
    try testing.expectEqual(@as(usize, 0), h.active());
    try testing.expectEqual(@as(u32, 128), counter.load(.acquire));
}

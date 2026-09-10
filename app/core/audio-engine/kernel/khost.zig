// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

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
    /// 流式会话并发上限（§6.3 max_streams 硬计数）。**与 cap_tasks 分开记账**：流各持一个
    /// session，不经任务槽复用（worker 亲和/ring 直推属 C 壳接线期，未在本层实现）。
    max_streams: u16 = 8,
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
    cfg: Cfg,
    rt: *runtime.Runtime,
    cap: usize,
    entries: []?*task.Task = &.{},
    nodes: []NodeCtx = &.{},
    mutex: std.Io.Mutex = .init,
    /// 当前已开的流式会话数（§6.3 max_streams 硬计数；Host.mutex 保护，独立于任务槽）
    stream_count: usize = 0,
    /// 是否已请求停机（read/seek 据此优雅拒绝，避免访问已停机的 rt）
    stopping: std.atomic.Value(bool),
    /// 停机时仍有未关闭的流 → 延迟释放，待最后一个 streamClose 收尾
    destroy_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: Cfg) !*Host {
        const h = try allocator.create(Host);
        errdefer allocator.destroy(h);
        h.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .rt = undefined,
            .cap = cfg.cap_tasks,
            .stopping = std.atomic.Value(bool).init(false),
        };
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

    /// §6.3 max_streams 硬计数（F9）：尝试登记一个流式会话。达到上限 → false（拒绝，
    /// 语义 = InstanceLimit）；成功 → stream_count+1 并返回 true。与 cap_tasks 槽
    /// **分开记账**——流各持一个 session，不占/不复用任务槽。Host.mutex 保护。
    pub fn streamOpen(self: *Host) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        const ok = self.stream_count < self.cfg.max_streams;
        if (ok) self.stream_count += 1;
        self.mutex.unlock(io);
        return ok;
    }

    /// §6.3 流式会话关闭记账：stream_count-1。必须在对应 `streamOpen` 成功后调用一次。
    pub fn streamClose(self: *Host) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        std.debug.assert(self.stream_count > 0);
        self.stream_count -= 1;
        const reap = self.destroy_pending and self.stream_count == 0;
        self.mutex.unlock(io);
        if (reap) self.destroyNow();
    }

    pub fn isStopping(self: *Host) bool {
        return self.stopping.load(.acquire);
    }

    pub fn shutdown(self: *Host) void {
        // 先置停机位：并发 read/seek 观察到后返回 io_error，不再触碰 rt。
        self.stopping.store(true, .release);
        self.rt.shutdown();
    }

    pub fn deinit(self: *Host) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        if (self.stream_count > 0) {
            // 仍有流未关：延迟到最后一个 streamClose 释放（否则 host/rt 悬垂 → 崩溃）
            self.destroy_pending = true;
            self.mutex.unlock(io);
            return;
        }
        self.mutex.unlock(io);
        self.destroyNow();
    }

    fn destroyNow(self: *Host) void {
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

/// 阻塞到 `stop` 才完工的任务体：完工前槽必不释放 → cap/释放的时序断言与机器速度解耦。
const BlockingHolder = struct {
    task: task.Task,
    stop: *std.atomic.Value(bool),
    counter: *std.atomic.Value(u32),

    fn blocked(t: *task.Task) void {
        const bh: *BlockingHolder = @fieldParentPtr("task", t);
        while (!bh.stop.load(.acquire)) std.Thread.yield() catch {};
        _ = bh.counter.fetchAdd(1, .monotonic);
    }
};

test "khost: cap 满即拒（InstanceLimit），完工自动释放槽后可再提交" {
    const h = try Host.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4, .cap_tasks = 4 });
    var gate = std.atomic.Value(bool).init(false);
    var counter = std.atomic.Value(u32).init(0);
    var holders: [4]BlockingHolder = undefined;
    for (&holders) |*x| x.* = .{ .task = .{ .run = BlockingHolder.blocked }, .stop = &gate, .counter = &counter };
    defer {
        gate.store(true, .release); // 无论走到哪先放行（防阻塞任务把 wait/shutdown 卡死）
        h.shutdown();
        h.deinit();
    }

    var ok: usize = 0;
    for (&holders) |*x| {
        if (h.submit(&x.task) != null) ok += 1;
    }
    try testing.expectEqual(@as(usize, 4), ok);
    try testing.expect(h.active() <= 4);

    // 第 5 个 → InstanceLimit（null）。4 个任务全阻塞、绝无槽提前释放 → 断言与时序无关。
    var extra = BlockingHolder{ .task = .{ .run = BlockingHolder.blocked }, .stop = &gate, .counter = &counter };
    try testing.expect(h.submit(&extra.task) == null);

    // 放行 → 4 槽自动释放 → 可再提交（cap 满即拒面与完工释放面都验证到）
    gate.store(true, .release);
    for (&holders) |*x| task.wait(&x.task);
    try testing.expectEqual(@as(usize, 0), h.active());
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

test "khost: F9 max_streams 硬计数——超限拒开（streamOpen false），关闭后恢复" {
    const h = try Host.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 2, .cap_tasks = 8, .max_streams = 2 });
    defer {
        h.shutdown();
        h.deinit();
    }

    try testing.expectEqual(@as(usize, 0), h.stream_count);
    // 上限 2：两个流成功，第三个被拒
    try testing.expect(h.streamOpen());
    try testing.expect(h.streamOpen());
    try testing.expect(!h.streamOpen());
    try testing.expectEqual(@as(usize, 2), h.stream_count);

    // 关一个 → 可再开一个（容量恢复）；流计数与任务槽互不干扰
    h.streamClose();
    try testing.expect(h.streamOpen());
    try testing.expectEqual(@as(usize, 2), h.stream_count);
    h.streamClose();
    h.streamClose();
    try testing.expectEqual(@as(usize, 0), h.stream_count);
    // 流记账不占任务槽：cap_tasks=8 的任务仍可正常提交（active 由 entries 独立计数）
    var counter = std.atomic.Value(u32).init(0);
    var holder = Holder{ .task = .{ .run = Holder.bump }, .counter = &counter };
    try testing.expect(h.submit(&holder.task) != null);
    task.wait(&holder.task);
    try testing.expectEqual(@as(u32, 1), counter.load(.acquire));
}

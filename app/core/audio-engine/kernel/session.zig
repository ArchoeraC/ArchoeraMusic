// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 流式会话能力（docs/engine-master-pool-design.md §6.3 的池内内部形态，不接 C 壳）
//!
//! 长流（播放/长 decode）＝跨多次"拉块步骤"共享**同一解码器实例**的会话：
//!   - `open(path)`：先分配会话壳；`start(rt)` 在池 worker 上做 probe+open（一次），
//!     `Decoder` 实例持有于会话；
//!   - `read(rt, buf, max_frames)`：一次"拉块步骤"——worker 逐块解到调用方缓冲，
//!     完工事件后调用方读 buf；`seekMs` 同理。步骤**串行 await**（一次一块），
//!     因此解码器实例绝不并发触碰（实例私有，§2.1）；
//!   - `close`：归还实例（释放 ctx）。
//!
//! 与 §6.3 差异（如实注明）：本形态为**分块串行**长流——正确性/实例隔离已成立；
//! worker 亲和（1 流 pinned 1 worker）与 ring 直推属 C 壳接线面，接入时叠加即可。
//!
//! 容错：任一步 open/read/seek error → 会话 `failed`（§5.2：error 收尾，不 panic）；
//! FATAL 逃生舱：会话体不可预知情形走 `fatal()`。状态/结果经 task 完工事件发布。

const std = @import("std");
const runtime = @import("runtime.zig");
const task = @import("task.zig");
const decoder = @import("decoder.zig");
const kio = @import("io.zig");
const kerr = @import("error.zig");
const streambuf = @import("streambuf.zig");
const probe = @import("probe.zig");

pub const SessState = enum(u8) {
    new, // 已 open 壳，未 start
    playing, // 实例已建，可 read/seek
    failed, // 某步 error（§5.2：会话级故障）
    fatal, // FATAL 逃生舱（不可预知输入）
    closed, // 实例已释放
};

/// 会话解码源形态（与 `decoder.open/openMem/openReader` 对应）。
pub const Source = union(enum) {
    path: []const u8,
    mem: []const u8,
    cb: kio.Reader.Callback,
};

/// 回调源上下文的析构（会话销毁时调用；通常释放 C 回调适配器）。
pub const CallbackOwner = struct {
    ctx: *anyopaque,
    destroy: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
};

pub const Session = struct {
    state: SessState = .new,
    allocator: std.mem.Allocator,
    /// 解码源形态（path / 内存切片 / 宿主回调流）；start 前须有效。
    source: Source,
    /// 回调源 peek 缓冲（本会话持有；非回调源为空）
    cb_buffer: []u8 = &.{},
    /// 回调源上下文析构（可空）
    cb_owner: ?CallbackOwner = null,
    dec: ?decoder.Decoder = null,
    info: decoder.Info = undefined,

    /// AS2：专属 worker 槽（pinned 1:1；null = 全局队列模式）。释放见 releasePin/close。
    pinned_id: ?usize = null,
    /// 会话运行所在的 runtime（pinned close 步骤内释放专属 worker 用；start 时记录）。
    rt: ?*runtime.Runtime = null,
    /// AS4：格式提示（C ABI ZkFormatHint 数值；0=auto → 常规 probe）。
    /// start 前设置；prepareStart 据此免 probe 直分派（失败回退 probe）。
    format_hint: u32 = 0,
    /// AS5：会话级取消请求（原子；read 步首观察到 → failed(error.Aborted)，不抢占运行中的块）。
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 当前步的完工槽（open/read/seek/close 复用同一会话级事件）
    step: task.Task = .{ .run = noopBody },

    /// 步骤参数（由调用方在触发前写入；worker 读；一次一步，串行）
    req_frames: usize = 0,
    req_ms: i64 = 0,
    out: []u8 = &.{}, // read 目标缓冲（调用方所有，须存活到 wait 返回）
    got_frames: usize = 0,

    fn noopBody(_: *task.Task) void {}

    /// 分配会话壳（path 必须调用方持有到 start 完成）
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !*Session {
        const s = try allocator.create(Session);
        s.* = .{ .allocator = allocator, .source = .{ .path = path } };
        return s;
    }

    /// 内存源会话（data 所有权归调用方，须覆盖会话生命周期）。
    pub fn createMem(allocator: std.mem.Allocator, data: []const u8) !*Session {
        const s = try allocator.create(Session);
        s.* = .{ .allocator = allocator, .source = .{ .mem = data } };
        return s;
    }

    /// 宿主回调流会话（peek 缓冲本会话分配并释放；`owner` 回调上下文析构可空）。
    /// N4：缓冲大小取 `streambuf.peek()`（默认 16 KiB），并向进程预算记账；
    /// 超预算 → `error.OutOfMemory`（调用方拒绝打开，不静默超配）。
    pub fn createCallback(allocator: std.mem.Allocator, cb: kio.Reader.Callback, owner: ?CallbackOwner) !*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        const peek = streambuf.peek();
        try streambuf.acquire(peek);
        const buf = allocator.alloc(u8, peek) catch |e| {
            streambuf.release(peek);
            return e;
        };
        s.* = .{ .allocator = allocator, .source = .{ .cb = cb }, .cb_buffer = buf, .cb_owner = owner };
        return s;
    }

    pub fn deinit(self: *Session) void {
        std.debug.assert(self.state == .closed);
        self.destroy();
    }

    /// 释放会话壳与自有缓冲（不要求 `state==closed`；用于 start 失败清理）。
    pub fn destroy(self: *Session) void {
        if (self.cb_owner) |o| o.destroy(o.ctx, self.allocator);
        if (self.cb_buffer.len > 0) {
            streambuf.release(self.cb_buffer.len); // N4：归还预算记账（与 createCallback 成对）
            self.allocator.free(self.cb_buffer);
        }
        self.allocator.destroy(self);
    }

    fn resetStep(self: *Session) void {
        // 逐字段复位，**不整struct覆写**：`cancel()` 可从任意线程原子写
        // `step.cancel_requested`，整struct赋值会与之竞争并可能清掉取消请求（A3）。
        self.step.run = noopBody;
        self.step.outcome = .pending;
        self.step.err = null;
        self.step.event = .unset;
        // 保留 cancel_requested（会话级取消由 cancel_flag + 本字段共同承载）。
    }

    /// 在池 worker 上建实例（probe+open，一次）
    pub fn start(self: *Session, rt: *runtime.Runtime) bool {
        std.debug.assert(self.state == .new);
        self.rt = rt;
        self.state = .playing;
        self.prepareStart();
        return self.dispatch(rt);
    }

    /// AS2：pinned 启动——先预留一个专属 worker（1 流 : 1 pinned worker，§6.3），
    /// 该会话的所有步骤只在此 worker 上串行执行（不进全局队列、不被回收）。无空闲
    /// worker 时返回 false（调用方回退 `start`/全局队列；默认路径不受影响）。
    pub fn startPinned(self: *Session, rt: *runtime.Runtime) bool {
        std.debug.assert(self.state == .new);
        const id = rt.acquirePinned() orelse return false;
        self.pinned_id = id;
        self.rt = rt;
        self.state = .playing;
        self.prepareStart();
        if (!self.dispatch(rt)) {
            rt.releasePinned(id);
            self.pinned_id = null;
            self.state = .new;
            return false;
        }
        return true;
    }

    /// 会话是否绑定专属 worker（AS2）。
    pub fn isPinned(self: *const Session) bool {
        return self.pinned_id != null;
    }

    /// AS5：请求取消本会话后续步骤（任意线程可调用）。`read` 在步首观察到后把
    /// 会话置 failed 并以 `error.Aborted` 收尾；不抢占正在执行的块（run-to-completion）。
    pub fn cancel(self: *Session) void {
        self.cancel_flag.store(true, .release);
        self.step.cancel();
    }

    /// AS5：是否已请求取消。
    pub fn isCancelled(self: *const Session) bool {
        return self.cancel_flag.load(.acquire);
    }

    /// 显式释放专属 worker（幂等；供停机等非 close-step 路径调用）。
    pub fn releasePin(self: *Session, rt: *runtime.Runtime) void {
        if (self.pinned_id) |id| {
            rt.releasePinned(id);
            self.pinned_id = null;
        }
    }

    fn prepareStart(self: *Session) void {
        self.resetStep();
        self.step.run = struct {
            fn f(t: *task.Task) void {
                const sess: *Session = @fieldParentPtr("step", t);
                var info: decoder.Info = undefined;
                // AS4：仅 hint != 0 时走免 probe 直分派（失败内部回退 probe）。
                const hint: ?probe.Format = if (sess.format_hint != 0)
                    probe.hintToFormat(sess.format_hint)
                else
                    null;
                const opened: kerr.Error!decoder.Decoder = switch (sess.source) {
                    .path => |p| if (hint) |hf|
                        decoder.openHinted(sess.allocator, p, hf, &info)
                    else
                        decoder.open(sess.allocator, p, &info),
                    .mem => |d| if (hint) |hf|
                        decoder.openHintedMem(sess.allocator, d, hf, &info)
                    else
                        decoder.openMem(sess.allocator, d, &info),
                    .cb => |cb| blk: {
                        var reader = kio.Reader.openCallback(cb, sess.cb_buffer);
                        if (hint) |hf| break :blk decoder.openHintedReader(sess.allocator, &reader, hf, &info);
                        break :blk decoder.openReader(sess.allocator, &reader, &info);
                    },
                };
                sess.dec = opened catch |e| {
                    sess.state = .failed;
                    t.fail(e);
                    return;
                };
                sess.info = info;
                sess.state = .playing;
            }
        }.f;
    }

    /// 步骤派发：pinned 会话定向到专属 worker；否则（或 pinned 槽失效）走全局队列。
    fn dispatch(self: *Session, rt: *runtime.Runtime) bool {
        if (self.pinned_id) |id| {
            if (rt.submitPinned(id, task.jobFor(&self.step))) return true;
            self.pinned_id = null; // 槽失效 → 退化全局（会话仍可继续，仅失去亲和）
        }
        return task.spawnInto(rt, &self.step);
    }

    /// 一次拉块：解到 out（字节缓冲）至多 req_frames 帧；wait 后读 got_frames
    pub fn read(self: *Session, rt: *runtime.Runtime, out: []u8, max_frames: usize) bool {
        std.debug.assert(self.state == .playing);
        self.out = out;
        self.req_frames = max_frames;
        self.resetStep();
        self.step.run = struct {
            fn f(t: *task.Task) void {
                const sess: *Session = @fieldParentPtr("step", t);
                // AS5：步首 fail-fast——已取消（会话级或本步 Task）→ Aborted 收尾。
                if (sess.isCancelled() or t.isCancelled()) {
                    sess.state = .failed;
                    t.fail(error.Aborted);
                    return;
                }
                var ch: u8 = 0;
                const n = (&sess.dec.?).read(sess.out, sess.req_frames, &ch) catch |e| {
                    sess.state = .failed;
                    t.fail(e);
                    return;
                };
                sess.got_frames = n;
                sess.req_frames = 0;
            }
        }.f;
        return self.dispatch(rt);
    }

    /// 跳到毫秒位置
    pub fn seekMs(self: *Session, rt: *runtime.Runtime, ms: i64) bool {
        std.debug.assert(self.state == .playing);
        self.req_ms = ms;
        self.resetStep();
        self.step.run = struct {
            fn f(t: *task.Task) void {
                const sess: *Session = @fieldParentPtr("step", t);
                (&sess.dec.?).seekMs(sess.req_ms) catch |e| {
                    sess.state = .failed;
                    t.fail(e);
                    return;
                };
            }
        }.f;
        return self.dispatch(rt);
    }

    /// 关闭实例（释放 ctx/文件句柄）
    pub fn close(self: *Session, rt: *runtime.Runtime) bool {
        std.debug.assert(self.state == .playing or self.state == .new);
        self.resetStep();
        self.step.run = struct {
            fn f(t: *task.Task) void {
                const sess: *Session = @fieldParentPtr("step", t);
                if (sess.dec) |*d| d.deinit();
                sess.dec = null;
                sess.state = .closed;
                // AS2：会话收尾即释放专属 worker（回全局队列，可被回收复用）
                if (sess.rt) |r| sess.releasePin(r);
            }
        }.f;
        return self.dispatch(rt);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 造黄金 WAV（8kHz mono，16 帧 i16 0..15）
fn writeGold(tmp: *testing.TmpDir, io: std.Io, name: []const u8) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "RIFF\x44\x00\x00\x00WAVE");
    try bytes.appendSlice(testing.allocator, "fmt ");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x40, 0x1F, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00 });
    try bytes.appendSlice(testing.allocator, "data");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x20, 0x00, 0x00, 0x00 });
    var samples: [32]u8 = undefined;
    for (0..16) |i| std.mem.writeInt(i16, samples[2 * i ..][0..2], @as(i16, @intCast(i)), .little);
    try bytes.appendSlice(testing.allocator, &samples);
    const f = try tmp.dir.createFile(io, name, .{});
    try std.Io.File.writeStreamingAll(f, io, bytes.items);
    std.Io.File.close(f, io);
    return std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
}

test "session: 分块长流解码 == 一次性解码（帧数/顺序一致，逐块 await）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try writeGold(&tmp, io, "g.wav");
    defer testing.allocator.free(path);

    // 一次性基线：16 帧
    var info: decoder.Info = undefined;
    var one = try decoder.open(std.heap.c_allocator, path, &info);
    var ref: [16]f32 = undefined;
    var ref_frames: usize = 0;
    {
        var raw: [64]u8 = undefined;
        var ch: u8 = 0;
        ref_frames = try one.read(&raw, 16, &ch);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            ref[i] = @as(f32, @floatFromInt(std.mem.readInt(i16, raw[i * 2 ..][0..2], .little)));
        }
    }
    one.deinit();
    try testing.expectEqual(@as(usize, 16), ref_frames);

    const rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 2 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    const sess = try Session.create(std.heap.c_allocator, path);
    defer {
        std.debug.assert(sess.state == .closed);
        sess.deinit();
    }
    try testing.expect(sess.start(rt));
    task.wait(&sess.step);
    try testing.expectEqual(SessState.playing, sess.state);
    try testing.expectEqual(@as(u32, 8000), sess.info.sample_rate);

    // 分块拉取：3 块（6/6/4 帧）顺序拼接 == 0..15
    var buf: [64]u8 = undefined;
    const chunk_sizes = [_]usize{ 6, 6, 4 };
    var out_frames: usize = 0;
    for (chunk_sizes) |sz| {
        try testing.expect(sess.read(rt, buf[0 .. sz * 2], sz));
        task.wait(&sess.step);
        try testing.expectEqual(SessState.playing, sess.state);
        const n = sess.got_frames;
        for (0..n) |k| {
            const v = @as(f32, @floatFromInt(std.mem.readInt(i16, buf[k * 2 ..][0..2], .little)));
            try testing.expectApproxEqAbs(ref[out_frames + k], v, 0.0);
        }
        out_frames += n;
    }
    try testing.expectEqual(@as(usize, 16), out_frames);

    try testing.expect(sess.seekMs(rt, 0));
    task.wait(&sess.step);
    try testing.expect(sess.read(rt, buf[0..16], 8));
    task.wait(&sess.step);
    try testing.expectEqual(@as(usize, 8), sess.got_frames);

    try testing.expect(sess.close(rt));
    task.wait(&sess.step);
    try testing.expectEqual(SessState.closed, sess.state);
}

test "session: AS2 pinned 启动——专属 worker 串行分块解码 == 一次性；close 归还" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try writeGold(&tmp, io, "gp.wav");
    defer testing.allocator.free(path);

    const rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    const sess = try Session.create(std.heap.c_allocator, path);
    defer {
        std.debug.assert(sess.state == .closed);
        sess.deinit();
    }
    try testing.expect(sess.startPinned(rt));
    try testing.expect(sess.isPinned());
    task.wait(&sess.step);
    try testing.expectEqual(SessState.playing, sess.state);

    // 分块串行（全程同一 pinned worker）：6+6+4 == 16 帧
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    for ([_]usize{ 6, 6, 4 }) |sz| {
        try testing.expect(sess.read(rt, buf[0 .. sz * 2], sz));
        task.wait(&sess.step);
        try testing.expectEqual(SessState.playing, sess.state);
        total += sess.got_frames;
    }
    try testing.expectEqual(@as(usize, 16), total);

    try testing.expect(sess.seekMs(rt, 0));
    task.wait(&sess.step);
    try testing.expect(sess.read(rt, buf[0..16], 8));
    task.wait(&sess.step);
    try testing.expectEqual(@as(usize, 8), sess.got_frames);

    // close 在 pinned worker 上收尾并归还专属 worker
    try testing.expect(sess.close(rt));
    task.wait(&sess.step);
    try testing.expectEqual(SessState.closed, sess.state);
    try testing.expect(!sess.isPinned());
}

test "session: 不可解码文件 start → failed（error 收尾，不 panic）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(io, "bad.bin", .{});
    try std.Io.File.writeStreamingAll(f, io, "not-an-audio-file");
    std.Io.File.close(f, io);
    const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "bad.bin" });
    defer testing.allocator.free(path);

    const rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 1 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const sess = try Session.create(std.heap.c_allocator, path);
    defer {
        // failed 态未建实例：直接 deinit（close 无需跑）
        sess.allocator.destroy(sess);
    }
    try testing.expect(sess.start(rt));
    task.wait(&sess.step);
    try testing.expectEqual(SessState.failed, sess.state);
    try testing.expectEqual(task.Outcome.failed, sess.step.outcome);
}

test "AS5 session: cancel 后 read 步首观察到 → failed(error.Aborted；不抢占运行中块)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try writeGold(&tmp, io, "gc.wav");
    defer testing.allocator.free(path);

    const rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 1 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const sess = try Session.create(std.heap.c_allocator, path);
    defer {
        // failed 态：手动释放实例与会话壳
        if (sess.dec) |*d| d.deinit();
        sess.destroy();
    }
    try testing.expect(sess.start(rt));
    task.wait(&sess.step);
    try testing.expectEqual(SessState.playing, sess.state);

    sess.cancel();
    try testing.expect(sess.isCancelled());
    var buf: [64]u8 = undefined;
    try testing.expect(sess.read(rt, buf[0..16], 8));
    task.wait(&sess.step);
    try testing.expectEqual(SessState.failed, sess.state);
    try testing.expectEqual(task.Outcome.failed, sess.step.outcome);
    try testing.expectEqual(error.Aborted, sess.step.err.?);
}

test "AS4 session: format_hint 路由——正确提示免 probe；错误提示回退 probe；均 start 成功" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try writeGold(&tmp, io, "gh.wav");
    defer testing.allocator.free(path);

    const rt = try runtime.Runtime.init(std.heap.c_allocator, .{ .min_workers = 2 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    // 正确提示（wav=1）
    {
        const sess = try Session.create(std.heap.c_allocator, path);
        defer {
            std.debug.assert(sess.state == .closed);
            sess.deinit();
        }
        sess.format_hint = 1;
        try testing.expect(sess.start(rt));
        task.wait(&sess.step);
        try testing.expectEqual(SessState.playing, sess.state);
        var buf: [64]u8 = undefined;
        try testing.expect(sess.read(rt, buf[0..16], 8));
        task.wait(&sess.step);
        try testing.expectEqual(@as(usize, 8), sess.got_frames);
        try testing.expect(sess.close(rt));
        task.wait(&sess.step);
    }

    // 错误提示（flac=2）：分派失败 → 回退 probe → 仍能 start/read
    {
        const sess = try Session.create(std.heap.c_allocator, path);
        defer {
            std.debug.assert(sess.state == .closed);
            sess.deinit();
        }
        sess.format_hint = 2;
        try testing.expect(sess.start(rt));
        task.wait(&sess.step);
        try testing.expectEqual(SessState.playing, sess.state);
        var buf: [64]u8 = undefined;
        try testing.expect(sess.read(rt, buf[0..16], 8));
        task.wait(&sess.step);
        try testing.expectEqual(@as(usize, 8), sess.got_frames);
        try testing.expect(sess.close(rt));
        task.wait(&sess.step);
    }
}

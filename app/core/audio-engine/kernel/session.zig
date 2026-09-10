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
const kerr = @import("error.zig");

pub const SessState = enum(u8) {
    new, // 已 open 壳，未 start
    playing, // 实例已建，可 read/seek
    failed, // 某步 error（§5.2：会话级故障）
    fatal, // FATAL 逃生舱（不可预知输入）
    closed, // 实例已释放
};

pub const Session = struct {
    state: SessState = .new,
    allocator: std.mem.Allocator,
    path: []const u8, // start 前须有效；open 后实例自建 Reader
    dec: ?decoder.Decoder = null,
    info: decoder.Info = undefined,

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
        s.* = .{ .allocator = allocator, .path = path };
        return s;
    }

    pub fn deinit(self: *Session) void {
        std.debug.assert(self.state == .closed);
        self.allocator.destroy(self);
    }

    fn resetStep(self: *Session) void {
        self.step = .{ .run = noopBody };
        self.step.event = .unset;
        self.step.outcome = .pending;
    }

    /// 在池 worker 上建实例（probe+open，一次）
    pub fn start(self: *Session, rt: *runtime.Runtime) bool {
        std.debug.assert(self.state == .new);
        self.state = .playing;
        self.resetStep();
        self.step.run = struct {
            fn f(t: *task.Task) void {
                const sess: *Session = @fieldParentPtr("step", t);
                var info: decoder.Info = undefined;
                sess.dec = decoder.open(sess.allocator, sess.path, &info) catch |e| {
                    sess.state = .failed;
                    t.fail(e);
                    return;
                };
                sess.info = info;
                sess.state = .playing;
            }
        }.f;
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
        return task.spawnInto(rt, &self.step);
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
        return task.spawnInto(rt, &self.step);
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
            }
        }.f;
        return task.spawnInto(rt, &self.step);
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

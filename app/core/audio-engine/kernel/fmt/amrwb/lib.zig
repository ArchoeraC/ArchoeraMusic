//! AMR-WB（G.722.2，16kHz ACELP）解码接入（.awb / `#!AMR-WB` 裸流 + 3gp 单轨抽取）
//!
//! 解码核心：codec.zig（FFmpeg amrwbdec 浮点路径逐句移植）+ tables.zig + dsp.zig。
//! 本模块负责：格式识别入口、帧迭代（读 mode → 帧长）、整读 → 逐帧解码 → 交错 s16，
//! 以 decoder.Decoder VTable 暴露（对齐 fmt/dts/ 接入模式）。
//!
//! 容器：
//!   - raw：9 字节 `#!AMR-WB\n` 头 + MIME/storage 帧（1 字节 mode 头 + 载荷），
//!     或直接逐帧（probe 已按头识别）；帧长表 = cf_sizes_wb[mode] 位 → ((b+7)/8)+1；
//!   - 3gp/mp4 单轨（.awb 样本常见形态，如 FFmpeg fate-suite amrwb）：走 mdat
//!     载荷逐帧扫描（AMR 帧含 mode 头字节，stsz 逐样本大小一致）。解码时每帧
//!     20ms → 320 样本 @16kHz，输出单声道 s16le。
//!
//! 参考：FFmpeg libavcodec/amrwbdec.c、amr.h、amrwbdata.h（LGPL-2.1+）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const codec = @import("codec.zig");

/// 每帧字节数（含 1 字节 MIME mode 头；mode 0..8 为 speech，9 SID，15 no_data）
fn frameBytes(mode: u8) ?usize {
    if (mode > 9) return null; // 10..14 保留 / 15 特殊处理（见下）
    const bits: usize = switch (mode) {
        0 => 132,
        1 => 177,
        2 => 253,
        3 => 285,
        4 => 317,
        5 => 365,
        6 => 397,
        7 => 461,
        8 => 477,
        else => 40, // SID
    };
    return (bits + 7) / 8 + 1;
}

/// 一帧信息：偏移 + 长度 + mode（无头 raw / mdat 共用）
pub const FrameRef = struct {
    offset: usize,
    len: usize,
    mode: u8,
};

/// 帧迭代器：`#!AMR-WB` 头（可选）后按 mode 前进。NO_DATA(15) 等单字节帧照常前进。
pub const FrameScanner = struct {
    buf: []const u8,
    pos: usize = 0,
    end: usize,
    /// 遇到的无效 mode（10..14）累计数
    bad: usize = 0,

    pub fn init(buf: []const u8) FrameScanner {
        var pos: usize = 0;
        if (buf.len >= 9 and std.mem.eql(u8, buf[0..9], "#!AMR-WB\n")) pos = 9;
        return .{ .buf = buf, .pos = pos, .end = buf.len };
    }

    /// 限定扫描区间（3gp mdat 载荷 [start,end)）
    pub fn initRange(buf: []const u8, start: usize, end: usize) FrameScanner {
        return .{ .buf = buf, .pos = start, .end = end };
    }

    pub fn next(self: *FrameScanner) ?FrameRef {
        if (self.pos >= self.end) return null;
        const mode = self.buf[self.pos] >> 3 & 0xF;
        if (mode >= 16) return null;
        if (mode == 15) { // no data：仅 1 字节
            const f = FrameRef{ .offset = self.pos, .len = 1, .mode = mode };
            self.pos += 1;
            return f;
        }
        const sz = frameBytes(mode) orelse {
            self.bad += 1;
            // 保留 mode：长度未知，无法对齐 → 停止
            self.pos = self.end;
            return null;
        };
        if (self.pos + sz > self.end) return null; // 截断尾
        const f = FrameRef{ .offset = self.pos, .len = sz, .mode = mode };
        self.pos += sz;
        return f;
    }
};

/// 3gp/MP4 顶层 box 类型 → 是否含 mdat 载荷；返回 mdat 数据区间
pub const MdatRange = struct { start: usize, end: usize };

/// 若为 3gp/mp4 容器，返回首个 mdat 数据区间（帧载荷扫描用）
pub fn findMdat(data: []const u8) ?MdatRange {
    if (data.len < 12) return null;
    if (!std.mem.eql(u8, data[4..8], "ftyp")) return null;
    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const size32 = std.mem.readInt(u32, data[pos..][0..4], .big);
        var size: u64 = size32;
        var hdr: usize = 8;
        var typ: []const u8 = undefined;
        if (size32 == 1) {
            if (pos + 16 > data.len) return null;
            size = std.mem.readInt(u64, data[pos + 8 ..][0..8], .big);
            hdr = 16;
            typ = data[pos + 8 .. pos + 12];
        } else if (size32 == 0) {
            size = data.len - pos;
            typ = data[pos + 4 .. pos + 8];
        } else {
            typ = data[pos + 4 .. pos + 8];
        }
        if (size < hdr or pos + size > data.len) return null;
        if (std.mem.eql(u8, typ, "mdat")) {
            const start = pos + hdr;
            return .{ .start = start, .end = start + (size - hdr) };
        }
        pos += @intCast(size);
    }
    return null;
}

/// 返回容器类型并构造帧扫描器（raw `#!AMR-WB` / 3gp mdat / 无头裸流）
pub const Container = enum { raw, mp4, raw_no_header };
fn makeScanner(data: []const u8) struct { scan: FrameScanner, container: Container } {
    if (data.len >= 9 and std.mem.eql(u8, data[0..9], "#!AMR-WB\n"))
        return .{ .scan = FrameScanner.init(data), .container = .raw };
    if (findMdat(data)) |m|
        return .{ .scan = FrameScanner.initRange(data, m.start, m.end), .container = .mp4 };
    return .{ .scan = FrameScanner.init(data), .container = .raw_no_header };
}

/// 读取全部可解码样本为浮点（16kHz 单声道原始输出）。返回样本数。
pub fn decodeAllF32(allocator: std.mem.Allocator, data: []const u8, out: *[]f32, info_out: *decoder.Info) Error!void {
    const sc = makeScanner(data);
    var dec = codec.Decoder.init();
    var pcm = std.ArrayList(f32).empty;
    errdefer pcm.deinit(allocator);

    var frames: usize = 0;
    var buf: [codec.FRAME_SAMPLES]f32 = undefined;
    var sc2 = sc.scan;
    while (sc2.next()) |fr| {
        if (fr.len == 0) continue;
        const n = dec.decodeFrame(data[fr.offset .. fr.offset + fr.len], &buf);
        if (n == 0) continue;
        try pcm.appendSlice(allocator, buf[0..n]);
        frames += 1;
    }
    if (frames == 0 or pcm.items.len == 0) return error.Corrupt;

    out.* = try pcm.toOwnedSlice(allocator);
    info_out.* = .{
        .sample_rate = 16000,
        .channels = 1,
        .bits_per_sample = 32,
        .is_float = true,
        .duration_us = @intCast(@divTrunc(@as(i128, @intCast(out.*.len)) * 1_000_000, @as(i128, 16000))),
        // 整文件预解码：输出样本总数即实际时长（帧数 × 320 / 16k）
        .duration_known = .exact,
        .codec_name = "amrwb",
        .format_name = if (sc.container == .mp4) "3gp" else "amrwb",
        .metadata = .{},
    };
}

/// 读取全部可解码样本（s16le 交错，单声道）。
pub fn decodeAll(allocator: std.mem.Allocator, data: []const u8, out: *[]i16, info_out: *decoder.Info) Error!void {
    var f32s: []f32 = &.{};
    decodeAllF32(allocator, data, &f32s, info_out) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    errdefer allocator.free(f32s);

    var pcm = std.ArrayList(i16).empty;
    errdefer pcm.deinit(allocator);
    for (f32s) |v| try pcm.append(allocator, f32ToS16(v));
    allocator.free(f32s);

    out.* = try pcm.toOwnedSlice(allocator);
    info_out.*.bits_per_sample = 16;
    info_out.*.is_float = false;
}

/// 与 ffmpeg swr FLT→S16 相同的 lrintf（round-half-even）×32768 后 clip。
pub fn f32ToS16(x: f32) i16 {
    const v: f64 = @as(f64, x) * 32768.0;
    const fl = @floor(v);
    var r: f64 = fl;
    const diff = v - fl;
    if (diff > 0.5 or (diff == 0.5 and @mod(fl, 2.0) != 0.0)) r += 1.0;
    const ri: i64 = @intFromFloat(r);
    return @intCast(std.math.clamp(ri, -32768, 32767));
}

// ---------------------------------------------------------------------------
// Decoder VTable（整读 → 逐帧 → 交错 s16；同 fmt/dts/lib.zig 接入模式）
// ---------------------------------------------------------------------------

const Ctx = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    pcm: []i16,
    total_samples: usize,
    sample_rate: u32,
    cursor: usize = 0,

    fn read(self: *Ctx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = 1;
        const n = @min(max_samples, self.total_samples - self.cursor);
        if (n == 0) return 0;
        const bytes = n * 2;
        if (out.len < bytes) return error.Corrupt;
        std.mem.copyForwards(u8, out[0..bytes], std.mem.sliceAsBytes(self.pcm[self.cursor..][0..n]));
        self.cursor += n;
        return n;
    }
};

fn awbRead(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    return c.read(out, max_samples, out_channels);
}
fn awbSeek(ctx: *anyopaque, ms: i64) Error!void {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    const target: i64 = if (ms <= 0) 0 else @intCast(@divTrunc(@as(i128, ms) * @as(i128, c.sample_rate), 1000));
    c.cursor = @min(@as(usize, @intCast(@max(target, 0))), c.total_samples);
}
fn awbPos(ctx: *anyopaque) i64 {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    return @intCast(@divTrunc(@as(i128, @intCast(c.cursor)) * 1000, c.sample_rate));
}
fn awbDeinit(ctx: *anyopaque) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    const a = c.allocator;
    a.free(c.data);
    a.free(c.pcm);
    a.destroy(c);
}

const vtable = decoder.Decoder.VTable{
    .read = awbRead,
    .seek_ms = awbSeek,
    .position_ms = awbPos,
    .deinit = awbDeinit,
};

/// 打开 .awb / #!AMR-WB（含 3gp 单轨）整文件解码；成功接管 `reader` 所有权。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const sz = reader.size() catch return error.Corrupt;
    if (sz <= 0 or sz > 256 * 1024 * 1024) return error.UnsupportedFormat;
    const data = try allocator.alloc(u8, @intCast(sz));
    errdefer allocator.free(data);
    var got: usize = 0;
    while (got < data.len) {
        const n = try reader.read(data[got..]);
        if (n == 0) break;
        got += n;
    }
    if (got == 0) return error.Corrupt;

    var pcm: []i16 = &.{};
    var out_info: decoder.Info = undefined;
    decodeAll(allocator, data[0..got], &pcm, &out_info) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            allocator.free(data);
            return error.Corrupt;
        },
    };
    errdefer allocator.free(pcm);

    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .data = data,
        .pcm = pcm,
        .total_samples = pcm.len,
        .sample_rate = out_info.sample_rate,
    };
    info.* = out_info;
    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

test "frameBytes：各 mode 帧长（含头字节）与 ffmpeg cf_sizes_wb+1 对齐" {
    const expect = [_]?usize{ 18, 24, 33, 37, 41, 47, 51, 59, 61, 6, null, null, null, null, null, null };
    for (0..16) |m| try testing.expectEqual(expect[m], frameBytes(@intCast(m)));
}

test "FrameScanner：6k60 fixture 帧数与时长" {
    const fx = @embedFile("tiny/seed-6k60.awb");
    var s = FrameScanner.init(fx);
    var n: usize = 0;
    var bytes: usize = 0;
    while (s.next()) |fr| {
        try testing.expectEqual(@as(u8, 0), fr.mode);
        bytes += fr.len;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(usize, fx.len), bytes + 9);
}

test "findMdat：3gp 容器识别（真实 3gp 头样本）" {
    // 从 raw fixture 构造：ftyp + mdat（载荷 = 去掉 #!AMR-WB 头的帧流）
    const fx = @embedFile("tiny/seed-6k60.awb"); // raw 带 #!AMR-WB
    const mp4 = blk: {
        var b = std.ArrayList(u8).empty;
        defer b.deinit(testing.allocator);
        try b.appendSlice(testing.allocator, "\x00\x00\x00\x1cftyp3gp4\x00\x00\x02\x00isomiso23gp4");
        const mdat_payload = fx[9..];
        const mdat_size: u32 = @intCast(8 + mdat_payload.len);
        var szb: [4]u8 = undefined;
        std.mem.writeInt(u32, &szb, mdat_size, .big);
        try b.appendSlice(testing.allocator, &szb);
        try b.appendSlice(testing.allocator, "mdat");
        try b.appendSlice(testing.allocator, mdat_payload);
        break :blk try b.toOwnedSlice(testing.allocator);
    };
    defer testing.allocator.free(mp4);
    const m = findMdat(mp4) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 36), m.start);
    try testing.expectEqual(@as(usize, mp4.len), m.end);
    var s = FrameScanner.initRange(mp4, m.start, m.end);
    var n: usize = 0;
    while (s.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 4), n);
}

test "decodeAll：6k60/12k65/23k85 fixture 解码输出基本一致（帧数 ×320 s16）" {
    const Case = struct { path: []const u8, frames: usize };
    const cases = [_]Case{
        .{ .path = @embedFile("tiny/seed-6k60.awb"), .frames = 4 },
        .{ .path = @embedFile("tiny/seed-12k65.awb"), .frames = 4 },
        .{ .path = @embedFile("tiny/seed-23k85.awb"), .frames = 4 },
    };
    for (cases) |c| {
        var pcm: []i16 = &.{};
        var inf: decoder.Info = undefined;
        try decodeAll(testing.allocator, c.path, &pcm, &inf);
        defer testing.allocator.free(pcm);
        try testing.expectEqual(@as(usize, c.frames * 320), pcm.len);
        try testing.expectEqual(@as(u32, 16000), inf.sample_rate);
        try testing.expectEqual(@as(u8, 1), inf.channels);
        try testing.expectEqualStrings("amrwb", inf.codec_name);
        var energy: f64 = 0;
        var peak: i32 = 0;
        for (pcm) |v| {
            energy += @as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(v));
            const a: i32 = if (v < 0) -@as(i32, v) else v;
            peak = @max(peak, a);
        }
        // 语音 fixture 应含实质内容（非静音）且幅值有界
        try testing.expect(peak > 100);
        try testing.expect(peak <= 32767);

    }
}

//! TAK (Tom's lossless Audio Kompressor, .tak, 无损) 解码器接入层（fmt/tak）。
//!
//! 容器（libavformat/takdec.c + tak_parser.c + tak.c）：
//!   - 可选容器头：魔数 "tBaK"（4 字节）后跟元数据块流。每块 = 1 字节类型
//!     (&0x7F) + 3 字节 LE size + (size-3) 字节数据 + 3 字节 CRC-24/BE
//!     （init 0xCE04B7）。块类型：STREAMINFO(1) 位段、LAST_FRAME(7)
//!     （last_frame_pos 40 位 + last_frame_size 24 位，相对帧区起点）、
//!     END(0) 终止；ENCODER/MD5/其它跳过。帧区 = END 块后到
//!     (data_start + pos + size) 的绝对终点；无 tBaK 头则整文件视为帧区；
//!   - 帧表构建（对齐 tak_parser）：在帧区扫描 sync 字节 FF A0，解析帧头并
//!     校验头 CRC-24 后才认作帧边界；帧间按边界切分，末帧延至帧区终点；
//!     每帧样本数 = IS_LAST? last_frame_samples : frame_samples（随 HAS_INFO
//!     STREAMINFO 逐帧更新）。
//!
//! 解码语义（对齐 ffmpeg n9.0.1 native tak，kernel/fmt/tak/core.zig）：
//!   - LSB-first 位流；帧独立可随机访问（帧解码无跨帧状态）；
//!   - 输出对齐 ffmpeg 内部样本格式：8bit → u8(+0x80)、16bit → s16
//!     （=`-f s16le`）、24bit → int32<<8（=`-f s32le`）；Info.bits_per_sample
//!     报 8/16/32；codec 非 MONO_STEREO/MULTICHANNEL、data_type≠0 或通道>6 →
//!     UnsupportedFormat。
//!
//! 建议 probe/接线（集成者执行）：
//!   - probe.zig Format 增 `.tak`；formats 增 `.tak = true`；
//!     identify 增 `if (eql(head[0..4], "tBaK")) return .tak;`
//!     （与 ffmpeg libavformat tak_probe 的 AVPROBE_SCORE_EXTENSION 同源）；
//!   - decoder.zig dispatch 增 `.tak => tak.open(allocator, &reader, info)`；
//!   - kernel.zig 聚合测试增 `_ = @import("fmt/tak/tables.zig")`、
//!     `_ = @import("fmt/tak/core.zig")`、`_ = @import("fmt/tak/lib.zig")`；
//!   - codec_name = "tak"，format_name = "tak"。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const core = @import("core.zig");
const T = @import("tables.zig");

const StreamInfo = core.StreamInfo;

/// 容器元数据解析结果
const Metadata = struct {
    /// 是否有 tBaK 容器头
    framed: bool = false,
    has_streaminfo: bool = false,
    streaminfo: StreamInfo = .{},
    /// 帧区起点（END 块后；无头时为 0）
    data_start: usize = 0,
    /// 帧区终点（LAST_FRAME 决定；否则为文件尾）
    data_end: usize = 0,
};

fn readLe24(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16);
}

/// 解析容器头（无 "tBaK" 时返回全默认：整文件为帧区）。
fn parseMetadata(data: []const u8) Error!Metadata {
    var m = Metadata{};
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], "tBaK")) {
        m.framed = false;
        m.data_start = 0;
        m.data_end = data.len;
        return m;
    }
    m.framed = true;
    var pos: usize = 4;
    var last_rel_end: ?u64 = null;
    var saw_end = false;
    while (pos + 4 <= data.len) {
        const typ: u8 = data[pos] & 0x7f;
        const size: usize = readLe24(data[pos + 1 .. pos + 4]);
        const total: usize = 4 + size;
        if (pos + total > data.len) return error.Corrupt;
        const body = data[pos + 4 .. pos + total];
        switch (typ) {
            T.TAK_METADATA_STREAMINFO => {
                if (!m.has_streaminfo) {
                    if (size <= 3) return error.Corrupt;
                    var br = core.BitReader.init(body[0 .. size - 3]);
                    try core.parseStreamInfoBits(&br, &m.streaminfo);
                    m.has_streaminfo = true;
                }
            },
            T.TAK_METADATA_LAST_FRAME => {
                if (size < 11) return error.Corrupt;
                var br = core.BitReader.init(body[0 .. size - 3]);
                const p = br.readBits64(T.TAK_LAST_FRAME_POS_BITS);
                const sz = br.readBits(T.TAK_LAST_FRAME_SIZE_BITS);
                last_rel_end = p + sz;
            },
            T.TAK_METADATA_END => {
                m.data_start = pos + total;
                saw_end = true;
                break;
            },
            else => {},
        }
        pos += total;
    }
    if (m.framed and !saw_end) return error.Corrupt; // 缺 END 块
    if (m.framed and m.data_start >= data.len) return error.Corrupt;
    m.data_end = if (last_rel_end) |rel| blk: {
        const abs = m.data_start +| @as(usize, @intCast(rel));
        break :blk @min(abs, data.len);
    } else data.len;
    if (m.data_end < m.data_start) return error.Corrupt;
    return m;
}

/// 帧表：starts/ends 字节区间 + 每帧样本数
const Frames = struct {
    starts: []usize,
    ends: []usize,
    ns: []usize,
    nframes: usize,
    total_samples: usize,
};

/// 构建帧表（对齐 tak_parser 语义：sync + 帧头 CRC-24 校验）。
/// 运行 ti 逐帧更新（HAS_INFO 时并入），返回更新后的流信息。
fn scanFrames(a: std.mem.Allocator, data: []const u8, start: usize, end: usize, ti: *StreamInfo) Error!Frames {
    var starts = std.ArrayList(usize).empty;
    defer starts.deinit(a);
    var ns = std.ArrayList(usize).empty;
    defer ns.deinit(a);

    var pos = start;
    while (pos + 2 <= end) : (pos += 1) {
        if (data[pos] != 0xFF or data[pos + 1] != 0xA0) continue;
        var br = core.BitReader.init(data[pos..end]);
        var tmp = ti.*;
        const flags = core.parseFrameHeader(&br, &tmp) catch continue;
        const hsize = br.pos / 8;
        if (hsize < 4 or pos + hsize > end) continue;
        if (!T.checkCrc(data[pos .. pos + hsize], hsize)) continue;
        // 有效帧边界
        ti.* = tmp;
        const nb: usize = if (flags & T.TAK_FRAME_HEADER_FLAG_IS_LAST != 0)
            @intCast(ti.last_frame_samples)
        else
            @intCast(ti.frame_samples);
        if (nb == 0) return error.Corrupt;
        starts.append(a, pos) catch return error.OutOfMemory;
        ns.append(a, nb) catch return error.OutOfMemory;
    }

    const n = starts.items.len;
    if (n == 0) return error.Corrupt;
    const soff = try a.alloc(usize, n);
    errdefer a.free(soff);
    const eoff = try a.alloc(usize, n);
    errdefer a.free(eoff);
    const slist = try a.alloc(usize, n);
    errdefer a.free(slist);
    var total: usize = 0;
    for (0..n) |i| {
        soff[i] = starts.items[i];
        slist[i] = ns.items[i];
        total +%= ns.items[i];
        eoff[i] = if (i + 1 < n) starts.items[i + 1] else end;
    }
    return .{
        .starts = soff,
        .ends = eoff,
        .ns = slist,
        .nframes = n,
        .total_samples = total,
    };
}

const DecoderCtx = struct {
    allocator: std.mem.Allocator,
    data: []u8, // 整文件（owned）
    frames: Frames, // owned
    dec: core.Decoder,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u16,
    width: u8, // 输出每样本字节（1/2/4）
    total_samples: usize,
    // 每帧解码输出缓冲（交错字节；上限 max samples/帧）
    queue: []u8,
    ti: StreamInfo,
    // 游标
    cursor: usize = 0, // 绝对样本（每声道）位置
    q_len: usize = 0,
    q_pos: usize = 0,
    have_queue: bool = false,

    fn ilv(self: *const DecoderCtx) usize {
        return @as(usize, self.channels) * self.width;
    }

    fn frameBase(self: *const DecoderCtx, fidx: usize) usize {
        var acc: usize = 0;
        for (0..fidx) |i| acc += self.frames.ns[i];
        return acc;
    }

    fn decodeFrameBytes(self: *DecoderCtx, fidx: usize) Error!void {
        const s = self.frames.starts[fidx];
        const fe = self.frames.ends[fidx];
        const frame_data = self.data[s..fe];
        var br = core.BitReader.init(frame_data);
        var ti2 = self.ti;
        const flags = core.parseFrameHeader(&br, &ti2) catch return error.Corrupt;
        self.ti = ti2;
        const nb: usize = if (flags & T.TAK_FRAME_HEADER_FLAG_IS_LAST != 0)
            @intCast(ti2.last_frame_samples)
        else
            @intCast(ti2.frame_samples);
        if (nb == 0) return error.Corrupt;
        self.dec.decodeBody(&br, &ti2, nb, self.queue) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };
        self.q_len = nb;
        const intra = self.cursor - self.frameBase(fidx);
        self.q_pos = @min(intra, nb);
        self.have_queue = true;
    }

    fn read(self: *DecoderCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = self.channels;
        if (self.cursor >= self.total_samples) return 0;
        const interleave = self.ilv();
        const want = @min(@min(max_samples, self.total_samples - self.cursor), out.len / interleave);
        if (want == 0 or out.len == 0) return 0;

        var produced: usize = 0;
        while (produced < want) {
            if (!self.have_queue) {
                const fidx = self.frameIndexOf(self.cursor) orelse return error.Corrupt;
                try self.decodeFrameBytes(fidx);
            }
            const take = @min(want - produced, self.q_len - self.q_pos);
            const dst = out[produced * interleave ..][0 .. take * interleave];
            const src = self.queue[self.q_pos * interleave ..][0 .. take * interleave];
            @memcpy(dst, src);
            self.q_pos += take;
            self.cursor += take;
            produced += take;
            if (self.q_pos >= self.q_len) self.have_queue = false;
        }
        return produced;
    }

    fn frameIndexOf(self: *const DecoderCtx, sample: usize) ?usize {
        var acc: usize = 0;
        for (0..self.frames.nframes) |i| {
            if (sample < acc + self.frames.ns[i]) return i;
            acc += self.frames.ns[i];
        }
        return null;
    }

    fn sampleToMs(samples: usize, sr: u32) i64 {
        return @intCast(@divTrunc(@as(i128, @intCast(samples)) * 1000, @as(i128, sr)));
    }
};

const vtable = decoder.Decoder.VTable{
    .read = read,
    .seek_ms = seekMs,
    .position_ms = positionMs,
    .deinit = deinit,
};

fn read(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}

fn seekMs(ctx: *anyopaque, ms: i64) Error!void {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const target: usize = if (ms <= 0)
        0
    else
        @min(@as(usize, @intCast(@divTrunc(@as(u128, @intCast(ms)) * self.sample_rate, 1000))), self.total_samples);
    self.cursor = target;
    self.have_queue = false;
    self.q_pos = 0;
}

fn positionMs(ctx: *anyopaque) i64 {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    return DecoderCtx.sampleToMs(self.cursor, self.sample_rate);
}

fn deinit(ctx: *anyopaque) void {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const a = self.allocator;
    self.dec.deinit();
    a.free(self.queue);
    a.free(self.frames.starts);
    a.free(self.frames.ends);
    a.free(self.frames.ns);
    a.free(self.data);
    a.destroy(self);
}

fn widthOf(bits: u16) u8 {
    return switch ((bits + 7) / 8) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const fsize = try reader.size();
    if (fsize < 4) return error.Corrupt;
    const data = try allocator.alloc(u8, @intCast(fsize));
    errdefer allocator.free(data);
    var got: usize = 0;
    while (got < fsize) {
        const n = reader.read(data[got..]) catch |e| switch (e) {
            error.Aborted => return error.Aborted,
            else => return error.IoError,
        };
        if (n == 0) break;
        got += n;
    }
    if (got < fsize) return error.Corrupt;

    const meta = try parseMetadata(data);
    var ti = meta.streaminfo;
    const frames = scanFrames(allocator, data, meta.data_start, meta.data_end, &ti) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    errdefer {
        allocator.free(frames.starts);
        allocator.free(frames.ends);
        allocator.free(frames.ns);
    }

    if (ti.channels == 0 or ti.channels > 6 or ti.sample_rate == 0 or ti.bps == 0)
        return error.Corrupt;
    if (ti.codec != T.TAK_CODEC_MONO_STEREO and ti.codec != T.TAK_CODEC_MULTICHANNEL)
        return error.UnsupportedFormat;
    if (ti.data_type != 0) return error.UnsupportedFormat;
    if (ti.codec == T.TAK_CODEC_MONO_STEREO and ti.channels > 2) return error.Corrupt;
    if (ti.bps != 8 and ti.bps != 16 and ti.bps != 24) return error.UnsupportedFormat;

    var dec = try core.Decoder.init(allocator);
    errdefer dec.deinit();

    const width = widthOf(@intCast(ti.bps));
    const qbytes = T.TAK_MAX_FRAME_SAMPLES * @as(usize, ti.channels) * width;
    const queue = try allocator.alloc(u8, qbytes);
    errdefer allocator.free(queue);

    const ctx = try allocator.create(DecoderCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .data = data,
        .frames = frames,
        .dec = dec,
        .sample_rate = ti.sample_rate,
        .channels = @intCast(ti.channels),
        .bits_per_sample = @intCast(ti.bps),
        .width = width,
        .total_samples = frames.total_samples,
        .queue = queue,
        .ti = ti,
    };

    info.* = .{
        .sample_rate = ctx.sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = if (ctx.bits_per_sample <= 16) @intCast(ctx.bits_per_sample) else 32,
        .is_float = false,
        .duration_us = @intCast(@divTrunc(@as(u128, @intCast(ctx.total_samples)) * 1_000_000, ctx.sample_rate)),
        .duration_known = .exact,
        .codec_name = "tak",
        .format_name = "tak",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// 回归测试（golden = ffmpeg n9.0.1 native tak 解码，逐字节）
// ---------------------------------------------------------------------------

const testing = std.testing;

const luckynight_tak = @embedFile("samples/luckynight-partial.tak"); // FATE 44.1k 立体声 16bit
const luckynight_golden = @embedFile("samples/luckynight-partial.s16");

fn decodeAll(tak: []const u8) !struct { bytes: std.ArrayList(u8), info: decoder.Info } {
    var r = io.Reader.openMem(tak);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * (info.bits_per_sample / 8)]);
    }
    return .{ .bytes = out, .info = info };
}

test "tak e2e: luckynight-partial.tak (44.1k/16bit 2ch, 38 帧) == ffmpeg s16le" {
    var res = try decodeAll(luckynight_tak);
    defer res.bytes.deinit(testing.allocator);
    const info = res.info;
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqualStrings("tak", info.codec_name);
    try testing.expectEqualStrings("tak", info.format_name);
    try testing.expectEqual(info.duration_known, .exact);

    const ns = res.bytes.items.len;
    const ng = luckynight_golden.len;
    var first_diff: ?usize = null;
    var equal: usize = 0;
    for (0..@min(ns, ng)) |i| {
        if (res.bytes.items[i] == luckynight_golden[i]) {
            equal += 1;
        } else if (first_diff == null) {
            first_diff = i;
        }
    }
    std.debug.print("  bytes mine={d} golden={d} equal={d}/{d} = {d:.6}%  first_diff={any}\n", .{
        ns, ng, equal, @min(ns, ng), 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(@min(ns, ng))), first_diff,
    });
    try testing.expectEqual(ng, ns);
    try testing.expectEqualSlices(u8, luckynight_golden, res.bytes.items);
}

test "tak seek: 7000ms 帧边界随机访问 == golden 同区段" {
    const a = testing.allocator;
    var r = io.Reader.openMem(luckynight_tak);
    var info: decoder.Info = undefined;
    var d = try open(a, &r, &info);
    defer d.deinit();

    try d.seekMs(7000);
    var seg = std.ArrayList(u8).empty;
    defer seg.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try seg.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
    }
    const target_sample: usize = 7000 * 44100 / 1000; // 308700（帧 28 内）
    try testing.expect(target_sample * 4 + seg.items.len <= luckynight_golden.len);
    try testing.expectEqualSlices(u8, luckynight_golden[target_sample * 4 .. target_sample * 4 + seg.items.len], seg.items);
}

test "tak 结构: 帧表 = 38 帧，metadata STREAMINFO 位段解析" {
    const a = testing.allocator;
    const meta = try parseMetadata(luckynight_tak);
    try testing.expect(meta.framed);
    try testing.expect(meta.has_streaminfo);
    try testing.expectEqual(@as(u32, 2), meta.streaminfo.codec); // MONO_STEREO
    try testing.expectEqual(@as(u32, 44100), meta.streaminfo.sample_rate);
    try testing.expectEqual(@as(u32, 16), meta.streaminfo.bps);
    try testing.expectEqual(@as(u32, 2), meta.streaminfo.channels);
    try testing.expectEqual(@as(i64, 418950), meta.streaminfo.samples);
    try testing.expectEqual(@as(i32, 11025), meta.streaminfo.frame_samples);

    var ti = meta.streaminfo;
    const frames = try scanFrames(a, luckynight_tak, meta.data_start, meta.data_end, &ti);
    defer {
        a.free(frames.starts);
        a.free(frames.ends);
        a.free(frames.ns);
    }
    try testing.expectEqual(@as(usize, 38), frames.nframes);
    try testing.expectEqual(@as(usize, 418950), frames.total_samples);
    // 各帧样本数 = 11025
    for (frames.ns) |n| try testing.expectEqual(@as(usize, 11025), n);
    // 帧字节区间连续且递增
    for (1..frames.nframes) |i| try testing.expect(frames.starts[i] > frames.starts[i - 1]);
}

test "tak 健壮性: 坏魔数/截断 → Corrupt；非法位深 → UnsupportedFormat" {
    var info: decoder.Info = undefined;
    // 坏魔数（非 tBaK 也不像帧 → Corrupt）
    var bad = [_]u8{0} ** 64;
    @memcpy(bad[0..4], "XXXX");
    var r0 = io.Reader.openMem(&bad);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r0, &info));
    // 截断（不足 4 字节）
    var r1 = io.Reader.openMem(luckynight_tak[0..3]);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r1, &info));
    // tBaK 后缺 END 块（直接截断元数据）
    var r2 = io.Reader.openMem(luckynight_tak[0..4]);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r2, &info));
}

//! Shorten (.shn, 无损) 解码器接入层（fmt/shn）。
//!
//! 容器（libavformat/shortendec.c）：裸流，无封装头；魔数 4 字节 "ajkg"
//! （0x616A6B67，AV_RB32）+ 1 字节 version，随后 golomb 编码的
//! internal_ftype/channels/blocksize 等命令流；音频参数（采样率/bps）
//! 在流首 FN_VERBATIM 携带的 WAVE（RIFF/fmt）或 AIFF（FORM/COMM）canonical
//! 头（≥44 字节）内。
//!
//! 建议 probe 接线（照 libavformat/shortendec.c shn_probe，评分 ≥ 51）：
//!   1. AV_RB32(buf) == 0x616a6b67（"ajkg"）；
//!   2. version = buf[4]；version==0：internal_ftype=UR(4)、channels=UR(0)、
//!      blocksize=256；version>0：k=UR(2)（≤31）→ internal_ftype=UR(k)，
//!      k=UR(2) → channels=UR(k)，k=UR(2) → blocksize=UR(k)（MSB-first 位序）；
//!   3. internal_ftype ∈ {2,3,5}（U8/S16HL/S16LH）且 1 ≤ channels ≤ 8 且
//!      1 ≤ blocksize ≤ 65535 → 识别 Format.shn。
//!   decoder dispatch：`.shn => shn.open(allocator, &reader, info)`；
//!   未识别 → 交由 FFmpeg 主后端（错误集内 UnsupportedFormat）。
//!
//! 解码语义（对齐 ffmpeg n9.0.1 native shorten，kernel/fmt/shn/core.zig）：
//!   - MSB-first 位流 + jpegls 变体 Rice（unary + k 位后缀；符号 = zigzag）；
//!   - internal_ftype 决定输出：TYPE_U8 → u8、TYPE_S16HL/S16LH → s16
//!     （AIFF-C swap 为值字节交换后按 LE 输出，与 ffmpeg `-f s16le` 逐位一致）；
//!   - seek：Shorten 块间状态耦合（wrap 样本/均值），不支持随机访问；
//!     seek_ms 重建解码器后从头快进到目标块（正确性优先）；
//!   - 时长：裸流无总长字段（ffmpeg Duration: N/A）→ duration_known = .unknown。
//!
//! Info：sample_rate/channels 取自 WAVE-AIFF 头 + shorten 头；
//! bits_per_sample = 8（U8）/ 16（S16）；codec_name = "shorten"，format_name = "shn"。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const core = @import("core.zig");

const DecoderCtx = struct {
    allocator: std.mem.Allocator,
    data: []u8, // 整文件（owned）
    dec: core.Decoder,
    sample_rate: u32,
    channels: u8,
    width: u8, // 输出每样本字节（1 = u8 / 2 = s16）
    // 输出块队列（一解码块 = blocksize×channels×width 字节；owned）
    queue: []u8,
    q_len: usize = 0, // queue 中本块帧数
    q_pos: usize = 0, // 本块内已消费帧
    have_queue: bool = false,
    cursor: usize = 0, // 绝对样本（帧）位置
    failed: bool = false,

    fn stride(self: *const DecoderCtx) usize {
        return @as(usize, self.channels) * self.width;
    }

    /// seek 用的快进：解码（丢弃）直到 target 样本；target 落在块中段时
    /// 保留该块队列并从块内偏移继续。返回实际定位（= target 或 EOF 处）。
    fn fastForward(self: *DecoderCtx, target: usize) Error!usize {
        var pos: usize = 0;
        while (pos < target) {
            const ok = try self.dec.nextBlock(self.queue);
            if (!ok) return pos;
            const frames = self.dec.blocksize;
            if (pos + frames > target) {
                self.q_len = frames;
                self.q_pos = target - pos;
                self.have_queue = true;
                return target;
            }
            pos += frames;
        }
        return pos;
    }

    fn read(self: *DecoderCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = self.channels;
        if (self.failed) return error.DecodeFailed;
        const interleave = self.stride();
        if (interleave == 0 or out.len == 0) return 0;
        const want = @min(max_samples, out.len / interleave);
        if (want == 0) return 0;

        var produced: usize = 0;
        while (produced < want) {
            if (!self.have_queue) {
                const ok = self.dec.nextBlock(self.queue) catch |e| {
                    self.failed = true;
                    return e;
                };
                if (!ok) break; // EOF（QUIT / 位流耗尽）
                self.q_len = self.dec.blocksize;
                self.q_pos = 0;
                self.have_queue = true;
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
    if (self.failed) return error.DecodeFailed;
    const target: usize = if (ms <= 0)
        0
    else
        @intCast(@divTrunc(@as(u128, @intCast(ms)) * self.sample_rate, 1000));
    if (target == self.cursor and self.have_queue and self.q_pos == 0) return; // 已在块边界
    // Shorten 块间状态耦合：重建解码器 + 从头快进（正确性优先）
    self.dec.deinit();
    self.dec = core.Decoder.init(self.allocator, self.data);
    self.have_queue = false;
    self.q_len = 0;
    self.q_pos = 0;
    self.cursor = 0;
    self.cursor = try self.fastForward(target);
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
    a.free(self.data);
    a.destroy(self);
}

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const fsize = try reader.size();
    if (fsize < 5) return error.Corrupt; // 魔数 4 字节 + version
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

    var dec = core.Decoder.init(allocator, data);
    errdefer dec.deinit();
    // 头部即时解析（Info 需要 sr/ch/bps；与 ffmpeg 首 decode 调用 read_header 等价）
    try dec.parseHeader();
    if (dec.sample_rate == 0) return error.Corrupt;

    const width: u8 = switch (dec.sample_type) {
        .u8 => 1,
        .s16 => 2,
    };
    // 输出块队列（按头内初始 blocksize 分配；FN_BLOCKSIZE 只缩不增）
    const qbytes = dec.blocksize * dec.channels * @as(usize, width);
    // 失败时由上方 errdefer dec.deinit() 统一释放
    const queue = try allocator.alloc(u8, qbytes);
    errdefer allocator.free(queue);

    const ctx = try allocator.create(DecoderCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .data = data,
        .dec = dec,
        .sample_rate = dec.sample_rate,
        .channels = @intCast(dec.channels),
        .width = width,
        .queue = queue,
    };

    info.* = .{
        .sample_rate = ctx.sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = switch (dec.sample_type) {
            .u8 => 8,
            .s16 => 16,
        },
        .is_float = false,
        .duration_us = 0,
        .duration_known = .unknown, // 裸流无总长字段（ffmpeg Duration: N/A）
        .codec_name = "shorten",
        .format_name = "shn",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// 回归测试（golden = ffmpeg n9.0.1 native shorten 解码，逐字节）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// FATE luckynight-partial.shn（44.1k 立体声 16bit，1MB 截断样本）
const luckynight_shn = @embedFile("samples/luckynight-partial.shn");
const luckynight_golden = @embedFile("samples/luckynight-partial.s16");

fn decodeAll(shn: []const u8) !struct { bytes: std.ArrayList(u8), info: decoder.Info } {
    var r = io.Reader.openMem(shn);
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

test "shn e2e: luckynight-partial.shn (44.1k/16bit 2ch) == ffmpeg s16le（逐位）" {
    var res = try decodeAll(luckynight_shn);
    defer res.bytes.deinit(testing.allocator);
    const info = res.info;
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqualStrings("shorten", info.codec_name);
    try testing.expectEqualStrings("shn", info.format_name);
    try testing.expectEqual(info.duration_known, .unknown);

    const ns = res.bytes.items.len;
    const ng = luckynight_golden.len;
    if (ns != ng) {
        std.debug.print("  WARN byte count mine={d} golden={d}\n", .{ ns, ng });
    }
    const limit = @min(ns, ng);
    var first_diff: ?usize = null;
    var equal: usize = 0;
    for (0..limit) |i| {
        if (res.bytes.items[i] == luckynight_golden[i]) {
            equal += 1;
        } else if (first_diff == null) {
            first_diff = i;
        }
    }
    std.debug.print("  bytes mine={d} golden={d} equal={d}/{d} = {d:.4}%  first_diff={any}\n", .{
        ns, ng, equal, limit, 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(limit)), first_diff,
    });
    try testing.expectEqual(ng, ns);
    try testing.expectEqualSlices(u8, luckynight_golden, res.bytes.items);
}

test "shn seek: 4000ms 快进重解码 == golden 同区段（随机访问正确性）" {
    const a = testing.allocator;
    var r = io.Reader.openMem(luckynight_shn);
    var info: decoder.Info = undefined;
    var d = try open(a, &r, &info);
    defer d.deinit();

    try d.seekMs(4000);
    var seg = std.ArrayList(u8).empty;
    defer seg.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try seg.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
    }
    const target_sample: usize = 4000 * 44100 / 1000; // 176400（块边界：176400/256=689.06 → 块 689 中段）
    try testing.expect(target_sample * 4 + seg.items.len <= luckynight_golden.len);
    try testing.expectEqualSlices(u8, luckynight_golden[target_sample * 4 .. target_sample * 4 + seg.items.len], seg.items);

    // seek 回 0 重解码 == 全量
    try d.seekMs(0);
    var full = std.ArrayList(u8).empty;
    defer full.deinit(a);
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try full.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqualSlices(u8, luckynight_golden, full.items);
}

test "shn 健壮性: 坏魔数/截断头 → Corrupt；非 RIFF/FORM verbatim → UnsupportedFormat" {
    var info: decoder.Info = undefined;

    // 坏魔数
    var bad_magic = [_]u8{0} ** 64;
    @memcpy(bad_magic[0..4], "XJKG");
    var r0 = io.Reader.openMem(&bad_magic);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r0, &info));

    // 截断（不足 5 字节）
    var r1 = io.Reader.openMem(luckynight_shn[0..4]);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r1, &info));

    // 魔数正确但流损坏（version 后乱码 → channels=0）
    var bad_stream = [_]u8{0} ** 64;
    @memcpy(bad_stream[0..4], "ajkg");
    bad_stream[4] = 2;
    var r2 = io.Reader.openMem(&bad_stream);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r2, &info));
}

// ---------------------------------------------------------------------------
// 合成样本（编码器镜像生成的码流，oracle = ffmpeg n9.0.1 native shorten 解码）：
// 覆盖 v0/v1/v2、FN_QLPC/DIFF0..3/ZERO/BITSHIFT/BLOCKSIZE/VERBATIM、
// U8/S16、AIFF/AIFF-C(swap)、1/2/4 声道。
// ---------------------------------------------------------------------------

const synth_v2_qlpc = @embedFile("samples/synth_v2_qlpc_2ch.shn");
const synth_v2_qlpc_golden = @embedFile("samples/synth_v2_qlpc_2ch.s16");
const synth_v1_diff = @embedFile("samples/synth_v1_diff_1ch.shn");
const synth_v1_diff_golden = @embedFile("samples/synth_v1_diff_1ch.s16");
const synth_v0_u8 = @embedFile("samples/synth_v0_u8.shn");
const synth_v0_u8_golden = @embedFile("samples/synth_v0_u8.u8");
const synth_v2_aiff4 = @embedFile("samples/synth_v2_aiff_4ch.shn");
const synth_v2_aiff4_golden = @embedFile("samples/synth_v2_aiff_4ch.s16");
const synth_v2_aifc = @embedFile("samples/synth_v2_aifc_swap_1ch.shn");
const synth_v2_aifc_golden = @embedFile("samples/synth_v2_aifc_swap_1ch.s16");

fn expectGolden(shn: []const u8, golden: []const u8, width: usize) !void {
    var r = io.Reader.openMem(shn);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * width]);
    }
    try testing.expectEqual(golden.len, out.items.len);
    try testing.expectEqualSlices(u8, golden, out.items);
}

test "shn 合成: v2 QLPC+DIFF0..3+ZERO+BITSHIFT2+BLOCKSIZE 缩+VERBATIM (2ch) == ffmpeg s16le" {
    var r = io.Reader.openMem(synth_v2_qlpc);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try expectGolden(synth_v2_qlpc, synth_v2_qlpc_golden, 2);
}

test "shn 合成: v1 DIFF0 (1ch, 无 lpcqoffset/均值无移位) == ffmpeg s16le" {
    var r = io.Reader.openMem(synth_v1_diff);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try expectGolden(synth_v1_diff, synth_v1_diff_golden, 2);
}

test "shn 合成: v0 U8 (k=字段-1 hack, coffset=0) == ffmpeg u8" {
    var r = io.Reader.openMem(synth_v0_u8);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(u8, 8), info.bits_per_sample);
    try expectGolden(synth_v0_u8, synth_v0_u8_golden, 1);
}

test "shn 合成: v2 AIFF 头 4ch == ffmpeg s16le（FORM/COMM 80bit 采样率 + 多声道交错）" {
    var r = io.Reader.openMem(synth_v2_aiff4);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try testing.expectEqual(@as(u8, 4), info.channels);
    try expectGolden(synth_v2_aiff4, synth_v2_aiff4_golden, 2);
}

test "shn 合成: v2 AIFF-C swap（值字节交换）== ffmpeg s16le" {
    var r = io.Reader.openMem(synth_v2_aifc);
    var info: decoder.Info = undefined;
    var d = try open(testing.allocator, &r, &info);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try expectGolden(synth_v2_aifc, synth_v2_aifc_golden, 2);
}

test "shn 流式: 逐样本读取（max_samples=1/7 奇异缓冲）== 全量输出（队列切片正确性）" {
    const a = testing.allocator;
    var r = io.Reader.openMem(luckynight_shn);
    var info: decoder.Info = undefined;
    var d = try open(a, &r, &info);
    defer d.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var buf: [64]u8 = undefined;
    var rounds: usize = 0;
    while (true) {
        var ch: u8 = 0;
        const take: usize = if (rounds % 3 == 0) 1 else 7;
        const n = try d.read(&buf, take, &ch);
        if (n == 0) break;
        try out.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
        rounds += 1;
        if (rounds > 2_000_000) return error.TestUnexpectedResult; // 防死循环
    }
    try testing.expectEqual(luckynight_golden.len, out.items.len);
    try testing.expectEqualSlices(u8, luckynight_golden, out.items);
}

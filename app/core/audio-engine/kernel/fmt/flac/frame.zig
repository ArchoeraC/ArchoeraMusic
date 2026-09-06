// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! FLAC 音频帧头解析（ff_flac_decode_frame_header，参考重构）
//!
//! 帧头位排布（32 位后字节对齐）：
//!   sync(15)=0x7FFC + var_size(1) | bs_code(4) + sr_code(4) + ch_mode(4)
//!   + bps_code(3) + reserved(1) | UTF-8 帧号/样本号 | blocksize 扩展位
//!   | samplerate 扩展位 | CRC-8（整帧头含 CRC 字节校验和应为 0）
//!
//! 常量表（flacdata.c）：
//!   - blocksize：code 6/7 为 8/16 位 +1，其余查表（0/192/576/…/32768）；
//!   - samplerate：code <12 查表，12/13/14 为 8 位*1000 / 16 位 / 16 位*10；
//!   - bps：code 0 = 0（用 STREAMINFO），3 非法，其余 8/12/16/20/24/32。
//!
//! ch_mode（flac.h FLAC_CHMODE_*）：0-7 独立（channels=code+1）；
//! 8=left_side / 9=right_side / 10=mid_side（channels=2）；≥11 非法。
//!
//! 本模块只做帧头**内在**校验（sync/reserved/code/CRC-8）；与 STREAMINFO 的
//! 一致性校验（blocksize ≤ max_blocksize、bps/samplerate 归属）在 lib.zig。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const bitreader = @import("bitreader.zig");

const BitReader = bitreader.BitReader;

/// 去相关模式（flac.h FLAC_CHMODE_*）
pub const ChMode = enum(u2) {
    independent = 0,
    left_side = 1,
    right_side = 2,
    mid_side = 3,
};

/// 解析后的帧头信息
pub const FrameHeader = struct {
    is_var_size: bool,
    /// 本帧样本数（16..65536）
    blocksize: u32,
    /// 帧头采样率（0 = 需用 STREAMINFO 值）
    sample_rate: u32,
    /// 声道数（1..8）
    channels: u8,
    ch_mode: ChMode,
    /// 位深（0 = 需用 STREAMINFO 值；否则 8/12/16/20/24/32）
    bps: u8,
    /// UTF-8 帧号（variable-blocksize 时为首样本编号）
    frame_or_sample_num: u64,
};

/// blocksize 表（flacdata.c ff_flac_blocksize_table）
const blocksize_table = [16]u32{ 0, 192, 576, 1152, 2304, 4608, 0, 0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
/// samplerate 表（flacdata.c ff_flac_sample_rate_table）
const sample_rate_table = [16]u32{ 0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000, 0, 0, 0, 0 };
/// bps 表（flac.c sample_size_table）
const sample_size_table = [8]u8{ 0, 8, 12, 0, 16, 20, 24, 32 };

/// 解析一帧帧头。内部自含 CRC-8 作用域（入口清零），调用方保证流位于帧边界。
/// 任一字段非法 → error.Corrupt（含 CRC-8 校验失败）。
pub fn parseHeader(br: *BitReader) Error!FrameHeader {
    br.crc8 = 0; // 帧头 CRC-8 作用域从同步码开始

    // sync(15) + var_size(1)
    const sync = try br.readBits(15);
    if (sync != 0x7FFC) return error.Corrupt;
    const is_var_size = (try br.readBit()) != 0;

    const bs_code: u4 = @intCast(try br.readBits(4));
    const sr_code: u4 = @intCast(try br.readBits(4));
    const ch_code: u4 = @intCast(try br.readBits(4));
    const bps_code: u3 = @intCast(try br.readBits(3));

    // reserved 位必须为 0
    if (try br.readBit() != 0) return error.Corrupt;

    // 声道数 / 去相关（flac.c：<8 独立；8-10 立体声耦合；≥11 非法）
    var channels: u8 = undefined;
    var ch_mode: ChMode = undefined;
    if (ch_code < 8) {
        channels = @intCast(ch_code + 1);
        ch_mode = .independent;
    } else if (ch_code < 11) {
        channels = 2;
        ch_mode = @enumFromInt(ch_code - 7);
    } else {
        return error.Corrupt;
    }

    // 位深（code 3 非法）
    if (bps_code == 3) return error.Corrupt;
    const bps = sample_size_table[bps_code];

    // UTF-8 帧号 / 样本号
    const frame_or_sample_num = try br.readUtf8();

    // blocksize（code 0 非法；6/7 读扩展位）
    var blocksize: u32 = undefined;
    if (bs_code == 0) {
        return error.Corrupt;
    } else if (bs_code == 6) {
        blocksize = (try br.readBits(8)) + 1;
    } else if (bs_code == 7) {
        blocksize = (try br.readBits(16)) + 1;
    } else {
        blocksize = blocksize_table[bs_code];
    }

    // samplerate（code 15 非法；12/13/14 读扩展位）
    var sample_rate: u32 = undefined;
    if (sr_code < 12) {
        sample_rate = sample_rate_table[sr_code];
    } else if (sr_code == 12) {
        sample_rate = (try br.readBits(8)) * 1000;
    } else if (sr_code == 13) {
        sample_rate = try br.readBits(16);
    } else if (sr_code == 14) {
        sample_rate = (try br.readBits(16)) * 10;
    } else {
        return error.Corrupt;
    }

    // CRC-8：读掉 CRC 字节后，累加器应回到 0
    _ = try br.readBits(8);
    if (br.crc8 != 0) return error.Corrupt;

    return .{
        .is_var_size = is_var_size,
        .blocksize = blocksize,
        .sample_rate = sample_rate,
        .channels = channels,
        .ch_mode = ch_mode,
        .bps = bps,
        .frame_or_sample_num = frame_or_sample_num,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;
const io = @import("../../io.zig");
const crc = @import("crc.zig");

/// 测试用 MSB-first 位写入器（按位填充字节，末尾补 CRC-8 并字节对齐）
const TestWriter = struct {
    bytes: std.ArrayList(u8),
    cache: u8 = 0,
    nbits: u8 = 0,

    fn init() TestWriter {
        return .{ .bytes = .empty };
    }
    fn deinit(self: *TestWriter) void {
        self.bytes.deinit(testing.allocator);
    }

    fn appendBits(self: *TestWriter, value: u32, n: u8) !void {
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const bit: u1 = @intCast((value >> @intCast(n - 1 - i)) & 1);
            self.cache = (self.cache << 1) | bit;
            self.nbits += 1;
            if (self.nbits == 8) {
                try self.bytes.append(testing.allocator, self.cache);
                self.cache = 0;
                self.nbits = 0;
            }
        }
    }

    fn padToByte(self: *TestWriter) !void {
        while (self.nbits != 0) try self.appendBits(0, 1);
    }

    /// 追加 CRC-8（对当前全部字节）并字节对齐收尾
    fn finishHeader(self: *TestWriter) !void {
        try self.padToByte();
        try self.bytes.append(testing.allocator, crc.crc8(self.bytes.items));
    }
};

/// 用给定字段编码一帧头（供各测试构造合法/非法输入）
fn encodeHeader(
    allocator: std.mem.Allocator,
    opts: struct {
        var_size: bool = false,
        bs_code: u4 = 12,
        sr_code: u4 = 9,
        ch_code: u4 = 1,
        bps_code: u3 = 4,
        reserved: u1 = 0,
        frame_num: u64 = 0,
        bs_extra: ?u32 = null, // 覆写 bs_code 6/7 扩展位
        sr_extra: ?u32 = null, // 覆写 sr_code 12/13/14 扩展位
        bad_crc: bool = false,
    },
) ![]u8 {
    var w = TestWriter.init();
    defer w.deinit();
    try w.appendBits(0x7FFC, 15);
    try w.appendBits(if (opts.var_size) 1 else 0, 1);
    try w.appendBits(opts.bs_code, 4);
    try w.appendBits(opts.sr_code, 4);
    try w.appendBits(opts.ch_code, 4);
    try w.appendBits(opts.bps_code, 3);
    try w.appendBits(opts.reserved, 1);
    // UTF-8 帧号
    if (opts.frame_num < 0x80) {
        try w.appendBits(@intCast(opts.frame_num), 8);
    } else if (opts.frame_num < 0x800) {
        try w.appendBits(@intCast(0xC0 | (opts.frame_num >> 6)), 8);
        try w.appendBits(@intCast(0x80 | (opts.frame_num & 0x3F)), 8);
    } else if (opts.frame_num < 0x10000) {
        try w.appendBits(@intCast(0xE0 | (opts.frame_num >> 12)), 8);
        try w.appendBits(@intCast(0x80 | ((opts.frame_num >> 6) & 0x3F)), 8);
        try w.appendBits(@intCast(0x80 | (opts.frame_num & 0x3F)), 8);
    } else {
        return error.TestUnexpectedResult;
    }
    // blocksize / samplerate 扩展位
    switch (opts.bs_code) {
        6 => try w.appendBits(opts.bs_extra orelse 200, 8),
        7 => try w.appendBits(opts.bs_extra orelse 0xFFFF, 16),
        else => {},
    }
    switch (opts.sr_code) {
        12 => try w.appendBits(opts.sr_extra orelse 44, 8),
        13 => try w.appendBits(opts.sr_extra orelse 0xAC44, 16),
        14 => try w.appendBits(opts.sr_extra orelse 3000, 16),
        else => {},
    }
    try w.padToByte();
    const crc_val = crc.crc8(w.bytes.items);
    if (opts.bad_crc) {
        // 故意写错 CRC：对计算值异或一个位
        try w.bytes.append(allocator, crc_val ^ 0x01);
    } else {
        try w.bytes.append(allocator, crc_val);
    }
    return w.bytes.toOwnedSlice(allocator);
}

fn parseHeaderBytes(bytes: []const u8) !FrameHeader {
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    return try parseHeader(&br);
}

test "frame: 基本帧头（stereo/44100/16bit/blocksize 4096/帧号 0）" {
    const bytes = try encodeHeader(testing.allocator, .{});
    defer testing.allocator.free(bytes);
    const hdr = try parseHeaderBytes(bytes);
    try testing.expectEqual(@as(bool, false), hdr.is_var_size);
    try testing.expectEqual(@as(u32, 4096), hdr.blocksize);
    try testing.expectEqual(@as(u32, 44100), hdr.sample_rate);
    try testing.expectEqual(@as(u8, 2), hdr.channels);
    try testing.expectEqual(ChMode.independent, hdr.ch_mode);
    try testing.expectEqual(@as(u8, 16), hdr.bps);
    try testing.expectEqual(@as(u64, 0), hdr.frame_or_sample_num);
}

test "frame: 多声道独立 + var_size + 8bit blocksize + 12 采样率 + 24bit + 3 字节 UTF-8" {
    const bytes = try encodeHeader(testing.allocator, .{
        .var_size = true,
        .bs_code = 6,
        .sr_code = 12,
        .ch_code = 5, // 6 声道独立
        .bps_code = 6, // 24 bit（表索引 6）
        .frame_num = 0xABCD,
        .bs_extra = 200, // blocksize = 201
        .sr_extra = 44, // 44000 Hz
    });
    defer testing.allocator.free(bytes);
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    const hdr = try parseHeader(&br);
    try testing.expectEqual(@as(bool, true), hdr.is_var_size);
    try testing.expectEqual(@as(u32, 201), hdr.blocksize);
    try testing.expectEqual(@as(u32, 44000), hdr.sample_rate);
    try testing.expectEqual(@as(u8, 6), hdr.channels);
    try testing.expectEqual(@as(u8, 24), hdr.bps);
    try testing.expectEqual(@as(u64, 0xABCD), hdr.frame_or_sample_num);
}

test "frame: mid_side 立体声 + blocksize 16bit + 13/14 采样率" {
    // mid_side（ch_code 10 → ch_mode mid_side）+ bs_code 7（blocksize 65536）
    {
        const bytes = try encodeHeader(testing.allocator, .{
            .bs_code = 7,
            .sr_code = 13,
            .ch_code = 10,
            .bs_extra = 0xFFFF, // 65536
            .sr_extra = 44100, // 直接 16 位
        });
        defer testing.allocator.free(bytes);
        var r = io.Reader.openMem(bytes);
        var br = BitReader.init(&r);
        const hdr = try parseHeader(&br);
        try testing.expectEqual(@as(u32, 65536), hdr.blocksize);
        try testing.expectEqual(@as(u32, 44100), hdr.sample_rate);
        try testing.expectEqual(@as(u8, 2), hdr.channels);
        try testing.expectEqual(ChMode.mid_side, hdr.ch_mode);
    }
    // left_side + sr_code 14（*10）
    {
        const bytes = try encodeHeader(testing.allocator, .{
            .sr_code = 14,
            .ch_code = 8,
            .sr_extra = 3000, // 30000 Hz
        });
        defer testing.allocator.free(bytes);
        var r = io.Reader.openMem(bytes);
        var br = BitReader.init(&r);
        const hdr = try parseHeader(&br);
        try testing.expectEqual(@as(u32, 30000), hdr.sample_rate);
        try testing.expectEqual(ChMode.left_side, hdr.ch_mode);
    }
}

test "frame: 2 字节 UTF-8 帧号" {
    const bytes = try encodeHeader(testing.allocator, .{ .frame_num = 0x800 });
    defer testing.allocator.free(bytes);
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    const hdr = try parseHeader(&br);
    try testing.expectEqual(@as(u64, 0x800), hdr.frame_or_sample_num);
}

test "frame: 非法输入 → Corrupt" {
    try expectCorrupt(try makeHeaderWithBadSync());
    try expectCorrupt(try encodeHeader(testing.allocator, .{ .reserved = 1 }));
    try expectCorrupt(try encodeHeader(testing.allocator, .{ .ch_code = 11 }));
    try expectCorrupt(try encodeHeader(testing.allocator, .{ .bps_code = 3 }));
    try expectCorrupt(try encodeHeader(testing.allocator, .{ .bs_code = 0 }));
    try expectCorrupt(try encodeHeader(testing.allocator, .{ .sr_code = 15 }));
    try expectCorrupt(try encodeHeader(testing.allocator, .{ .bad_crc = true }));
}

fn makeHeaderWithBadSync() ![]u8 {
    var w = TestWriter.init();
    defer w.deinit();
    try w.appendBits(0x7FFD, 15); // 错误同步码
    try w.appendBits(0, 1);
    try w.appendBits(12, 4);
    try w.appendBits(9, 4);
    try w.appendBits(1, 4);
    try w.appendBits(4, 3);
    try w.appendBits(0, 1);
    try w.appendBits(0, 8); // 帧号 0
    try w.padToByte();
    try w.bytes.append(testing.allocator, crc.crc8(w.bytes.items));
    return w.bytes.toOwnedSlice(testing.allocator);
}

fn expectCorrupt(bytes: []u8) !void {
    defer testing.allocator.free(bytes);
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    try testing.expectError(error.Corrupt, parseHeader(&br));
}

test "frame: 帧头解析后位置恰在帧头末尾（含 CRC-8 字节）" {
    const bytes = try encodeHeader(testing.allocator, .{});
    defer testing.allocator.free(bytes);
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    _ = try parseHeader(&br);
    try testing.expectEqual(@as(u64, bytes.len), r.pos);
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! APE 容器解析（docs/audio-kernel-zig.md §9.10）
//!
//! 参考重构对照 FFmpeg libavformat/ape.c 的 ape_read_header：MAC 描述符 /
//! 头部 / seektable / bittable / 帧表推导（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 布局（两个版本分支）：
//!   - version >= 3980：描述符（padding1 u16 / descriptorlength u32 /
//!     headerlength u32 / seektablelength u32 / wavheaderlength u32 /
//!     audiodatalength u32 / audiodatalength_high u32 / wavtaillength u32 /
//!     md5[16]）+ 头部（compressiontype / formatflags / blocksperframe /
//!     finalframeblocks / totalframes / bps / channels / samplerate）；
//!   - version < 3980：紧凑头部（compressiontype / formatflags / channels /
//!     samplerate / wavheaderlength / wavtaillength / totalframes /
//!     finalframeblocks）+ 可选 peak level / seek elements + 可选内嵌 WAV 头。
//!
//! 帧表：seektable 偏移 + 帧长推导；version < 3810 另有每帧 1 字节 bittable。
//! 总样本数 = blocksperframe·(totalframes-1) + finalframeblocks。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");

const APE_MIN_VERSION = 3800;
const APE_MAX_VERSION = 3990;

/// 单帧定位（数据段均为文件绝对偏移）
pub const Frame = struct {
    pos: u64 = 0,
    size: u64 = 0,
    nblocks: u32 = 0,
    /// < 3810：位（bittable 追加）；>= 3810：字节（帧对齐偏移 0..3）
    skip: u32 = 0,
};

pub const Header = struct {
    fileversion: u32,
    compression_level: u32,
    formatflags: u32,
    bps: u32,
    channels: u32,
    samplerate: u32,
    blocksperframe: u32,
    finalframeblocks: u32,
    totalframes: u32,
    total_samples: u64,
    frames: []Frame,
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn readU16(self: *Cursor) ?u16 {
        if (self.pos + 2 > self.data.len) return null;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *Cursor) ?u32 {
        if (self.pos + 4 > self.data.len) return null;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn skip(self: *Cursor, n: usize) bool {
        if (self.pos + n > self.data.len) return false;
        self.pos += n;
        return true;
    }
};

/// 解析文件头与帧表。`frames` 为 allocator 分配的数组（调用方 deinit 释放）。
pub fn parse(allocator: std.mem.Allocator, reader: *io.Reader) Error!Header {
    var head: [4096]u8 = undefined;
    const n = try reader.peek(&head);
    if (n < 6) return error.Corrupt;
    const h = head[0..n];
    if (!std.mem.eql(u8, h[0..4], "MAC ")) return error.UnsupportedFormat;

    var c = Cursor{ .data = h, .pos = 4 };
    const fileversion = (c.readU16() orelse return error.Corrupt);
    if (fileversion < APE_MIN_VERSION or fileversion > APE_MAX_VERSION) return error.UnsupportedFormat;

    var compression_level: u32 = 0;
    var formatflags: u32 = 0;
    var bps: u32 = 0;
    var channels: u32 = 0;
    var samplerate: u32 = 0;
    var blocksperframe: u32 = 0;
    var finalframeblocks: u32 = 0;
    var totalframes: u32 = 0;
    var wavheaderlength: u32 = 0;
    var wavtaillength: u32 = 0;
    var seektablelength: u32 = 0;
    var seektable_off: usize = 0;
    var firstframe: usize = 0;

    if (fileversion >= 3980) {
        // 描述符
        _ = (c.readU16() orelse return error.Corrupt); // padding1
        const descriptorlength = (c.readU32() orelse return error.Corrupt);
        const headerlength = (c.readU32() orelse return error.Corrupt);
        seektablelength = (c.readU32() orelse return error.Corrupt);
        wavheaderlength = (c.readU32() orelse return error.Corrupt);
        _ = (c.readU32() orelse return error.Corrupt); // audiodatalength
        _ = (c.readU32() orelse return error.Corrupt); // audiodatalength_high
        wavtaillength = (c.readU32() orelse return error.Corrupt);
        if (!c.skip(16)) return error.Corrupt; // md5
        if (descriptorlength > 52) {
            if (!c.skip(descriptorlength - 52)) return error.Corrupt;
        }
        // 头部
        compression_level = (c.readU16() orelse return error.Corrupt);
        formatflags = (c.readU16() orelse return error.Corrupt);
        blocksperframe = (c.readU32() orelse return error.Corrupt);
        finalframeblocks = (c.readU32() orelse return error.Corrupt);
        totalframes = (c.readU32() orelse return error.Corrupt);
        bps = (c.readU16() orelse return error.Corrupt);
        channels = (c.readU16() orelse return error.Corrupt);
        samplerate = (c.readU32() orelse return error.Corrupt);
        seektable_off = descriptorlength + headerlength;
        // 描述符格式：seektable 之后才是内嵌 WAV 头
        firstframe = seektable_off + seektablelength + wavheaderlength;
    } else {
        compression_level = (c.readU16() orelse return error.Corrupt);
        formatflags = (c.readU16() orelse return error.Corrupt);
        channels = (c.readU16() orelse return error.Corrupt);
        samplerate = (c.readU32() orelse return error.Corrupt);
        wavheaderlength = (c.readU32() orelse return error.Corrupt);
        wavtaillength = (c.readU32() orelse return error.Corrupt);
        totalframes = (c.readU32() orelse return error.Corrupt);
        finalframeblocks = (c.readU32() orelse return error.Corrupt);

        if ((formatflags & 1) != 0) {
            bps = 8;
        } else if ((formatflags & 8) != 0) {
            bps = 24;
        } else {
            bps = 16;
        }

        if (fileversion >= 3950) {
            blocksperframe = 73728 * 4;
        } else if (fileversion >= 3900 or (fileversion >= 3800 and compression_level >= 4000)) {
            blocksperframe = 73728;
        } else {
            blocksperframe = 9216;
        }

        if ((formatflags & 4) != 0) {
            if (!c.skip(4)) return error.Corrupt; // peak level
        }
        if ((formatflags & 16) != 0) {
            const seekelements = (c.readU32() orelse return error.Corrupt);
            seektablelength = seekelements * 4;
        } else {
            seektablelength = totalframes * 4;
        }

        // 内嵌 WAV 头（未置 CREATE_WAV_HEADER 时）位于头部之后、seektable 之前
        seektable_off = if ((formatflags & 32) == 0) c.pos + wavheaderlength else c.pos;
        firstframe = c.pos + seektablelength + wavheaderlength;
    }

    if (totalframes == 0) return error.Corrupt;
    if (seektablelength / 4 < totalframes) return error.Corrupt;

    // < 3810 的 bittable 位于 seektable 之后、首帧之前（每帧 1 字节）
    const bittable_off: usize = seektable_off + seektablelength;
    if (fileversion < 3810) firstframe += totalframes;

    const frames = try allocator.alloc(Frame, totalframes);
    errdefer allocator.free(frames);
    for (frames) |*f| f.* = .{};

    frames[0].pos = firstframe;
    frames[0].nblocks = blocksperframe;

    // 读 seektable（首项占位丢弃）
    {
        try reader.seek(@intCast(seektable_off), .start);
        var ebuf: [4]u8 = undefined;
        var i: usize = 0;
        while (i < totalframes) : (i += 1) {
            const g = try reader.read(&ebuf);
            if (g < 4) return error.Corrupt;
            const entry: u32 = std.mem.readInt(u32, &ebuf, .little);
            if (i == 0) continue; // seektable[0] 丢弃
            frames[i].pos = entry;
            frames[i].nblocks = blocksperframe;
            frames[i - 1].size = frames[i].pos - frames[i - 1].pos;
            frames[i].skip = @intCast((frames[i].pos - frames[0].pos) & 3);
        }
    }

    frames[totalframes - 1].nblocks = finalframeblocks;

    // 末帧大小：由文件总长推导
    {
        const file_size = try reader.size();
        var final_size: u64 = 0;
        if (file_size > 0) {
            final_size = file_size -% frames[totalframes - 1].pos -% wavtaillength;
            final_size -%= final_size & 3;
        }
        if (file_size == 0 or final_size == 0 or final_size > file_size) {
            final_size = @as(u64, finalframeblocks) * 8;
        }
        frames[totalframes - 1].size = final_size;
    }

    // 帧定位修正（对齐 FFmpeg：skip 回退 + 4 字节对齐）
    for (frames) |*f| {
        if (f.skip != 0) {
            f.pos -%= f.skip;
            f.size +%= f.skip;
        }
        f.size = (f.size + 3) & ~@as(u64, 3);
    }

    // bittable（< 3810）：每帧 1 字节，追加到上一帧与 bit 偏移
    if (fileversion < 3810) {
        try reader.seek(@intCast(bittable_off), .start);
        var i: usize = 0;
        while (i < totalframes) : (i += 1) {
            var b: [1]u8 = undefined;
            const g = try reader.read(&b);
            if (g < 1) return error.Corrupt;
            const bits: u32 = b[0];
            if (i != 0 and bits != 0) frames[i - 1].size +%= 4;
            frames[i].skip = (frames[i].skip << 3) + bits;
        }
    }

    var total_samples: u64 = finalframeblocks;
    if (totalframes > 1) total_samples +%= @as(u64, blocksperframe) * (totalframes - 1);

    return .{
        .fileversion = fileversion,
        .compression_level = compression_level,
        .formatflags = formatflags,
        .bps = bps,
        .channels = channels,
        .samplerate = samplerate,
        .blocksperframe = blocksperframe,
        .finalframeblocks = finalframeblocks,
        .totalframes = totalframes,
        .total_samples = total_samples,
        .frames = frames,
    };
}

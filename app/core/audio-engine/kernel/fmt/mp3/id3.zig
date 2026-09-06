// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ID3 标签解析（ID3v2.2 / v2.3 / v2.4 + ID3v1）—— MP3 元数据
//!
//! 对齐 FFmpeg av_dict 语义（参考 id3v2.c / id3v1.c）：
//!   - ID3v2 帧 → Metadata 标准字段 + 通用 tags（含 TXXX / TPE2 / TRCK 等
//!     全部保留，重复键全保留，key 原样大小写）；
//!   - TXXX REPLAYGAIN_* → ReplayGain（单位对齐 AVReplayGain：
//!     gain 0.001dB / peak 0.00001）；
//!   - APIC → Picture（mime / description / 图片数据）；
//!   - ID3v1 文件尾 → 标准字段（若 ID3v2 未覆盖）。
//!
//! 内存契约：open 时经 parse 分配全部字段（NUL 终止 / 零长 slice），
//! 生命周期与 Decoder 一致，由 freeMeta / freePictures 释放。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");

const Allocator = std.mem.Allocator;
const Reader = io.Reader;

const max_tag_text: u64 = 4096;
const max_picture_data: u64 = 64 * 1024 * 1024;

/// ID3v2 标签头（10 字节）解析结果
pub const V2Header = struct {
    /// 帧体（标签头之后）大小
    size: u64,
    /// 帧格式版本（2 / 3 / 4）
    major: u8,
    /// 标签起始（ID3 位置）
    start: u64,
    /// 标签结束（文件偏移）
    end: u64,
};

/// 解析 ID3v2 头。无 ID3v2 → null。损坏（大小异常）→ error.Corrupt。
/// 返回标签区（含头）结束偏移。
pub fn parseV2Header(reader: *Reader, start: u64) Error!?V2Header {
    try reader.seek(@intCast(start), .start);
    var head: [10]u8 = undefined;
    const n = try reader.read(&head);
    if (n < 10 or !std.mem.eql(u8, head[0..3], "ID3")) return null;
    if (head[3] == 0xFF or (head[6] & 0x80) != 0 or
        (head[7] & 0x80) != 0 or (head[8] & 0x80) != 0 or (head[9] & 0x80) != 0)
    {
        return error.Corrupt;
    }
    const major = head[3];
    if (major != 2 and major != 3 and major != 4) return error.Corrupt;
    const flags = head[5];
    const size: u64 = syncsafe(head[6..10]);
    var end = start + 10 + size;
    // v2.4 扩展头 + 标签脚注（footer flag 0x10）：footer 加 10 字节
    if (major == 4 and (flags & 0x10) != 0) end += 10;
    return .{ .size = size, .major = major, .start = start, .end = end };
}

/// 解析全部 ID3v2 帧 → Metadata / tags / pictures / replay_gain。
/// reader 定位于标签头；返回标签后偏移（音频起点）。无标签 → 返回 start。
pub fn parseV2(
    reader: *Reader,
    allocator: Allocator,
    start: u64,
    meta: *decoder.Metadata,
    pics: *[]decoder.Picture,
    rg: *decoder.ReplayGain,
) Error!u64 {
    const hdr = (try parseV2Header(reader, start)) orelse return start;
    if (hdr.size == 0) return hdr.end;

    // 跳过扩展头
    var pos = start + 10;
    if (hdr.major == 3 or hdr.major == 4) {
        // 扩展头标志位于标签头第 6 字节（flags）
        try reader.seek(@intCast(start + 5), .start);
        var flag_byte: [1]u8 = undefined;
        _ = try reader.read(&flag_byte);
        if (flag_byte[0] & 0x40 != 0) { // 扩展头存在
            try reader.seek(@intCast(pos), .start);
            var ext: [4]u8 = undefined;
            const r = try reader.read(&ext);
            if (r < 4) return hdr.end;
            const ext_size: u64 = if (hdr.major == 4) syncsafe(&ext) else bigEndianU32(&ext);
            // 对齐 v2.3 语义：v2.3 的 ext_size 含自身 4 字节；v2.4 不含
            const skip = if (hdr.major == 4) ext_size else ext_size - 4;
            pos += 4 + skip;
        } else {
            pos = start + 10;
        }
    }

    var pictures: std.ArrayList(decoder.Picture) = .empty;
    errdefer {
        for (pictures.items) |*p| freePicture(allocator, p);
        pictures.deinit(allocator);
    }
    var tags: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (tags.items) |*t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }

    var frame_start = pos;
    while (frame_start + 10 <= hdr.end) {
        try reader.seek(@intCast(frame_start), .start);
        var frame_hdr: [10]u8 = undefined;
        const r = try reader.read(&frame_hdr);
        if (r < 10) break;
        // 帧结束填充（0x00）或帧头不可识别 → 停止
        if (frame_hdr[0] == 0) break;

        const frame_id = frame_hdr[0..4];
            var body_size: u64 = undefined;
        var frame_flags: [2]u8 = undefined;
        var next: u64 = undefined;
        if (hdr.major == 2) {
            // v2.2：3 字节 ID + 3 字节 BE 大小
            const id3 = frame_hdr[0..3];
            body_size = (@as(u64, frame_hdr[3]) << 16) | (@as(u64, frame_hdr[4]) << 8) | frame_hdr[5];
            frame_flags = .{ 0, 0 };
            next = frame_start + 6 + body_size;
            parseFrame2(reader, allocator, id3, body_size, meta, &tags, rg, &pictures) catch {};
        } else {
            body_size = if (hdr.major == 4) syncsafe(frame_hdr[4..8]) else bigEndianU32(frame_hdr[4..8]);
            frame_flags = .{ frame_hdr[8], frame_hdr[9] };
            // v2.4 数据长度指示符（0x01 标志）占用 4 字节 body 前缀
            var body = frame_start + 10;
            if (hdr.major == 4 and (frame_flags[0] & 0x01) != 0) {
                if (body_size < 4) break;
                body += 4;
                body_size -= 4;
            }
            // v2.4 组标志（0x40）附带 1 字节组标识
            if (hdr.major == 4 and (frame_flags[0] & 0x40) != 0) {
                if (body_size < 1) break;
                body += 1;
                body_size -= 1;
            }
            next = body + body_size;
            // 解压标志（v2.3 0x80 / v2.4 0x08）不支持 → 跳过帧
            const compressed = (hdr.major == 4 and (frame_flags[0] & 0x08) != 0) or
                (hdr.major == 3 and (frame_flags[0] & 0x80) != 0);
            if (!compressed) {
                parseFrame34(reader, allocator, hdr.major, frame_id, body, body_size, meta, &tags, rg, &pictures) catch {};
            }
        }
        if (next <= frame_start or next > hdr.end) break;
        frame_start = next;
    }

    // 转移图片与通用标签
    if (pictures.items.len > 0) {
        pics.* = try pictures.toOwnedSlice(allocator);
    }
    meta.tags = try tags.toOwnedSlice(allocator);
    return hdr.end;
}

/// 解析单个 v2.2 帧（3 字节帧 ID）
fn parseFrame2(
    reader: *Reader,
    allocator: Allocator,
    id: []const u8,
    body_size: u64,
    meta: *decoder.Metadata,
    tags: *std.ArrayList(decoder.Tag),
    rg: *decoder.ReplayGain,
    pics: *std.ArrayList(decoder.Picture),
) Error!void {
    const body = (try readFrameBody(reader, allocator, body_size)) orelse return;
    defer allocator.free(body);
    if (body.len == 0) return;

    // v2.2 → v2.3 帧 ID 映射
    var id34: [4]u8 = v22ToV23(id);
    const id34_s: []const u8 = &id34;
    if (std.mem.eql(u8, id, "PIC")) {
        parseApic(allocator, body, pics) catch {};
        return;
    }
    if (std.mem.eql(u8, id, "TXX")) {
        parseTxxx(allocator, body, tags, rg) catch {};
        return;
    }
    parseTextFrame(allocator, id34_s, body, meta, tags, rg) catch {};
}

/// 解析单个 v2.3 / v2.4 帧（4 字节帧 ID）
fn parseFrame34(
    reader: *Reader,
    allocator: Allocator,
    major: u8,
    id: []const u8,
    body: u64,
    body_size: u64,
    meta: *decoder.Metadata,
    tags: *std.ArrayList(decoder.Tag),
    rg: *decoder.ReplayGain,
    pics: *std.ArrayList(decoder.Picture),
) Error!void {
    _ = major;
    // 读帧体（读前 seek 到 body）
    try reader.seek(@intCast(body), .start);
    const buf = allocator.alloc(u8, @intCast(@min(body_size, max_tag_text))) catch return;
    defer allocator.free(buf);
    var got: usize = 0;
    while (got < buf.len) {
        const r = try reader.read(buf[got..]);
        if (r == 0) break;
        got += r;
    }
    const data = buf[0..got];
    if (data.len == 0) return;

    if (std.mem.eql(u8, id, "APIC")) {
        parseApic(allocator, data, pics) catch {};
        return;
    }
    if (std.mem.eql(u8, id, "TXXX")) {
        parseTxxx(allocator, data, tags, rg) catch {};
        return;
    }
    // 文本帧（T*** / COMM / USLT 等）→ 标准字段 / tags
    parseTextFrame(allocator, id, data, meta, tags, rg) catch {};
}

/// 读取帧体到堆缓冲（长度 clamp 到 max_tag_text；剩余 seek 跳过）
fn readFrameBody(reader: *Reader, allocator: Allocator, len: u64) Error!?[]u8 {
    const n: usize = @intCast(@min(len, max_tag_text));
    if (n == 0) return &.{};
    const buf = allocator.alloc(u8, n) catch return error.OutOfMemory;
    var got: usize = 0;
    while (got < n) {
        const r = reader.read(buf[got..]) catch {
            allocator.free(buf);
            return null;
        };
        if (r == 0) break;
        got += r;
    }
    if (len > got) reader.seek(@intCast(len - got), .current) catch {};
    return buf[0..got];
}

/// 文本帧 → 标准字段 / 通用 tags。兼容 ID3v2.3（前 1 字节编码）+ v2.4（无编码字节）。
fn parseTextFrame(
    allocator: Allocator,
    id: []const u8,
    data: []const u8,
    meta: *decoder.Metadata,
    tags: *std.ArrayList(decoder.Tag),
    rg: *decoder.ReplayGain,
) Error!void {
    _ = rg;
    var content = data;
    var enc: u8 = 0;
    if (content.len >= 1 and content[0] <= 3) {
        enc = content[0];
        content = content[1..];
    }
    if (content.len == 0) return;

    // COMM 帧：语言(3) + 简短描述(0 终止) + 实际文本
    if (std.mem.eql(u8, id, "COMM")) {
        if (content.len < 4) return;
        const desc_end = terminatorIndex(content[3..], enc) orelse return;
        content = content[3 + desc_end + terminatorLen(enc) ..];
        if (content.len == 0) return;
    }

    const value_raw = decodeText(allocator, enc, content) catch return;
    defer allocator.free(value_raw);
    const value = std.mem.trimEnd(u8, value_raw, "\x00");
    if (value.len == 0) return;

    // 通用条目全量保留（含标准字段键，重复键全保留）
    const k = allocator.dupe(u8, id) catch return;
    errdefer allocator.free(k);
    const v = allocator.dupe(u8, value) catch return;
    errdefer allocator.free(v);
    tags.append(allocator, .{ .key = k, .value = v }) catch return;

    // 标准字段映射（首字段优先）
    const field = id3TextField(id) orelse return;
    const s = allocator.dupeZ(u8, value) catch return;
    if (!setMetaField(meta, field, s)) allocator.free(s);
}

/// TXXX 帧（描述 + 值，均为编码文本）
fn parseTxxx(
    allocator: Allocator,
    data: []const u8,
    tags: *std.ArrayList(decoder.Tag),
    rg: *decoder.ReplayGain,
) Error!void {
    if (data.len < 2) return;
    const enc = data[0];
    // 描述以 0 终止（可能 1 或 2 字节，取决于编码）
    const desc_end = terminatorIndex(data[1..], enc) orelse return;
    const desc_raw = data[1 .. 1 + desc_end];
    const value_raw = data[1 + desc_end + terminatorLen(enc) ..];
    const desc = decodeText(allocator, enc, desc_raw) catch return;
    defer allocator.free(desc);
    const value = decodeText(allocator, enc, value_raw) catch return;
    defer allocator.free(value);
    if (value.len == 0 or desc.len == 0) return;

    // 通用条目（描述=key）
    const k = allocator.dupe(u8, desc) catch return;
    errdefer allocator.free(k);
    const v = allocator.dupe(u8, value) catch return;
    errdefer allocator.free(v);
    tags.append(allocator, .{ .key = k, .value = v }) catch return;

    // REPLAYGAIN_* → rg
    if (std.ascii.eqlIgnoreCase(desc, "REPLAYGAIN_TRACK_GAIN")) {
        rg.track_gain = parseGainDb(value) orelse rg.track_gain;
    } else if (std.ascii.eqlIgnoreCase(desc, "REPLAYGAIN_TRACK_PEAK")) {
        rg.track_peak = parsePeak(value) orelse rg.track_peak;
    } else if (std.ascii.eqlIgnoreCase(desc, "REPLAYGAIN_ALBUM_GAIN")) {
        rg.album_gain = parseGainDb(value) orelse rg.album_gain;
    } else if (std.ascii.eqlIgnoreCase(desc, "REPLAYGAIN_ALBUM_PEAK")) {
        rg.album_peak = parsePeak(value) orelse rg.album_peak;
    }
}

/// APIC 帧 → Picture
fn parseApic(allocator: Allocator, data: []const u8, pics: *std.ArrayList(decoder.Picture)) Error!void {
    if (data.len < 4) return;
    const enc = data[0];
    // MIME（0 终止；v2.2 用 3 字符类型）
    const mime_end = std.mem.indexOfScalar(u8, data[1..], 0) orelse return;
    if (mime_end == 0) return;
    const mime = allocator.dupe(u8, data[1 .. 1 + mime_end]) catch return;
    errdefer allocator.free(mime);
    var off = 1 + mime_end + 1;
    if (off >= data.len) return;
    const pic_type = data[off];
    off += 1;
    const desc_end = terminatorIndex(data[off..], enc) orelse return;
    const desc = decodeText(allocator, enc, data[off .. off + desc_end]) catch return;
    errdefer allocator.free(desc);
    off += desc_end + terminatorLen(enc);
    if (off >= data.len) return;
    const img = allocator.dupe(u8, data[off..]) catch return;
    errdefer allocator.free(img);

    pics.append(allocator, .{
        .picture_type = pic_type,
        .mime = mime,
        .description = desc,
        .data = img,
    }) catch return;
}

/// ID3v1 文件尾标签解析（128 字节：TAG + 30 标题 + 30 艺术家 + 30 专辑 + 4 年 + 30 注释 + 1 流派）
/// 仅填充未被 ID3v2 覆盖的标准字段。
pub fn parseV1(reader: *Reader, allocator: Allocator, file_size: u64, meta: *decoder.Metadata) Error!void {
    if (file_size < 128) return;
    const off = file_size - 128;
    try reader.seek(@intCast(off), .start);
    var tag: [128]u8 = undefined;
    const n = try reader.read(&tag);
    if (n < 128 or !std.mem.eql(u8, tag[0..3], "TAG")) return;

    try setV1Field(allocator, meta, .title, tag[3..33]);
    try setV1Field(allocator, meta, .artist, tag[33..63]);
    try setV1Field(allocator, meta, .album, tag[63..93]);
    // 年份 93..97
    const year = std.mem.trimEnd(u8, tag[93..97], "\x00");
    if (year.len > 0 and meta.date == null) {
        meta.date = allocator.dupeZ(u8, year) catch return;
    }
    // 注释 97..127（v1.1 末 2 字节为 track+0，注释有效 28 字节）
    try setV1Field(allocator, meta, .comment, tag[97..125]);
}

fn setV1Field(allocator: Allocator, meta: *decoder.Metadata, field: MetaField, raw: []const u8) Error!void {
    if (fieldOccupied(meta, field)) return;
    const s = std.mem.trimEnd(u8, raw, "\x00 \t");
    if (s.len == 0) return;
    const d = allocator.dupeZ(u8, s) catch return error.OutOfMemory;
    if (!setMetaField(meta, field, d)) allocator.free(d);
}

// ---------------------------------------------------------------------------
// 编码解码（ID3v2 文本：0=Latin-1, 1=UTF-16 BOM, 2=UTF-16BE, 3=UTF-8）
// ---------------------------------------------------------------------------

/// 解码 ID3v2 文本到 UTF-8（分配堆缓冲）。失败 → 返回原样（Latin-1 近似）。
fn decodeText(allocator: Allocator, enc: u8, data: []const u8) Error![]u8 {
    switch (enc) {
        3 => return allocator.dupe(u8, data), // UTF-8
        0 => {
            // Latin-1 → UTF-8（逐字节展开）
            const out = allocator.alloc(u8, data.len) catch return error.OutOfMemory;
            // Latin-1 字符 > 0x7F 需 2 字节；保守分配 data.len*2
            const out2 = allocator.alloc(u8, data.len * 2) catch return error.OutOfMemory;
            var oi: usize = 0;
            for (data) |b| {
                if (b < 0x80) {
                    out2[oi] = b;
                    oi += 1;
                } else {
                    out2[oi] = 0xC0 | (b >> 6);
                    out2[oi + 1] = 0x80 | (b & 0x3F);
                    oi += 2;
                }
            }
            allocator.free(out);
            return out2[0..oi];
        },
        1, 2 => {
            // UTF-16（enc=1 带 BOM）→ UTF-8
            var utf16 = data;
            var be = enc == 2;
            if (enc == 1 and utf16.len >= 2) {
                if (utf16[0] == 0xFF and utf16[1] == 0xFE) {
                    be = false;
                    utf16 = utf16[2..];
                } else if (utf16[0] == 0xFE and utf16[1] == 0xFF) {
                    be = true;
                    utf16 = utf16[2..];
                }
            }
            if (utf16.len % 2 != 0) utf16 = utf16[0 .. utf16.len - 1];
            // 预计算 UTF-8 大小
            var need: usize = 0;
            var i: usize = 0;
            while (i + 1 < utf16.len) : (i += 2) {
                const unit: u16 = if (be)
                    (@as(u16, utf16[i]) << 8) | utf16[i + 1]
                else
                    (@as(u16, utf16[i + 1]) << 8) | utf16[i];
                if (unit == 0) break; // 终止符
                if (unit < 0x80) need += 1 else if (unit < 0x800) need += 2 else need += 3;
            }
            const out = allocator.alloc(u8, need) catch return error.OutOfMemory;
            var oi: usize = 0;
            i = 0;
            while (i + 1 < utf16.len) : (i += 2) {
                const unit: u16 = if (be)
                    (@as(u16, utf16[i]) << 8) | utf16[i + 1]
                else
                    (@as(u16, utf16[i + 1]) << 8) | utf16[i];
                if (unit == 0) break;
                if (unit < 0x80) {
                    out[oi] = @intCast(unit);
                    oi += 1;
                } else if (unit < 0x800) {
                    out[oi] = @intCast(0xC0 | (unit >> 6));
                    out[oi + 1] = @intCast(0x80 | (unit & 0x3F));
                    oi += 2;
                } else {
                    out[oi] = @intCast(0xE0 | (unit >> 12));
                    out[oi + 1] = @intCast(0x80 | ((unit >> 6) & 0x3F));
                    out[oi + 2] = @intCast(0x80 | (unit & 0x3F));
                    oi += 3;
                }
            }
            return out[0..oi];
        },
        else => return allocator.dupe(u8, data),
    }
}

fn terminatorIndex(data: []const u8, enc: u8) ?usize {
    switch (enc) {
        1, 2 => {
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                if (data[i] == 0 and data[i + 1] == 0) return i;
            }
            return null;
        },
        else => return std.mem.indexOfScalar(u8, data, 0),
    }
}

fn terminatorLen(enc: u8) usize {
    return if (enc == 1 or enc == 2) 2 else 1;
}

// ---------------------------------------------------------------------------
// 字段映射 / 内存管理
// ---------------------------------------------------------------------------

const MetaField = enum { title, artist, album, date, genre, comment };

fn id3TextField(id: []const u8) ?MetaField {
    if (std.mem.eql(u8, id, "TIT2")) return .title;
    if (std.mem.eql(u8, id, "TPE1")) return .artist;
    if (std.mem.eql(u8, id, "TALB")) return .album;
    if (std.mem.eql(u8, id, "TYER") or std.mem.eql(u8, id, "TDRC")) return .date;
    if (std.mem.eql(u8, id, "TCON")) return .genre;
    if (std.mem.eql(u8, id, "COMM")) return .comment;
    return null;
}

fn v22ToV23(id3: []const u8) [4]u8 {
    return .{ id3[0], id3[1], id3[2], ' ' };
}

fn fieldOccupied(meta: *decoder.Metadata, field: MetaField) bool {
    return switch (field) {
        .title => meta.title != null,
        .artist => meta.artist != null,
        .album => meta.album != null,
        .date => meta.date != null,
        .genre => meta.genre != null,
        .comment => meta.comment != null,
    };
}

fn setMetaField(meta: *decoder.Metadata, field: MetaField, s: [:0]const u8) bool {
    if (fieldOccupied(meta, field)) return false;
    switch (field) {
        .title => meta.title = s,
        .artist => meta.artist = s,
        .album => meta.album = s,
        .date => meta.date = s,
        .genre => meta.genre = s,
        .comment => meta.comment = s,
    }
    return true;
}

/// 释放标签元数据全部字段（与 lib.zig deinit 共用）
pub fn freeMeta(allocator: Allocator, meta: *decoder.Metadata) void {
    inline for (.{ &meta.title, &meta.artist, &meta.album, &meta.date, &meta.genre, &meta.comment }) |f| {
        if (f.*) |s| {
            allocator.free(s);
            f.* = null;
        }
    }
    if (meta.tags.len > 0) {
        for (meta.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        allocator.free(meta.tags);
        meta.tags = &.{};
    }
}

/// 释放单个 Picture 的动态字段
fn freePicture(allocator: Allocator, pic: *decoder.Picture) void {
    if (pic.mime.len > 0) allocator.free(pic.mime);
    if (pic.description.len > 0) allocator.free(pic.description);
    if (pic.data.len > 0) allocator.free(pic.data);
    pic.* = .{};
}

/// 释放图片数组
pub fn freePictures(allocator: Allocator, pics: *[]decoder.Picture) void {
    for (pics.*) |*p| freePicture(allocator, p);
    if (pics.*.len > 0) {
        allocator.free(pics.*);
        pics.* = &.{};
    }
}

// ---------------------------------------------------------------------------
// ReplayGain 解析（单位对齐 AVReplayGain：gain 0.001dB / peak 0.00001）
// ---------------------------------------------------------------------------

fn parseGainDb(s: []const u8) ?i32 {
    var buf = std.mem.trim(u8, s, " \t");
    if (buf.len == 0) return null;
    if (std.ascii.endsWithIgnoreCase(buf, "db")) {
        buf = std.mem.trim(u8, buf[0 .. buf.len - 2], " \t");
    }
    const v = std.fmt.parseFloat(f32, buf) catch return null;
    const scaled = v * 1000.0;
    if (!std.math.isFinite(scaled)) return null;
    if (scaled > 2147483.647 or scaled < -2147483.648) return null;
    return @intFromFloat(@round(scaled));
}

fn parsePeak(s: []const u8) ?u32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch return null;
    const scaled = v * 100000.0;
    if (!std.math.isFinite(scaled)) return null;
    if (scaled < 0 or scaled > 4294967295.0) return null;
    return @intFromFloat(@round(scaled));
}

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

/// ID3v2 synchsafe 整数（每字节 7 位有效）
fn syncsafe(b: []const u8) u64 {
    return (@as(u64, b[0] & 0x7F) << 21) |
        (@as(u64, b[1] & 0x7F) << 14) |
        (@as(u64, b[2] & 0x7F) << 7) |
        (@as(u64, b[3] & 0x7F));
}

fn bigEndianU32(b: []const u8) u64 {
    return (@as(u64, b[0]) << 24) | (@as(u64, b[1]) << 16) | (@as(u64, b[2]) << 8) | b[3];
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "syncsafe 解析" {
    try std.testing.expectEqual(@as(u64, 0x10), syncsafe(&[_]u8{ 0x00, 0x00, 0x00, 0x10 }));
    try std.testing.expectEqual(@as(u64, 0xFFFFFF), syncsafe(&[_]u8{ 0x07, 0x7F, 0x7F, 0x7F }));
}

test "ID3v2.3 解析标题" {
    // 构造最小 ID3v2.3：标签头(10) + TIT2 帧头(4 ID + 4 size + 2 flags = 10) + 1 编码 + "Title"(5) = 26
    var tag: [26]u8 = undefined;
    tag[0..3].* = "ID3".*;
    tag[3] = 3; // v2.3
    tag[4] = 0;
    tag[5] = 0;
    const body_size: u32 = 16;
    std.mem.writeInt(u32, tag[6..10], body_size, .big); // v2.3 非 synchsafe
    // TIT2 帧
    tag[10..14].* = "TIT2".*;
    std.mem.writeInt(u32, tag[14..18], 6, .big);
    tag[18] = 0; // flags
    tag[19] = 0; // flags
    tag[20] = 3; // UTF-8
    tag[21..26].* = "Title".*;

    var reader = io.Reader.openMem(&tag);
    var meta: decoder.Metadata = .{};
    var pics: []decoder.Picture = &.{};
    var rg: decoder.ReplayGain = .{};
    defer {
        freeMeta(std.testing.allocator, &meta);
        freePictures(std.testing.allocator, &pics);
    }
    const end = try parseV2(&reader, std.testing.allocator, 0, &meta, &pics, &rg);
    try std.testing.expectEqual(@as(u64, tag.len), end);
    try std.testing.expectEqualStrings("Title", meta.title.?);
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! ASF（Advanced Systems Format）容器解析——WMA v1/v2 层（阶段 A）。
//!
//! 本模块只做：ASF Header 解析（File Properties + 音频 Stream Properties →
//! WAVEFORMATEX 参数）并定位 Data Object；数据包去包与 WMA 帧重组在后续阶段。
//! 布局对齐 FFmpeg libavformat/asfdec_f.c + libavcodec/wmadec.c（GUID 字节序按
//! ff_asf_guid 字面量，[0..16] 直接 eql）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const decoder = @import("../../decoder.zig");

pub const asf_header_guid = [16]u8{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };
const asf_file_props_guid = [16]u8{ 0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };
const asf_stream_props_guid = [16]u8{ 0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };
const asf_audio_stream_guid = [16]u8{ 0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B };
const asf_data_header_guid = [16]u8{ 0x36, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };
const asf_content_desc_guid = [16]u8{ 0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };
const asf_ext_content_desc_guid = [16]u8{ 0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11, 0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50 };
const asf_header_ext_guid = [16]u8{ 0xB5, 0x03, 0xBF, 0x5F, 0x2E, 0xA9, 0xCF, 0x11, 0x8E, 0xE3, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };

const CodecWmaV1: u16 = 0x0160;
const CodecWmaV2: u16 = 0x0161;
const CodecWmaPro: u16 = 0x0162;
const CodecWmaLossless: u16 = 0x0163;
const CodecWmaVoice: u16 = 0x000A;

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// WMA 音频流参数（WAVEFORMATEX + extradata 中的 flag 位）。
pub const AudioStream = struct {
    codec_tag: u16,
    channels: u8,
    sample_rate: u32,
    avg_bytes: u32, // 每秒平均字节（bitrate = ×8）
    block_align: u16, // 每 superframe 字节（WMA 帧重组关键）
    bits_per_sample: u16,
    /// 指向 header 缓冲内的 extradata（生命周期随 buffer）
    extradata: []const u8 = &.{},
    /// extradata 中解出的 WMA flag（wmadec.c：RL16(extradata+4)）
    flags2: u16 = 0,
    use_exp_vlc: bool = false,
    use_bit_reservoir: bool = false,
    use_variable_block_len: bool = false,
};

pub const Header = struct {
    file_size: u64,
    preroll_ms: u32,
    play_time_ms: u64,
    packet_size: u32, // Data Object 每包字节（min==max）
    audio: ?AudioStream = null,
    /// Header Object 之后的字节偏移（应为 Data Object）
    data_offset: usize = 0,
};

/// 解析 ASF Header Object（须从文件头开始），返回音频流参数与 Data 区起点。
/// `buf` 至少含 Header（可用头部缓冲；Header 之后可继续给足便于后续 data 定位）。
pub fn parseHeader(buf: []const u8) Error!Header {
    if (buf.len < 30) return error.Corrupt;
    if (!std.mem.eql(u8, buf[0..16], &asf_header_guid)) return error.UnsupportedFormat;
    const header_size = rd64(buf, 16); // 含 30 字节 object 头
    if (header_size < 30 or buf.len < header_size) return error.Corrupt;

    var hdr = Header{
        .file_size = 0,
        .preroll_ms = 0,
        .play_time_ms = 0,
        .packet_size = 0,
    };

    var pos: usize = 30;
    while (pos + 24 <= header_size) {
        const g = buf[pos..][0..16];
        const size = rd64(buf, pos + 16);
        if (size < 24 or pos + size > buf.len) return error.Corrupt;
        const body = pos + 24;

        if (std.mem.eql(u8, g, &asf_file_props_guid)) {
            // body: file_id(16) file_size(8) creation(8) packets(8) play(8) send(8)
            // preroll(4) flags(4) min_pkt(4) max_pkt(4)
            if (size < 24 + 16 + 8 + 8 + 8 + 8 + 8 + 4 + 4 + 4 + 4) return error.Corrupt;
            hdr.file_size = rd64(buf, body + 16);
            hdr.play_time_ms = rd64(buf, body + 40) / 10000;
            hdr.preroll_ms = rd32(buf, body + 56); // ASF preroll 单位 = ms
            const min_pkt = rd32(buf, body + 64);
            const max_pkt = rd32(buf, body + 68);
            hdr.packet_size = @max(min_pkt, max_pkt);
        } else if (std.mem.eql(u8, g, &asf_stream_props_guid)) {
            // body: stream_type(16) error_correction(16) total(8) tsp(4) _u32(4)
            // stream_id u16(4+2+4…) → WAVEFORMATEX 在 body+54
            const stype = buf[body..][0..16];
            if (!std.mem.eql(u8, stype, &asf_audio_stream_guid)) {
                pos += @intCast(size);
                continue;
            }
            const wb = body + 54; // 16+16+8+4+4+2+4
            if (wb + 20 > buf.len) return error.Corrupt;
            const tag = rd16(buf, wb);
            if (tag != CodecWmaV1 and tag != CodecWmaV2 and tag != CodecWmaPro and tag != CodecWmaLossless and tag != CodecWmaVoice) {
                pos += @intCast(size);
                continue;
            }
            var a = AudioStream{
                .codec_tag = tag,
                .channels = @intCast(rd16(buf, wb + 2)),
                .sample_rate = rd32(buf, wb + 4),
                .avg_bytes = rd32(buf, wb + 8),
                .block_align = rd16(buf, wb + 12),
                .bits_per_sample = rd16(buf, wb + 14),
            };
            const cb = rd16(buf, wb + 16);
            if (wb + 18 + cb <= buf.len) {
                a.extradata = buf[wb + 18 .. wb + 18 + cb];
                // wmadec.c：wmav2 → RL16(extradata+4)；wmav1 → RL16(extradata+2)
                // wmalossless 的 flags 不在此（decode_flags=RL16(extradata+14)），
                // wmavoice 的 flags 在 extradata+18（46 字节整段）
                // 均由各自子模块解析。
                if (tag != CodecWmaPro and tag != CodecWmaLossless and tag != CodecWmaVoice) {
                    const flag_off: usize = if (tag == CodecWmaV2) 4 else 2;
                    if (a.extradata.len >= flag_off + 2) {
                        a.flags2 = rd16(a.extradata, flag_off);
                        a.use_exp_vlc = (a.flags2 & 0x0001) != 0;
                        a.use_bit_reservoir = (a.flags2 & 0x0002) != 0;
                        a.use_variable_block_len = (a.flags2 & 0x0004) != 0;
                    }
                }
            }
            hdr.audio = a;
        }
        pos += @intCast(size);
    }
    hdr.data_offset = @intCast(header_size);
    if (hdr.audio == null) return error.UnsupportedFormat; // 无 WMA 音频轨
    return hdr;
}

/// 解析 Data Object 头并返回首个数据包偏移（Data 头 50 字节后）。
/// Data: guid16 + size8 + file_id16 + total_packets8 + reserved2 → packets@+50。
pub fn dataPacketsOffset(buf: []const u8, data_offset: usize) Error!usize {
    if (data_offset + 50 > buf.len) return error.Corrupt;
    if (!std.mem.eql(u8, buf[data_offset..][0..16], &asf_data_header_guid)) return error.UnsupportedFormat;
    return data_offset + 50;
}

/// 容器时长（微秒）= play_duration(100ns→ms) − preroll(ms)，与 ffprobe
/// format duration 同源。仅当头自洽（Header 内 file_size 字段 == 实际大小
/// 且 Data Object 未被截断）时可信——FATE 等截断样本的头时长属于原始完整
/// 文件，ffprobe 亦回退内容估算。不自洽/字段缺失 → null（调用方回落）。
pub fn containerDurationUs(buf: []const u8, hdr: *const Header) ?i64 {
    if (hdr.play_time_ms == 0) return null;
    if (hdr.file_size != buf.len) return null;
    const d = hdr.data_offset;
    if (d + 50 > buf.len) return null;
    if (!std.mem.eql(u8, buf[d..][0..16], &asf_data_header_guid)) return null;
    const data_size = rd64(buf, d + 16);
    if (data_size < 50 or d + data_size > buf.len) return null;
    if (hdr.play_time_ms <= hdr.preroll_ms) return null;
    return @intCast((hdr.play_time_ms - hdr.preroll_ms) * 1000);
}

// ---------------------------------------------------------------------------
// ASF 标签解析（Content Description + Extended Content Description；§8.4.2①）
// ---------------------------------------------------------------------------

pub const Tags = struct {
    meta: decoder.Metadata = .{},
    tags: []decoder.Tag = &.{},

    pub fn deinit(self: *Tags, allocator: std.mem.Allocator) void {
        inline for (.{ &self.meta.title, &self.meta.artist, &self.meta.album, &self.meta.date, &self.meta.genre, &self.meta.comment }) |p| {
            if (p.*) |s| {
                allocator.free(s);
                p.* = null;
            }
        }
        for (self.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        if (self.tags.len > 0) allocator.free(self.tags);
        self.tags = &.{};
        self.meta = .{};
    }
};

/// UTF-16LE 字节 → UTF-8 哨兵切片（供 decoder.Metadata 可空字段）
fn utf16z(allocator: std.mem.Allocator, bytes: []const u8) ![:0]u8 {
    const n = bytes.len / 2;
    const u16s = try allocator.alloc(u16, n);
    defer allocator.free(u16s);
    for (0..n) |i| u16s[i] = rd16(bytes, i * 2);
    return std.unicode.utf16LeToUtf8AllocZ(allocator, u16s);
}

/// UTF-16LE 字节 → UTF-8 普通切片
fn utf16(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const n = bytes.len / 2;
    const u16s = try allocator.alloc(u16, n);
    defer allocator.free(u16s);
    for (0..n) |i| u16s[i] = rd16(bytes, i * 2);
    return std.unicode.utf16LeToUtf8Alloc(allocator, u16s);
}

fn addTag(allocator: std.mem.Allocator, list: *std.ArrayList(decoder.Tag), name: []const u8, value: []const u8) !void {
    if (name.len == 0 or value.len == 0) return;
    const k = try allocator.dupe(u8, name);
    errdefer allocator.free(k);
    const v = try allocator.dupe(u8, value);
    errdefer allocator.free(v);
    try list.append(allocator, .{ .key = k, .value = v });
}

fn mapField(meta: *decoder.Metadata, name: []const u8, value: []const u8, allocator: std.mem.Allocator) !void {
    const slot: ?usize =
        if (std.ascii.eqlIgnoreCase(name, "WM/AlbumTitle")) 0
        else if (std.ascii.eqlIgnoreCase(name, "WM/AlbumArtist")) 1
        else if (std.ascii.eqlIgnoreCase(name, "WM/Year")) 2
        else if (std.ascii.eqlIgnoreCase(name, "WM/Genre")) 3
        else if (std.ascii.eqlIgnoreCase(name, "WM/Composer")) 4
        else null;
    const s = slot orelse return;
    const z = try allocator.dupeZ(u8, value);
    switch (s) {
        0 => meta.album = z,
        1 => meta.artist = z,
        2 => meta.date = z,
        3 => meta.genre = z,
        else => meta.comment = z,
    }
}

fn parseContentDesc(allocator: std.mem.Allocator, meta: *decoder.Metadata, body: []const u8) void {
    if (body.len < 10) return;
    const tl = rd16(body, 0);
    const al = rd16(body, 2);
    const cl = rd16(body, 4);
    const dl = rd16(body, 6);
    const rl = rd16(body, 8);
    var p: usize = 10;
    const fields = [_]struct { len: u16, slot: enum { title, artist, comment } }{
        .{ .len = tl, .slot = .title },
        .{ .len = al, .slot = .artist },
        .{ .len = cl, .slot = .comment }, // copyright
        .{ .len = dl, .slot = .comment },
    };
    for (fields) |f| {
        if (p + f.len > body.len) break;
        const z = utf16z(allocator, body[p .. p + f.len]) catch {
            p += f.len;
            continue;
        };
        p += f.len;
        switch (f.slot) {
            .title => if (meta.title == null) {
                meta.title = z;
            } else allocator.free(z),
            .artist => if (meta.artist == null) {
                meta.artist = z;
            } else allocator.free(z),
            .comment => if (meta.comment == null) {
                meta.comment = z;
            } else allocator.free(z),
        }
    }
    _ = rl;
}

fn parseExtContent(allocator: std.mem.Allocator, meta: *decoder.Metadata, list: *std.ArrayList(decoder.Tag), body: []const u8) void {
    if (body.len < 2) return;
    const count = rd16(body, 0);
    var p: usize = 2;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        if (p + 2 > body.len) break;
        const nl = rd16(body, p);
        p += 2;
        if (p + nl > body.len) break;
        const name = utf16(allocator, body[p .. p + nl]) catch {
            p += nl;
            continue;
        };
        p += nl;
        if (p + 4 > body.len) {
            allocator.free(name);
            break;
        }
        const vtype = rd16(body, p);
        const vl = rd16(body, p + 2);
        p += 4;
        if (p + vl > body.len) {
            allocator.free(name);
            break;
        }
        const vbytes = body[p .. p + vl];
        p += vl;

        if (vtype == 0) {
            const val = utf16(allocator, vbytes) catch {
                allocator.free(name);
                continue;
            };
            addTag(allocator, list, name, val) catch {};
            mapField(meta, name, val, allocator) catch {};
            allocator.free(val);
        } else {
            var num: [24]u8 = undefined;
            const text: []const u8 = switch (vtype) {
                2 => std.fmt.bufPrint(&num, "{d}", .{rd32(vbytes, 0)}) catch "",
                3 => std.fmt.bufPrint(&num, "{d}", .{rd32(vbytes, 0)}) catch "",
                4 => std.fmt.bufPrint(&num, "{d}", .{rd64(vbytes, 0)}) catch "",
                5 => std.fmt.bufPrint(&num, "{d}", .{rd16(vbytes, 0)}) catch "",
                else => "",
            };
            if (text.len > 0) addTag(allocator, list, name, text) catch {};
        }
        allocator.free(name);
    }
}

/// 解析 ASF Header 中的标签（Content Description / Extended Content Description，
/// 后者含 Header Extension 嵌套）。无标签返回空 `Tags`（非错误）。
pub fn parseTags(allocator: std.mem.Allocator, buf: []const u8) Error!Tags {
    var out = Tags{};
    if (buf.len < 30 or !std.mem.eql(u8, buf[0..16], &asf_header_guid)) return out;
    const header_size = rd64(buf, 16);
    if (header_size < 30 or buf.len < header_size) return out;

    var list: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (list.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        list.deinit(allocator);
    }

    var pos: usize = 30;
    while (pos + 24 <= header_size) {
        const g = buf[pos..][0..16];
        const size = rd64(buf, pos + 16);
        if (size < 24 or pos + size > buf.len) break;
        const body = buf[pos + 24 .. pos + size];

        if (std.mem.eql(u8, g, &asf_content_desc_guid)) {
            parseContentDesc(allocator, &out.meta, body);
        } else if (std.mem.eql(u8, g, &asf_ext_content_desc_guid)) {
            parseExtContent(allocator, &out.meta, &list, body);
        } else if (std.mem.eql(u8, g, &asf_header_ext_guid)) {
            // reserved(16) + data_size(4) + 嵌套对象
            if (body.len >= 20) {
                const dsize: usize = rd32(body, 16);
                const ns = body[20..];
                const ne = @min(ns.len, dsize);
                var q: usize = 0;
                while (q + 24 <= ne) {
                    const ng = ns[q..][0..16];
                    const nsz = rd64(ns, q + 16);
                    if (nsz < 24 or q + nsz > ns.len) break;
                    const nbody = ns[q + 24 .. q + nsz];
                    if (std.mem.eql(u8, ng, &asf_ext_content_desc_guid)) {
                        parseExtContent(allocator, &out.meta, &list, nbody);
                    } else if (std.mem.eql(u8, ng, &asf_content_desc_guid)) {
                        parseContentDesc(allocator, &out.meta, nbody);
                    }
                    q += @intCast(nsz);
                }
            }
        }
        pos += @intCast(size);
    }

    out.tags = list.toOwnedSlice(allocator) catch &.{};
    out.meta.tags = out.tags;
    return out;
}

/// 头部 play_duration − preroll（微秒），不要求 file_size 自洽（截断样本可作估计）。
pub fn playDurationUs(hdr: *const Header) ?i64 {
    if (hdr.play_time_ms == 0 or hdr.play_time_ms <= hdr.preroll_ms) return null;
    return @intCast((hdr.play_time_ms - hdr.preroll_ms) * 1000);
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! FLAC 元数据解析（可选 ID3v2 前置 + fLaC 头 + 元数据块遍历 + STREAMINFO + SEEKTABLE）
//!
//! 文件布局（参考重构，对照 FFmpeg libavformat/flacdec.c 与 libavcodec/flac.c）：
//!   [可选 ID3v2 标签] `fLaC`(4B) → 元数据块序列（每块 4B 头：last(1)+type(7) +
//!   size(24 BE)）→ 音频帧。已实证确认：最后一个元数据块后**无 CRC-16**，帧头紧跟
//!   （§ 会话记录）。
//!
//! 块类型（flac.h FLAC_METADATA_TYPE_*）：
//!   0 STREAMINFO（34B，必须出现且仅出现一次，其位置在文件开头）
//!   1 PADDING / 2 APPLICATION —— 跳过
//!   3 SEEKTABLE（每点 18B：sample_number u64 + stream_offset u64 + frame_samples u16）
//!   4 VORBIS_COMMENT（Vorbis comment：字段长度 LE；TITLE/ARTIST/ALBUM/DATE/GENRE/COMMENT
//!     （COMMENT 与 DESCRIPTION 同义）→ `decoder.Metadata`，键大小写不敏感、首字段优先、
//!     单字段限长 §9.1 同款；全部条目（含 TRACKNUMBER/ALBUMARTIST/REPLAYGAIN_* 等非标准
//!     键）→ `Metadata.tags`，对齐 FFmpeg av_dict；REPLAYGAIN_* 同时解析为增益）
//!   5 CUESHEET（CD 目录：头 396B + 每 track 36B + 每 index 12B；index offset（样本，相对
//!     音频流起点）→ `decoder.CuePoint`，条目数 clamp 到块实际承载）
//!   6 PICTURE（FLAC 规范 §5.8 / ID3v2 APIC：type/mime/desc/宽高/色深/数据，字段长度 BE；
//!     数据限长 64MiB，字段越界放弃该图 → `decoder.Picture`）
//!   其余类型（7..126 保留）与 127 INVALID —— 跳过（FFmpeg flacdec default 分支 avio_skip
//!     同款容错，未来新块类型不致拒播）
//!
//! 健壮性（§13.3）：magic / STREAMINFO 尺寸 / bps / blocksize / SEEKTABLE 尺寸
//! 均做边界校验；块循环有界（遇 last=1 终止，流截断 → Corrupt）；
//! VORBIS_COMMENT / CUESHEET / PICTURE 内部字段越界 → 停止该块解析（不报 Corrupt）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");

/// STREAMINFO 块固定尺寸（flac.h FLAC_STREAMINFO_SIZE）
pub const streaminfo_size = 34;
/// SEEKTABLE 单个 seek point 尺寸（libavformat/flacdec.c SEEKPOINT_SIZE）
pub const seekpoint_size = 18;
/// 单字段文本上限（防畸形超大分配；对齐 WAV LIST-INFO §9.1）
const max_meta_text: u64 = 4096;
/// 单图数据上限（§13.3 防畸形超大分配；封面常见 ≤ 数 MB）
const max_picture_data: u64 = 64 * 1024 * 1024;

/// 元数据块类型（flac.h FLAC_METADATA_TYPE_*）
pub const MetadataType = enum(u7) {
    streaminfo = 0,
    padding,
    application,
    seektable,
    vorbis_comment,
    cuesheet,
    picture,

    /// 未定义块类型（7..126 保留 / 127 INVALID）—— 跳过（FFmpeg flacdec default
    /// 分支 avio_skip 同款容错，见文件头注释）
    unknown,

    /// 字节 → 类型；未定义值（7..126 与 127 INVALID）→ .unknown（跳过，不报错）
    fn fromByte(b: u7) MetadataType {
        return switch (b) {
            0 => .streaminfo,
            1 => .padding,
            2 => .application,
            3 => .seektable,
            4 => .vorbis_comment,
            5 => .cuesheet,
            6 => .picture,
            else => .unknown,
        };
    }
};

/// STREAMINFO 解析结果（34 字节布局见文件头注释）
pub const StreamInfo = struct {
    min_blocksize: u16,
    max_blocksize: u16,
    min_framesize: u24,
    max_framesize: u24,
    sample_rate: u32, // 0 = 未知（时长不可得）
    channels: u8, // 1..8
    bits_per_sample: u8, // 4..32（<4 非法，由 parse 拒绝）
    total_samples: u64, // 0 = 未知
    md5: [16]u8,
};

/// SEEKTABLE 单个 seek point（解码定位用，§9.3 / ffmpeg av_add_index_entry 语义）
pub const SeekPoint = struct {
    /// 该点对应帧的**首样本编号**；0xFFFFFFFFFFFFFFFF = 占位点（不可用）
    sample_number: u64,
    /// 帧在文件中的**字节偏移**（相对文件头，含 fLaC 魔数）
    stream_offset: u64,
    /// 该帧的样本数（点可能落在帧中部）
    frame_samples: u16,
};

/// 元数据解析整体结果
pub const ParseResult = struct {
    allocator: std.mem.Allocator,
    info: StreamInfo,
    /// 分配器持有的 SEEKTABLE（空 = 无 seektable）
    seektable: std.ArrayList(SeekPoint),
    /// VORBIS_COMMENT 标签（allocator 持有；deinit 释放）
    meta: decoder.Metadata,
    /// VORBIS_COMMENT 通用条目构建缓冲（parse 成功 → toOwnedSlice 转移给
    /// meta.tags；失败 errdefer 路径由 deinit 释放元素）
    tags_buf: std.ArrayList(decoder.Tag) = .empty,
    /// REPLAYGAIN 增益（REPLAYGAIN_* 标签；纯值无动态内存）
    replay_gain: decoder.ReplayGain = .{},
    /// CUESHEET 提示点（allocator 持有；deinit 释放）
    cue_points: []decoder.CuePoint,
    /// PICTURE 附加图片（allocator 持有；deinit 释放）
    pictures: []decoder.Picture,

    pub fn deinit(self: *ParseResult) void {
        self.seektable.deinit(self.allocator);
        freeMeta(self.allocator, &self.meta);
        // tags_buf 未转移的条目（errdefer 路径）
        freeTagItems(self.allocator, self.tags_buf.items);
        self.tags_buf.deinit(self.allocator);
        if (self.cue_points.len > 0) {
            self.allocator.free(self.cue_points);
            self.cue_points = &.{};
        }
        freePictures(self.allocator, &self.pictures);
    }
};

/// 释放通用标签条目的 key/value（不释放条目数组本身）
fn freeTagItems(allocator: std.mem.Allocator, tags: []const decoder.Tag) void {
    for (tags) |t| {
        allocator.free(t.key);
        allocator.free(t.value);
    }
}

/// 释放标签元数据全部字段（parse 失败 errdefer 与 lib.zig deinit 共用）
pub fn freeMeta(allocator: std.mem.Allocator, meta: *decoder.Metadata) void {
    inline for (.{ &meta.title, &meta.artist, &meta.album, &meta.date, &meta.genre, &meta.comment }) |f| {
        if (f.*) |s| {
            allocator.free(s);
            f.* = null;
        }
    }
    // 通用条目（含条目数组本身）
    if (meta.tags.len > 0) {
        freeTagItems(allocator, meta.tags);
        allocator.free(meta.tags);
        meta.tags = &.{};
    }
}

/// 释放单个 Picture 的动态字段（mime / description / data；空 slice 不分配）
fn freePicture(allocator: std.mem.Allocator, pic: *decoder.Picture) void {
    if (pic.mime.len > 0) allocator.free(pic.mime);
    if (pic.description.len > 0) allocator.free(pic.description);
    if (pic.data.len > 0) allocator.free(pic.data);
    pic.* = .{};
}

/// 释放图片数组全部资源（parse 失败 errdefer 与 lib.zig deinit 共用）
pub fn freePictures(allocator: std.mem.Allocator, pics: *[]decoder.Picture) void {
    for (pics.*) |*p| freePicture(allocator, p);
    if (pics.*.len > 0) {
        allocator.free(pics.*);
        pics.* = &.{};
    }
}

/// 解析 fLaC 头与全部元数据块；成功时 reader 定位于**第一个音频帧**。
/// 调用方保证 reader 位于文件开头（offset 0）。
pub fn parse(reader: *io.Reader, allocator: std.mem.Allocator) Error!ParseResult {
    // 可选 ID3v2 前置标签（FLAC 规范允许；FFmpeg flacdec 同款跳过，见文件头注释）
    try skipId3v2(reader);

    // fLaC 魔数（防御性校验：probe 已按魔数路由，此处兜底）
    var magic: [4]u8 = undefined;
    try readExact(reader, &magic);
    if (!std.mem.eql(u8, &magic, "fLaC")) return error.Corrupt;

    var result = ParseResult{
        .allocator = allocator,
        .info = undefined,
        .seektable = .empty,
        .meta = .{},
        .cue_points = &.{},
        .pictures = &.{},
    };
    errdefer result.deinit();

    var found_streaminfo = false;
    while (true) {
        var hdr: [4]u8 = undefined;
        try readExact(reader, &hdr);
        const last = hdr[0] & 0x80 != 0;
        const meta_type = MetadataType.fromByte(@intCast(hdr[0] & 0x7F));
        const size: u32 = std.mem.readInt(u24, hdr[1..4], .big);

        switch (meta_type) {
            .streaminfo => {
                // STREAMINFO 只能出现一次且必须为 34 字节（flacdec.c 同款校验）
                if (found_streaminfo) return error.Corrupt;
                if (size != streaminfo_size) return error.Corrupt;
                var buf: [streaminfo_size]u8 = undefined;
                try readExact(reader, &buf);
                result.info = try parseStreamInfo(&buf);
                found_streaminfo = true;
            },
            .seektable => {
                // 与 FFmpeg 一致：STREAMINFO 之前不允许处理非 STREAMINFO 块
                if (!found_streaminfo) return error.Corrupt;
                if (size % seekpoint_size != 0) return error.Corrupt;
                const points = size / seekpoint_size;
                var i: u32 = 0;
                while (i < points) : (i += 1) {
                    var sp: [seekpoint_size]u8 = undefined;
                    try readExact(reader, &sp);
                    try result.seektable.append(allocator, .{
                        .sample_number = std.mem.readInt(u64, sp[0..8], .big),
                        .stream_offset = std.mem.readInt(u64, sp[8..16], .big),
                        .frame_samples = std.mem.readInt(u16, sp[16..18], .big),
                    });
                }
            },
            .vorbis_comment => {
                if (!found_streaminfo) return error.Corrupt;
                try parseVorbisComment(reader, allocator, size, &result.meta, &result.tags_buf, &result.replay_gain);
            },
            .cuesheet => {
                if (!found_streaminfo) return error.Corrupt;
                try parseCuesheet(reader, allocator, size, &result.cue_points);
            },
            .picture => {
                if (!found_streaminfo) return error.Corrupt;
                try parsePicture(reader, allocator, size, &result.pictures);
            },
            // PADDING / APPLICATION / 未知类型（含 127 INVALID）—— 跳过
            // （FFmpeg flacdec default 分支 avio_skip 同款容错）
            else => {
                try reader.seek(@intCast(size), .current);
            },
        }

        if (last) break;
    }
    if (!found_streaminfo) return error.Corrupt;

    // 通用条目缓冲 → meta.tags（转移所有权；toOwnedSlice 后缓冲为空）
    result.meta.tags = try result.tags_buf.toOwnedSlice(allocator);
    return result;
}

/// 跳过文件头 ID3v2 标签（布局：'ID3'(3) + ver(2) + flags(1) + size(4, synchsafe)，
/// 无 footer；FLAC 文件 ID3v2 无 footer flag 常规）。非 ID3 头 → 不移动位置。
/// size 声明越界 → 允许 seek 越过（后续魔数校验报 Corrupt，§13.3 有界）。
fn skipId3v2(reader: *io.Reader) Error!void {
    var head: [10]u8 = undefined;
    const n = try reader.peek(&head);
    if (n < 10 or !std.mem.eql(u8, head[0..3], "ID3")) return;
    const total: u64 = 10 + synchsafe32(&head[6..10].*);
    try reader.seek(@intCast(total), .current);
}

/// ID3v2 synchsafe 32 位（每字节仅 7 有效位，最高位必须为 0）
fn synchsafe32(b: *const [4]u8) u32 {
    return (@as(u32, b[0]) << 21) | (@as(u32, b[1]) << 14) | (@as(u32, b[2]) << 7) | b[3];
}

// ---------------------------------------------------------------------------
// VORBIS_COMMENT（类型 4）
// ---------------------------------------------------------------------------

/// 标签 key → 元数据字段（Vorbis 规范，大小写不敏感）
fn commentFieldOf(key: []const u8) ?MetaField {
    if (std.ascii.eqlIgnoreCase(key, "TITLE")) return .title;
    if (std.ascii.eqlIgnoreCase(key, "ARTIST")) return .artist;
    if (std.ascii.eqlIgnoreCase(key, "ALBUM")) return .album;
    if (std.ascii.eqlIgnoreCase(key, "DATE")) return .date;
    if (std.ascii.eqlIgnoreCase(key, "GENRE")) return .genre;
    // Vorbis 规范自由文本字段：COMMENT / DESCRIPTION 同义（首字段优先）
    if (std.ascii.eqlIgnoreCase(key, "COMMENT")) return .comment;
    if (std.ascii.eqlIgnoreCase(key, "DESCRIPTION")) return .comment;
    return null;
}

const MetaField = enum { title, artist, album, date, genre, comment };

/// 首次遇到才写入；返回 false 表示字段已占用（调用方释放传入串）
fn setMetaField(meta: *decoder.Metadata, field: MetaField, s: [:0]const u8) bool {
    switch (field) {
        .title => {
            if (meta.title != null) return false;
            meta.title = s;
        },
        .artist => {
            if (meta.artist != null) return false;
            meta.artist = s;
        },
        .album => {
            if (meta.album != null) return false;
            meta.album = s;
        },
        .date => {
            if (meta.date != null) return false;
            meta.date = s;
        },
        .genre => {
            if (meta.genre != null) return false;
            meta.genre = s;
        },
        .comment => {
            if (meta.comment != null) return false;
            meta.comment = s;
        },
    }
    return true;
}

/// 读取一个 LE u32（块内剩余不足 → null，容错停止）
fn readLeU32(reader: *io.Reader, end: u64) Error!?u32 {
    if (end -| reader.pos < 4) return null;
    var b: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const r = try reader.read(b[got..]);
        if (r == 0) return null; // 文件截断
        got += r;
    }
    return std.mem.readInt(u32, &b, .little);
}

/// 解析 FLAC VORBIS_COMMENT 块。Vorbis comment 布局（字段长度 **LE**）：
///   vendor_length(4) + vendor_string + list_length(4) + N × {length(4) + "KEY=value"}。
/// 全部条目（含非标准键）→ `tags`（对齐 FFmpeg av_dict）；REPLAYGAIN_* → `rg`；
/// 标准字段 → `meta`（首字段优先）。
/// 容错：内部字段长度越界/畸形 → 停止该块解析（reader 定位到块尾，不报 Corrupt，
/// 对齐 WAV LIST-INFO §9.1）。
fn parseVorbisComment(
    reader: *io.Reader,
    allocator: std.mem.Allocator,
    size: u32,
    meta: *decoder.Metadata,
    tags: *std.ArrayList(decoder.Tag),
    rg: *decoder.ReplayGain,
) Error!void {
    const end = reader.pos + size;
    const vendor_len = (try readLeU32(reader, end)) orelse {
        try reader.seek(@intCast(end -| reader.pos), .current);
        return;
    };
    // vendor_string（长度声明可能越界 → seek 跳过，剩余不足则到块尾）
    try reader.seek(@intCast(@min(vendor_len, end -| reader.pos)), .current);
    const list_len = (try readLeU32(reader, end)) orelse {
        try reader.seek(@intCast(end -| reader.pos), .current);
        return;
    };
    var i: u64 = 0;
    while (i < list_len) : (i += 1) {
        const flen = (try readLeU32(reader, end)) orelse {
            try reader.seek(@intCast(end -| reader.pos), .current);
            return;
        };
        try parseCommentField(reader, allocator, end, flen, meta, tags, rg);
    }
}

/// 读取单个 "KEY=value" 字段（长度声明 clamp 到块内可用；限长 max_meta_text）
fn parseCommentField(
    reader: *io.Reader,
    allocator: std.mem.Allocator,
    end: u64,
    len: u64,
    meta: *decoder.Metadata,
    tags: *std.ArrayList(decoder.Tag),
    rg: *decoder.ReplayGain,
) Error!void {
    const avail = end -| reader.pos;
    const n: usize = @intCast(@min(@min(len, avail), max_meta_text));
    if (n == 0) {
        if (avail > 0) try reader.seek(@intCast(avail), .current);
        return;
    }
    const buf = allocator.alloc(u8, n) catch return error.OutOfMemory;
    defer allocator.free(buf);
    var got: usize = 0;
    while (got < n) {
        const r = try reader.read(buf[got..]);
        if (r == 0) break;
        got += r;
    }
    if (len > got) try reader.seek(@intCast(@min(len - got, end -| reader.pos)), .current);
    // KEY=value：键非空且含 '='；值 trim 空则忽略
    const eq = std.mem.indexOfScalar(u8, buf[0..got], '=') orelse return;
    if (eq == 0) return;
    const key = buf[0..eq];
    const value = std.mem.trim(u8, buf[eq + 1 .. got], " \t\r\n\x00");
    if (value.len == 0) return;

    // 通用条目全量保留（对齐 FFmpeg av_dict：含 REPLAYGAIN_* 与标准字段键，
    // 重复键全部保留；key 原样大小写、value 已 trim）
    {
        const k = allocator.dupe(u8, key) catch return error.OutOfMemory;
        errdefer allocator.free(k);
        const v = allocator.dupe(u8, value) catch return error.OutOfMemory;
        errdefer allocator.free(v);
        try tags.append(allocator, .{ .key = k, .value = v });
    }

    // REPLAYGAIN 增益（单位对齐 FFmpeg AVReplayGain：gain 0.001dB / peak 0.00001）
    if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_TRACK_GAIN")) {
        rg.track_gain = parseGainDb(value) orelse rg.track_gain;
    } else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_TRACK_PEAK")) {
        rg.track_peak = parsePeak(value) orelse rg.track_peak;
    } else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_ALBUM_GAIN")) {
        rg.album_gain = parseGainDb(value) orelse rg.album_gain;
    } else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_ALBUM_PEAK")) {
        rg.album_peak = parsePeak(value) orelse rg.album_peak;
    }

    // 标准字段映射（首字段优先）
    const field = commentFieldOf(key) orelse return;
    const s = allocator.dupeZ(u8, value) catch return error.OutOfMemory;
    if (!setMetaField(meta, field, s)) allocator.free(s);
}

/// 解析 REPLAYGAIN_*_GAIN（"±X.XX dB"）→ 千分之一 dB 整数（对齐 FFmpeg
/// AVReplayGain.gain 单位）；畸形/越界 → null
fn parseGainDb(s: []const u8) ?i32 {
    var buf = std.mem.trim(u8, s, " \t");
    if (buf.len == 0) return null;
    if (std.ascii.endsWithIgnoreCase(buf, "db")) {
        buf = std.mem.trim(u8, buf[0 .. buf.len - 2], " \t");
    }
    const v = std.fmt.parseFloat(f32, buf) catch return null;
    const scaled = v * 1000.0;
    if (!std.math.isFinite(scaled)) return null;
    if (scaled > 2147483.647 or scaled < -2147483.648) return null; // i32 溢出防护
    return @intFromFloat(@round(scaled));
}

/// 解析 REPLAYGAIN_*_PEAK（"0.999023"）→ 十万分之一单位整数（对齐 FFmpeg
/// AVReplayGain.peak 单位）；畸形/越界 → null
fn parsePeak(s: []const u8) ?u32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch return null;
    if (v < 0 or !std.math.isFinite(v)) return null;
    const scaled = v * 100000.0;
    if (scaled >= 4294967295.0) return null;
    return @intFromFloat(@round(scaled));
}

// ---------------------------------------------------------------------------
// CUESHEET（类型 5）
// ---------------------------------------------------------------------------

/// CUESHEET 头固定尺寸：catalog(128) + lead_in(8) + is_cd/reserved(1) + num_tracks(1) + padding(258)
const cuesheet_header_size: u64 = 396;
/// 单个 track 固定头尺寸：offset(8) + number(1) + ISRC(12) + flags(1) + num_indices(1) + padding(12)
const cuesheet_track_size: u64 = 36;
/// 单个 index 尺寸：offset(8) + number(1) + reserved(3)
const cuesheet_index_size: u64 = 12;

/// 解析 FLAC CUESHEET 块：CD 目录 → 每个 track 的每个 index 生成一个提示点。
/// `position` = index 的样本偏移（相对音频流起点，FLAC 规范语义）；
/// `id` 顺序编号（FLAC 无全局 id 语义，与 WAV `cue ` 的 dwName 对齐）。
/// 容错：track/index 数 clamp 到块内实际字节（§13.3），截断时保留已解析点。
fn parseCuesheet(reader: *io.Reader, allocator: std.mem.Allocator, size: u32, cues: *[]decoder.CuePoint) Error!void {
    const block_start = reader.pos;
    const end = block_start + size;
    if (end -| reader.pos < cuesheet_header_size) {
        try reader.seek(@intCast(size), .current);
        return; // 头不完整 → 忽略
    }
    // num_tracks 位于头部第 137 字节（catalog 128 + lead_in 8 + flags 1）
    try reader.seek(@intCast(block_start + 137), .start);
    var nt: [1]u8 = undefined;
    try readExact(reader, &nt); // 头完整，必可读
    const num_tracks = nt[0];
    try reader.seek(@intCast(block_start + cuesheet_header_size), .start);

    var list = std.ArrayList(decoder.CuePoint).empty;
    errdefer list.deinit(allocator);
    var t: u8 = 0;
    while (t < num_tracks) : (t += 1) {
        if (end -| reader.pos < cuesheet_track_size) break; // track 头不足 → 停止
        var th: [cuesheet_track_size]u8 = undefined;
        try readExact(reader, &th);
        const num_indices = th[22]; // offset(8)+number(1)+ISRC(12)+flags(1)
        var k: u8 = 0;
        while (k < num_indices) : (k += 1) {
            if (end -| reader.pos < cuesheet_index_size) break;
            var ih: [cuesheet_index_size]u8 = undefined;
            try readExact(reader, &ih);
            const offset = std.mem.readInt(u64, ih[0..8], .big);
            try list.append(allocator, .{
                .id = @intCast(list.items.len), // 顺序编号
                .position = @intCast(@min(offset, 0xFFFF_FFFF)), // clamp 到 u32
            });
        }
    }
    cues.* = try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// PICTURE（类型 6）
// ---------------------------------------------------------------------------

/// 读取一个 BE u32（块内剩余不足或文件截断 → null，容错停止）
fn readBeU32(reader: *io.Reader, end: u64) Error!?u32 {
    if (end -| reader.pos < 4) return null;
    var b: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const r = try reader.read(b[got..]);
        if (r == 0) return null; // 文件截断
        got += r;
    }
    return std.mem.readInt(u32, &b, .big);
}

/// 读取一个长度前缀字段（声明长度 clamp 到块内可用与 limit；返回分配的字节，
/// len==0 时返回无分配空 slice）。返回 null 表示块内无剩余字节/文件截断
/// （停止该块解析）。超出声明长度的剩余字节 seek 跳过，保证块内对齐。
fn readLenField(reader: *io.Reader, allocator: std.mem.Allocator, end: u64, len: u64, limit: u64) Error!?[]u8 {
    const avail = end -| reader.pos;
    if (len == 0) return &.{};
    if (avail == 0) return null;
    const n: usize = @intCast(@min(@min(len, avail), limit));
    const buf = allocator.alloc(u8, n) catch return error.OutOfMemory;
    var got: usize = 0;
    while (got < n) {
        const r = try reader.read(buf[got..]);
        if (r == 0) {
            allocator.free(buf);
            return null; // 文件截断
        }
        got += r;
    }
    if (len > got) try reader.seek(@intCast(@min(len - got, end -| reader.pos)), .current);
    return buf;
}

/// 解析 FLAC PICTURE 块（FLAC 规范 §5.8 / ID3v2 APIC 布局，字段 BE）：
///   type(4) + mime_len(4) + mime + desc_len(4) + desc + width(4) + height(4) +
///   depth(4) + colors(4) + data_len(4) + data。
/// 容错：任一字段越界/截断 → 放弃该图（不报 Corrupt），reader 定位到块尾；
/// mime/desc 限长 max_meta_text、data 限长 max_picture_data（§13.3 防超大分配）。
fn parsePicture(reader: *io.Reader, allocator: std.mem.Allocator, size: u32, pics: *[]decoder.Picture) Error!void {
    const end = reader.pos + size;
    // 无论成功/放弃/错误，退出时 reader 定位于块尾（下块头不错位）
    defer reader.seek(@intCast(end -| reader.pos), .current) catch {};
    var pic: decoder.Picture = .{};
    var aborted = false;
    defer if (aborted) freePicture(allocator, &pic);

    pic.picture_type = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    const mime_len = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    pic.mime = (try readLenField(reader, allocator, end, mime_len, max_meta_text)) orelse {
        aborted = true;
        return;
    };
    const desc_len = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    pic.description = (try readLenField(reader, allocator, end, desc_len, max_meta_text)) orelse {
        aborted = true;
        return;
    };
    pic.width = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    pic.height = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    pic.depth = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    pic.colors = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    const data_len = (try readBeU32(reader, end)) orelse {
        aborted = true;
        return;
    };
    pic.data = (try readLenField(reader, allocator, end, data_len, max_picture_data)) orelse {
        aborted = true;
        return;
    };

    // 组装图片数组（parseCuesheet 同款：临时 ArrayList → toOwnedSlice 转移）
    var list = std.ArrayList(decoder.Picture).empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, pic);
    aborted = false; // 所有权已转移给 list
    pics.* = try list.toOwnedSlice(allocator);
}

/// 解析 34 字节 STREAMINFO（字段布局见文件头；ff_flac_parse_streaminfo）
fn parseStreamInfo(buf: *const [streaminfo_size]u8) Error!StreamInfo {
    const min_blocksize = std.mem.readInt(u16, buf[0..2], .big);
    const max_blocksize = std.mem.readInt(u16, buf[2..4], .big);
    const min_framesize: u24 = @intCast(std.mem.readInt(u24, buf[4..7], .big));
    const max_framesize: u24 = @intCast(std.mem.readInt(u24, buf[7..10], .big));
    const sample_rate: u32 = @intCast(std.mem.readInt(u24, buf[10..13], .big) >> 4);
    const channels: u8 = @intCast((buf[12] >> 1) & 0x07);
    const bps: u8 = @intCast(((buf[12] & 0x01) << 4) | (buf[13] >> 4));
    // 36 位样本数：buf[13] 低 4 位 + buf[14..17]
    const total_samples: u64 = (@as(u64, buf[13] & 0x0F) << 32) |
        (@as(u64, buf[14]) << 24) |
        (@as(u64, buf[15]) << 16) |
        (@as(u64, buf[16]) << 8) |
        buf[17];

    if (max_blocksize < 16) return error.Corrupt; // flac.h FLAC_MIN_BLOCKSIZE
    if (bps < 4) return error.Corrupt; // flac.c：bps+1 < 4 非法（<4 → 16 并报错）

    return .{
        .min_blocksize = min_blocksize,
        .max_blocksize = max_blocksize,
        .min_framesize = min_framesize,
        .max_framesize = max_framesize,
        .sample_rate = sample_rate,
        .channels = channels + 1,
        .bits_per_sample = bps + 1,
        .total_samples = total_samples,
        .md5 = buf[18..34].*,
    };
}

/// 循环读取直到填满 buf；EOF → error.Corrupt（截断）
fn readExact(reader: *io.Reader, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try reader.read(buf[off..]);
        if (n == 0) return error.Corrupt;
        off += n;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 构造 34 字节 STREAMINFO：44100Hz / 2ch / 16bit / 100 样本 / blocksize 4096
fn makeStreamInfo() [streaminfo_size]u8 {
    return .{
        0x10, 0x00, // min_blocksize 4096
        0x10, 0x00, // max_blocksize 4096
        0x00, 0x00, 0x00, // min_framesize 0
        0x00, 0x00, 0x00, // max_framesize 0
        0x0A, 0xC4, 0x42, // samplerate 44100 (20b) + ch-1=1 + bps-1 高 1 位
        0xF0, // bps-1 低 4 位 + total_samples 高 4 位
        0x00, 0x00, 0x00, 0x64, // total_samples = 100
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // md5 = 0
    };
}

test "streaminfo: fLaC 头 + STREAMINFO + SEEKTABLE 解析" {
    const si = makeStreamInfo();
    // 块头：STREAMINFO（非最后）→ SEEKTABLE（最后）
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 }); // STREAMINFO, size 34
    try stream.appendSlice(testing.allocator, &si);
    try stream.appendSlice(testing.allocator, &.{ 0x83, 0x00, 0x00, 0x12 }); // SEEKTABLE + last, size 18
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }); // sample 0
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x58 }); // offset 0x2058
    try stream.appendSlice(testing.allocator, &.{ 0x10, 0x00 }); // frame_samples 4096

    var r = io.Reader.openMem(stream.items);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(u16, 4096), result.info.min_blocksize);
    try testing.expectEqual(@as(u16, 4096), result.info.max_blocksize);
    try testing.expectEqual(@as(u32, 44100), result.info.sample_rate);
    try testing.expectEqual(@as(u8, 2), result.info.channels);
    try testing.expectEqual(@as(u8, 16), result.info.bits_per_sample);
    try testing.expectEqual(@as(u64, 100), result.info.total_samples);
    try testing.expectEqual(@as(usize, 1), result.seektable.items.len);
    try testing.expectEqual(@as(u64, 0), result.seektable.items[0].sample_number);
    try testing.expectEqual(@as(u64, 0x2058), result.seektable.items[0].stream_offset);
    try testing.expectEqual(@as(u16, 4096), result.seektable.items[0].frame_samples);
    // 解析结束后 reader 应指向音频帧起点（4 + 4 + 34 + 4 + 18 = 64）
    try testing.expectEqual(@as(u64, 64), r.pos);
}

test "streaminfo: 魔数错误 → Corrupt" {
    var r = io.Reader.openMem("RIFFxxxx");
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));
}

test "streaminfo: STREAMINFO 缺失 → Corrupt" {
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x00 }); // PADDING + last
    var r = io.Reader.openMem(stream.items);
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));
}

test "streaminfo: STREAMINFO 尺寸非 34 → Corrupt" {
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x04 }); // STREAMINFO + last, size 4
    try stream.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    var r = io.Reader.openMem(stream.items);
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));
}

test "streaminfo: STREAMINFO 重复出现 → Corrupt" {
    const si = makeStreamInfo();
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &si);
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &si);
    var r = io.Reader.openMem(stream.items);
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));
}

test "streaminfo: 未知块类型（保留值 / 127 INVALID）→ 跳过容错" {
    // 仅有 type 127 + last 且无 STREAMINFO → 仍 Corrupt（STREAMINFO 缺失）
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80 | 0x7F, 0x00, 0x00, 0x00 }); // type 127 + last
    var r = io.Reader.openMem(stream.items);
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));

    // STREAMINFO + 未知块（type 7、127）+ last → 跳过成功（FFmpeg default 分支同款）
    const si = makeStreamInfo();
    var stream2 = std.ArrayList(u8).empty;
    defer stream2.deinit(testing.allocator);
    try stream2.appendSlice(testing.allocator, "fLaC");
    try stream2.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 });
    try stream2.appendSlice(testing.allocator, &si);
    try stream2.appendSlice(testing.allocator, &.{ 0x07, 0x00, 0x00, 0x04 }); // type 7, size 4
    try stream2.appendSlice(testing.allocator, &.{ 1, 2, 3, 4 });
    try stream2.appendSlice(testing.allocator, &.{ 0x80 | 0x7F, 0x00, 0x00, 0x02 }); // type 127 + last, size 2
    try stream2.appendSlice(testing.allocator, &.{ 5, 6 });
    var r2 = io.Reader.openMem(stream2.items);
    var result = try parse(&r2, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(@as(u32, 44100), result.info.sample_rate);
    // 音频帧起点：fLaC(4) + si 头(4+34) + type7 头(4+4) + 127 头(4+2) = 56
    try testing.expectEqual(@as(u64, 56), r2.pos);
}

test "streaminfo: ID3v2 前置标签跳过（FLAC 规范允许）" {
    const junk = [_]u8{0x41} ** 32;
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "ID3");
    try stream.appendSlice(testing.allocator, &.{ 0x03, 0x00, 0x00 }); // ID3v2.3, flags 0
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x20 }); // synchsafe size 32
    try stream.appendSlice(testing.allocator, &junk);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 }); // STREAMINFO + last
    try stream.appendSlice(testing.allocator, &makeStreamInfo());

    var r = io.Reader.openMem(stream.items);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(@as(u32, 44100), result.info.sample_rate);
    // 音频帧起点：ID3(10+32) + fLaC(4) + 块头(4) + 34 = 84
    try testing.expectEqual(@as(u64, 84), r.pos);
}

test "streaminfo: max_blocksize < 16 / bps < 4 → Corrupt" {
    var bad = makeStreamInfo();
    bad[2] = 0x00; // max_blocksize 高字节 → 0x0000
    bad[3] = 0x00;
    try testing.expectError(error.Corrupt, parseStreamInfo(&bad));

    var bad2 = makeStreamInfo();
    bad2[12] = 0x40; // 清掉 bps 位：0x42 → 0x40
    bad2[13] = 0x00; // bps-1 = 0 → bps = 1 < 4
    try testing.expectError(error.Corrupt, parseStreamInfo(&bad2));
}

test "streaminfo: SEEKTABLE 尺寸非 18 倍数 → Corrupt" {
    const si = makeStreamInfo();
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &si);
    try stream.appendSlice(testing.allocator, &.{ 0x80 | 0x03, 0x00, 0x00, 0x01 }); // SEEKTABLE + last, size 1
    try stream.appendSlice(testing.allocator, &.{0x00});
    var r = io.Reader.openMem(stream.items);
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));
}

test "streaminfo: STREAMINFO 前的 SEEKTABLE → Corrupt（与 FFmpeg 一致）" {
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80 | 0x03, 0x00, 0x00, 0x12 }); // SEEKTABLE + last
    var r = io.Reader.openMem(stream.items);
    try testing.expectError(error.Corrupt, parse(&r, testing.allocator));
}

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn be32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    return b;
}

/// 构造 fLaC + STREAMINFO + 一个 type 元数据块（最后），返回整文件字节
fn buildMetaStream(meta_type: u7, payload: []const u8) ![]u8 {
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 }); // STREAMINFO（非最后）
    try stream.appendSlice(testing.allocator, &makeStreamInfo());
    var hdr: [4]u8 = undefined;
    hdr[0] = @as(u8, 0x80) | meta_type; // last = 1
    std.mem.writeInt(u24, hdr[1..4], @intCast(payload.len), .big);
    try stream.appendSlice(testing.allocator, &hdr);
    try stream.appendSlice(testing.allocator, payload);
    return stream.toOwnedSlice(testing.allocator);
}

test "streaminfo: VORBIS_COMMENT 解析（大小写不敏感 + 首字段优先 + 未知键跳过）" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &le32(11)); // vendor_length "libFLAC 1.4"
    try buf.appendSlice(testing.allocator, "libFLAC 1.4");
    const fields = [_][]const u8{
        "TITLE=My Song", "title=dup", // 首字段优先 → "My Song"
        "ARTIST=Singer", "ALBUM=Album",
        "DATE=2026",     "GENRE=Rock",
        "COMMENT=Great", "DESCRIPTION=Extra", // COMMENT/DESCRIPTION 同义 → 首字段 "Great"
        "UNKNOWN=x", // 未知键跳过
    };
    try buf.appendSlice(testing.allocator, &le32(@intCast(fields.len)));
    for (fields) |f| {
        try buf.appendSlice(testing.allocator, &le32(@intCast(f.len)));
        try buf.appendSlice(testing.allocator, f);
    }

    const file = try buildMetaStream(4, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    try testing.expectEqualStrings("My Song", result.meta.title.?);
    try testing.expectEqualStrings("Singer", result.meta.artist.?);
    try testing.expectEqualStrings("Album", result.meta.album.?);
    try testing.expectEqualStrings("2026", result.meta.date.?);
    try testing.expectEqualStrings("Rock", result.meta.genre.?);
    try testing.expectEqualStrings("Great", result.meta.comment.?);
}

test "streaminfo: VORBIS_COMMENT 字段长度越界 → 容错停止（不 Corrupt）" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &le32(0xFFFF_FFFF)); // vendor_length 声明超长（块内不足）
    // 块内再无有效字段；解析应安全停止、不越界读
    const file = try buildMetaStream(4, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();
    try testing.expect(result.meta.title == null);
    try testing.expectEqual(@as(usize, 0), result.meta.tags.len);
}

test "streaminfo: VORBIS_COMMENT 全量 tags 保留 + REPLAYGAIN 解析" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &le32(4)); // vendor_length "FLAC"
    try buf.appendSlice(testing.allocator, "FLAC");
    const fields = [_][]const u8{
        "TITLE=Demo", // 标准字段键同时入 tags（原样大小写）
        "TRACKNUMBER=03", // 非标准键
        "ALBUMARTIST=Various",
        "REPLAYGAIN_TRACK_GAIN=-6.35 dB",
        "REPLAYGAIN_TRACK_PEAK=0.999023",
        "REPLAYGAIN_ALBUM_GAIN=-8.00 dB",
        "REPLAYGAIN_ALBUM_PEAK=0.987654",
        "LYRICS=la la la",
    };
    try buf.appendSlice(testing.allocator, &le32(@intCast(fields.len)));
    for (fields) |f| {
        try buf.appendSlice(testing.allocator, &le32(@intCast(f.len)));
        try buf.appendSlice(testing.allocator, f);
    }
    const file = try buildMetaStream(4, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    // tags 全量（含标准字段键，顺序与文件一致）
    try testing.expectEqual(@as(usize, fields.len), result.meta.tags.len);
    try testing.expectEqualStrings("TITLE", result.meta.tags[0].key);
    try testing.expectEqualStrings("Demo", result.meta.tags[0].value);
    try testing.expectEqualStrings("TRACKNUMBER", result.meta.tags[1].key);
    try testing.expectEqualStrings("03", result.meta.tags[1].value);
    try testing.expectEqualStrings("ALBUMARTIST", result.meta.tags[2].key);
    try testing.expectEqualStrings("LYRICS", result.meta.tags[7].key);
    // REPLAYGAIN 数值（gain 0.001dB / peak 0.00001，对齐 FFmpeg AVReplayGain）
    try testing.expectEqual(@as(?i32, -6350), result.replay_gain.track_gain);
    try testing.expectEqual(@as(?u32, 99902), result.replay_gain.track_peak);
    try testing.expectEqual(@as(?i32, -8000), result.replay_gain.album_gain);
    try testing.expectEqual(@as(?u32, 98765), result.replay_gain.album_peak);
    // 标准字段照常填充
    try testing.expectEqualStrings("Demo", result.meta.title.?);
}

test "streaminfo: REPLAYGAIN 畸形值 → 保持 null（不崩溃）" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &le32(4));
    try buf.appendSlice(testing.allocator, "FLAC");
    const fields = [_][]const u8{
        "REPLAYGAIN_TRACK_GAIN=abc",
        "REPLAYGAIN_TRACK_PEAK=-1.5",
        "REPLAYGAIN_ALBUM_GAIN=", // 空值被 trim 忽略（不产生条目）
    };
    try buf.appendSlice(testing.allocator, &le32(@intCast(fields.len)));
    for (fields) |f| {
        try buf.appendSlice(testing.allocator, &le32(@intCast(f.len)));
        try buf.appendSlice(testing.allocator, f);
    }
    const file = try buildMetaStream(4, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(@as(?i32, null), result.replay_gain.track_gain);
    try testing.expectEqual(@as(?u32, null), result.replay_gain.track_peak);
    // 空值字段未入 tags（value 空被忽略）
    try testing.expectEqual(@as(usize, 2), result.meta.tags.len);
}

test "streaminfo: CUESHEET 解析（track/index → cue_points）" {
    var hdr = [_]u8{0} ** 396;
    hdr[136] = 0x80; // is_cd = 1
    hdr[137] = 2; // num_tracks = 2
    var t1 = [_]u8{0} ** 36;
    std.mem.writeInt(u64, t1[0..8], 0, .big); // track_offset
    t1[8] = 1; // track_number
    t1[22] = 2; // num_indices
    var idx1 = [_]u8{0} ** 12; // index 1.0: offset 0
    var idx2 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, idx2[0..8], 58800, .big); // index 1.1: offset 58800
    var t2 = [_]u8{0} ** 36;
    std.mem.writeInt(u64, t2[0..8], 123456, .big);
    t2[8] = 2;
    t2[22] = 1;
    var idx3 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, idx3[0..8], 123456, .big); // index 2.0: offset 123456

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &hdr);
    try buf.appendSlice(testing.allocator, &t1);
    try buf.appendSlice(testing.allocator, &idx1);
    try buf.appendSlice(testing.allocator, &idx2);
    try buf.appendSlice(testing.allocator, &t2);
    try buf.appendSlice(testing.allocator, &idx3);

    const file = try buildMetaStream(5, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.cue_points.len);
    try testing.expectEqual(@as(u32, 0), result.cue_points[0].position);
    try testing.expectEqual(@as(u32, 58800), result.cue_points[1].position);
    try testing.expectEqual(@as(u32, 123456), result.cue_points[2].position);
    // id 顺序编号
    try testing.expectEqual(@as(u32, 0), result.cue_points[0].id);
    try testing.expectEqual(@as(u32, 2), result.cue_points[2].id);
}

test "streaminfo: CUESHEET 声明 track 数超载 → clamp 保留已解析点" {
    var hdr = [_]u8{0} ** 396;
    hdr[137] = 10; // 声明 10 个 track，块内只有 2 个
    var t1 = [_]u8{0} ** 36;
    t1[22] = 1;
    var idx1 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, idx1[0..8], 100, .big);
    var t2 = [_]u8{0} ** 36;
    t2[22] = 1;
    var idx2 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, idx2[0..8], 200, .big);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &hdr);
    try buf.appendSlice(testing.allocator, &t1);
    try buf.appendSlice(testing.allocator, &idx1);
    try buf.appendSlice(testing.allocator, &t2);
    try buf.appendSlice(testing.allocator, &idx2);

    const file = try buildMetaStream(5, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    // 实际只够 2 个 track（每 track 36B + 12B）→ 2 个点；不报错、不越界
    try testing.expectEqual(@as(usize, 2), result.cue_points.len);
    try testing.expectEqual(@as(u32, 100), result.cue_points[0].position);
    try testing.expectEqual(@as(u32, 200), result.cue_points[1].position);
}

test "streaminfo: PICTURE 解析（type/mime/desc/尺寸/数据）" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &be32(3)); // picture_type = front cover
    try buf.appendSlice(testing.allocator, &be32(10)); // mime_len
    try buf.appendSlice(testing.allocator, "image/jpeg");
    try buf.appendSlice(testing.allocator, &be32(5)); // desc_len
    try buf.appendSlice(testing.allocator, "Front");
    try buf.appendSlice(testing.allocator, &be32(600)); // width
    try buf.appendSlice(testing.allocator, &be32(400)); // height
    try buf.appendSlice(testing.allocator, &be32(24)); // depth
    try buf.appendSlice(testing.allocator, &be32(0)); // colors（非索引色）
    try buf.appendSlice(testing.allocator, &be32(4)); // data_len
    try buf.appendSlice(testing.allocator, &.{ 0xFF, 0xD8, 0xFF, 0xE0 });

    const file = try buildMetaStream(6, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.pictures.len);
    const pic = &result.pictures[0];
    try testing.expectEqual(@as(u32, 3), pic.picture_type);
    try testing.expectEqualStrings("image/jpeg", pic.mime);
    try testing.expectEqualStrings("Front", pic.description);
    try testing.expectEqual(@as(u32, 600), pic.width);
    try testing.expectEqual(@as(u32, 400), pic.height);
    try testing.expectEqual(@as(u32, 24), pic.depth);
    try testing.expectEqual(@as(u32, 0), pic.colors);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8, 0xFF, 0xE0 }, pic.data);
}

test "streaminfo: PICTURE 字段截断 → 放弃该图（不 Corrupt）且块对齐不破坏后续块" {
    // 畸形 PICTURE：mime_len 声明 0xFFFF 但块内只有 6 字节 → 读 6 字节后块耗尽
    var bad_pic = std.ArrayList(u8).empty;
    defer bad_pic.deinit(testing.allocator);
    try bad_pic.appendSlice(testing.allocator, &be32(3)); // type
    try bad_pic.appendSlice(testing.allocator, &be32(0xFFFF)); // mime_len 声明超长
    try bad_pic.appendSlice(testing.allocator, "ab"); // 块内仅 2 字节 → 不足 4 字节读 desc_len

    // 组装：fLaC + STREAMINFO + PICTURE（非最后，size = 14） + VORBIS_COMMENT（最后）
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &makeStreamInfo());
    var pic_hdr = [_]u8{ 0x06, 0x00, 0x00, 0x00 }; // PICTURE（非最后）
    std.mem.writeInt(u24, pic_hdr[1..4], @intCast(bad_pic.items.len), .big);
    try stream.appendSlice(testing.allocator, &pic_hdr);
    try stream.appendSlice(testing.allocator, bad_pic.items);
    // 合法的 VORBIS_COMMENT 块（TITLE=OK）跟在畸形 PICTURE 之后
    var vb = std.ArrayList(u8).empty;
    defer vb.deinit(testing.allocator);
    try vb.appendSlice(testing.allocator, &le32(0)); // vendor_length = 0
    try vb.appendSlice(testing.allocator, &le32(1)); // 1 字段
    try vb.appendSlice(testing.allocator, &le32(8)); // "TITLE=OK"
    try vb.appendSlice(testing.allocator, "TITLE=OK");
    var vb_hdr = [_]u8{ 0x84, 0x00, 0x00, 0x00 }; // VORBIS_COMMENT + last
    std.mem.writeInt(u24, vb_hdr[1..4], @intCast(vb.items.len), .big);
    try stream.appendSlice(testing.allocator, &vb_hdr);
    try stream.appendSlice(testing.allocator, vb.items);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    // 畸形图被放弃；后续 VORBIS_COMMENT 正常解析（证明块对齐未破坏）
    try testing.expectEqual(@as(usize, 0), result.pictures.len);
    try testing.expectEqualStrings("OK", result.meta.title.?);
}

test "streaminfo: PICTURE data 声明超块 → data 截断到可用（不 Corrupt）" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &be32(3)); // type
    try buf.appendSlice(testing.allocator, &be32(0)); // mime_len（空）
    try buf.appendSlice(testing.allocator, &be32(0)); // desc_len（空）
    try buf.appendSlice(testing.allocator, &be32(0)); // width
    try buf.appendSlice(testing.allocator, &be32(0)); // height
    try buf.appendSlice(testing.allocator, &be32(0)); // depth
    try buf.appendSlice(testing.allocator, &be32(0)); // colors
    try buf.appendSlice(testing.allocator, &be32(100)); // data_len 声明 100，块内仅 5
    try buf.appendSlice(testing.allocator, &.{ 1, 2, 3, 4, 5 });

    const file = try buildMetaStream(6, buf.items);
    defer testing.allocator.free(file);
    var r = io.Reader.openMem(file);
    var result = try parse(&r, testing.allocator);
    defer result.deinit();

    // data 截断到块内可用（5 字节），图片保留
    try testing.expectEqual(@as(usize, 1), result.pictures.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, result.pictures[0].data);
}

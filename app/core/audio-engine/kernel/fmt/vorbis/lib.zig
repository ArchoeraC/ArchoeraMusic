// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Vorbis 解码器封装（open + VTable + Ogg 流式 pushdata）
//!
//! 文档（docs/audio-kernel-zig.md §9.12）：复用自研 Ogg 容器（fmt/ogg.zig 负责
//! 页/包重组与 granule 定位），解码走 vendored `stb_vorbis`（public domain 单文件，
//! 编译进内核见 build.zig addCSourceFile）。
//!
//! 接入方式：stb_vorbis pushdata API（`stb_vorbis_open_pushdata` +
//! `stb_vorbis_decode_frame_pushdata`）——调用方流式喂入 Ogg 字节，stb_vorbis
//! 内部做 Ogg 页同步与 Vorbis 帧解码；输出 float（每声道独立数组）→ 转 s16
//! 交错（缩放 2^15，对齐 stb_vorbis 自身 `FAST_SCALED_FLOAT_TO_INT(x,15)`）。
//!
//! 帧循环语义（对齐 stb_vorbis pushdata）：
//!   - `decode_frame_pushdata` 返回 (bytes_used, samples)：
//!     - 0 字节/0 样本 → 需更多输入（继续喂）；
//!     - N 字节/0 样本 → 页重同步（继续喂）；
//!     - N 字节/M 样本 → 解出一帧；
//!   - 输入缓冲按需增长，`in_pos` 记录已消费字节，空间不足时前移压缩。
//!
//! 输出契约：原生 16-bit、交错 PCM，采样率/声道取自 Vorbis ident（stb_vorbis
//! `get_info`）。Vorbis 为有损格式（无 bit-exact 参考），对照 FFmpeg `libvorbis`
//! 以 ±1 LSB 容差评估（§3.7 裁决 vendored stb_vorbis）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const ogg = @import("../ogg.zig");

const c = @cImport(@cInclude("stb_vorbis.h"));

const VORBIS_need_more_data = 1;
/// pushdata 打开时初始数据块大小（逐步增长直到包含全部头）
const OPEN_CHUNK = 32 * 1024;
/// 解码时单次追加读取块大小
const READ_CHUNK = 32 * 1024;

const VorbisCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,

    vf: ?*c.stb_vorbis = null,

    sample_rate: u32 = 0,
    channels: u8 = 0,

    /// 标签元数据（open 解析；deinit 释放）
    meta: decoder.Metadata = .{},

    /// pushdata 输入缓冲（已读入但可能未消费的 Ogg 字节）
    in_buf: std.ArrayList(u8) = .empty,
    /// 已消费位置（<= in_buf.len）
    in_pos: usize = 0,

    /// 已解码 PCM（交错 s16）
    pcm: std.ArrayList(i16) = .empty,
    pcm_pos: usize = 0,
    eof: bool = false,
    samples_done: u64 = 0,
};

// ---- open ----

/// 从已打开 Reader 解析 Vorbis（decoder.open 与测试共用入口）。
/// 成功时 Decoder 接管 `reader` 所有权（deinit 关闭）。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const f = try allocator.create(VorbisCtx);
    errdefer allocator.destroy(f);
    f.* = .{
        .allocator = allocator,
        .reader = reader.*,
    };
    errdefer f.reader.deinit();

    // 首页流序列号（尾页扫描按流匹配；无 OggS 前缀时 0 = 不限定）
    var serial: u32 = 0;
    {
        var head: [27]u8 = undefined;
        const n = f.reader.peek(&head) catch 0;
        if (n >= 27 and std.mem.eql(u8, head[0..4], "OggS")) {
            serial = std.mem.readInt(u32, head[14..18], .little);
        }
    }

    // 逐步喂入直到 stb_vorbis 完成头部解析（VORBIS_need_more_data 时继续）
    var consumed: c_int = 0;
    var err: c_int = 0;
    var buf_len: usize = 0;
    while (true) {
        if (buf_len + READ_CHUNK > f.in_buf.capacity) {
            try f.in_buf.ensureTotalCapacity(allocator, @max(buf_len + READ_CHUNK, OPEN_CHUNK));
        }
        const got = try f.reader.read(try f.in_buf.addManyAsSlice(allocator, READ_CHUNK));
        f.in_buf.items.len = buf_len + got;
        buf_len = f.in_buf.items.len;
        if (got == 0) return error.Corrupt; // 头部缺失

        f.vf = c.stb_vorbis_open_pushdata(f.in_buf.items.ptr, @intCast(buf_len), &consumed, &err, null);
        if (f.vf != null) break;
        if (err == VORBIS_need_more_data and buf_len < 16 * 1024 * 1024) continue;
        return error.Corrupt;
    }
    f.in_pos = @intCast(consumed);

    try extractComments(f, allocator);

    const vinfo = c.stb_vorbis_get_info(f.vf.?);
    f.sample_rate = @intCast(vinfo.sample_rate);
    f.channels = @intCast(vinfo.channels);
    if (f.channels == 0) return error.Corrupt;

    // 时长：尾窗扫描末页 granule（Vorbis granule = 累计解码样本数，首帧从 0，
    // 无 pre-skip）。seek 不可用（callback 流）→ unknown；EOS 页缺失/损坏 →
    // 退末页 granule 估计（.estimate）。stb_vorbis pushdata 模式无总长 API
    // （其内部 stream_length 依赖文件 seek），故自研尾扫为可靠路径。
    var total_samples: u64 = 0;
    var duration_known: decoder.DurationKnown = .unknown;
    if ((ogg.scanTailPage(&f.reader, serial) catch null)) |tail| {
        const granule_max: i64 = @as(i64, @intCast(f.sample_rate)) * 12 * 3600;
        if (tail.granule > 0 and tail.granule < granule_max) {
            total_samples = @intCast(tail.granule);
            duration_known = if (tail.eos) .exact else .estimate;
        }
    }

    info.* = .{
        .sample_rate = f.sample_rate,
        .channels = f.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = if (total_samples > 0)
            @intCast((@as(u128, total_samples) * 1_000_000) / f.sample_rate)
        else
            0,
        .duration_known = duration_known,
        .codec_name = "vorbis",
        .format_name = "ogg",
        .metadata = f.meta,
    };
    return .{ .vtable = &vtable, .ctx = f };
}

// ---------------------------------------------------------------------------
// 元数据专用快路径（probe-only，§8.4.2①）
// ---------------------------------------------------------------------------

/// 元数据专用轻量上下文：只保留 Ogg demux + 识别头字段 + 标签，
/// **不含** stb_vorbis 解码器（codebook/残差状态）。
const MetaCtx = struct {
    allocator: std.mem.Allocator,
    demux: ogg.Demux,
    sample_rate: u32 = 0,
    channels: u8 = 0,
    meta: decoder.Metadata = .{},
};

fn metaDeinit(p: *anyopaque) void {
    const f: *MetaCtx = @ptrCast(@alignCast(p));
    freeMeta(f.allocator, &f.meta);
    f.demux.deinit();
    f.allocator.destroy(f);
}

/// 解析 Vorbis comment 头包（type 0x03 + "vorbis" + vendor + N×"KEY=value"）。
/// 与 OpusTags 同布局（RFC 7845 §5.2 / Vorbis I §5）。
fn parseVorbisComment(meta: *decoder.Metadata, allocator: std.mem.Allocator, data: []const u8) Error!void {
    if (data.len < 7 or data[0] != 0x03 or !std.mem.eql(u8, data[1..7], "vorbis")) return;
    var pos: usize = 7;
    if (pos + 4 > data.len) return;
    const vendor_len: usize = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    pos += @min(vendor_len, data.len -| pos);
    if (pos + 4 > data.len) return;
    const list_len: u32 = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    var tags: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        if (pos + 4 > data.len) break;
        const slen: usize = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (slen > data.len -| pos) break;
        const entry = data[pos .. pos + slen];
        pos += slen;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        const key = entry[0..eq];
        const value = std.mem.trim(u8, entry[eq + 1 ..], " \t\r\n\x00");
        if (value.len == 0) continue;

        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try tags.append(allocator, .{ .key = k, .value = v });

        const field = commentFieldOf(key) orelse continue;
        const s = try allocator.dupeZ(u8, value);
        if (!setMetaField(meta, field, s)) allocator.free(s);
    }
    meta.tags = try tags.toOwnedSlice(allocator);
}

/// 元数据专用入口：只解 Vorbis 识别头 + comment 头 + 尾页 granule（时长），
/// 不构造 stb_vorbis 解码器。
pub fn openMeta(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.MetadataSession {
    const f = try allocator.create(MetaCtx);
    errdefer allocator.destroy(f);
    f.* = .{ .allocator = allocator, .demux = undefined };
    f.demux = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.demux.deinit();

    // 识别头：type 0x01 + "vorbis" + version(4) + channels(1) + sample_rate(4)…
    const id_pkt = (try f.demux.nextPacket()) orelse return error.Corrupt;
    if (id_pkt.continued) return error.Corrupt;
    const id = id_pkt.data;
    if (id.len < 16 or id[0] != 0x01 or !std.mem.eql(u8, id[1..7], "vorbis")) return error.Corrupt;
    f.channels = id[11];
    f.sample_rate = std.mem.readInt(u32, id[12..16], .little);
    if (f.channels == 0 or f.sample_rate == 0) return error.Corrupt;

    if (try f.demux.nextPacket()) |c_pkt| {
        parseVorbisComment(&f.meta, allocator, c_pkt.data) catch {};
    }
    errdefer freeMeta(allocator, &f.meta);

    var total_samples: u64 = 0;
    var duration_known: decoder.DurationKnown = .unknown;
    if ((ogg.scanTailPage(&f.demux.reader, f.demux.serial) catch null)) |tail| {
        const granule_max: i64 = @as(i64, @intCast(f.sample_rate)) * 12 * 3600;
        if (tail.granule > 0 and tail.granule < granule_max) {
            total_samples = @intCast(tail.granule);
            duration_known = if (tail.eos) .exact else .estimate;
        }
    }

    info.* = .{
        .sample_rate = f.sample_rate,
        .channels = f.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = if (total_samples > 0)
            @intCast((@as(u128, total_samples) * 1_000_000) / f.sample_rate)
        else
            0,
        .duration_known = duration_known,
        .codec_name = "vorbis",
        .format_name = "ogg",
        .metadata = f.meta,
    };
    return .{ .ctx = @ptrCast(f), .deinit_fn = metaDeinit };
}


// ---------------------------------------------------------------------------
// 标签（Vorbis comment：vendor + N × "KEY=value"）
// ---------------------------------------------------------------------------

const MetaField = enum { title, artist, album, date, genre, comment };

fn commentFieldOf(key: []const u8) ?MetaField {
    if (std.ascii.eqlIgnoreCase(key, "TITLE")) return .title;
    if (std.ascii.eqlIgnoreCase(key, "ARTIST")) return .artist;
    if (std.ascii.eqlIgnoreCase(key, "ALBUM")) return .album;
    if (std.ascii.eqlIgnoreCase(key, "DATE")) return .date;
    if (std.ascii.eqlIgnoreCase(key, "GENRE")) return .genre;
    if (std.ascii.eqlIgnoreCase(key, "COMMENT")) return .comment;
    if (std.ascii.eqlIgnoreCase(key, "DESCRIPTION")) return .comment;
    return null;
}

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

/// 释放元数据字符串（deinit 调用；对齐 FLAC freeMeta 语义）
fn freeMeta(allocator: std.mem.Allocator, meta: *decoder.Metadata) void {
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

/// 从 stb_vorbis 已解析的 comment_list 提取标签（"KEY=value" → 标准字段 + tags + replaygain）。
fn extractComments(f: *VorbisCtx, allocator: std.mem.Allocator) Error!void {
    const comment = c.stb_vorbis_get_comment(f.vf.?);
    var tags: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }
    const n: usize = if (comment.comment_list_length > 0) @intCast(comment.comment_list_length) else 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = std.mem.span(comment.comment_list[i]);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        const key = entry[0..eq];
        const value = std.mem.trim(u8, entry[eq + 1 ..], " \t\r\n\x00");
        if (value.len == 0) continue;

        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try tags.append(allocator, .{ .key = k, .value = v });

        const field = commentFieldOf(key) orelse continue;
        const s = try allocator.dupeZ(u8, value);
        if (!setMetaField(&f.meta, field, s)) allocator.free(s);
    }
    f.meta.tags = try tags.toOwnedSlice(allocator);
}

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

// ---- VTable 实现 ----

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *VorbisCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    const frame_bytes = @as(usize, f.channels) * 2;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.pcm_pos * f.channels >= f.pcm.items.len) {
            f.pcm.clearRetainingCapacity();
            f.pcm_pos = 0;
            if (!try decodeMore(f)) break; // EOF
            continue;
        }
        const avail = (f.pcm.items.len / f.channels) - f.pcm_pos;
        const take = @min(avail, cap - produced);
        const src_byte_off = f.pcm_pos * frame_bytes;
        const dst = out[produced * frame_bytes ..][0 .. take * frame_bytes];
        @memcpy(dst, std.mem.sliceAsBytes(f.pcm.items)[src_byte_off .. src_byte_off + take * frame_bytes]);
        f.pcm_pos += take;
        produced += take;
    }
    return produced;
}

/// 从 stb_vorbis 解出一帧（或继续喂输入）。返回是否有新 PCM。
fn decodeMore(f: *VorbisCtx) Error!bool {
    while (true) {
        // 输入耗尽 → 追加读取
        if (f.in_pos >= f.in_buf.items.len) {
            if (f.eof) return false;
            // 前移压缩已消费前缀
            if (f.in_pos > 0) {
                const rem = f.in_buf.items.len - f.in_pos;
                std.mem.copyForwards(u8, f.in_buf.items[0..rem], f.in_buf.items[f.in_pos..]);
                f.in_buf.items.len = rem;
                f.in_pos = 0;
            }
            const got = try f.reader.read(try f.in_buf.addManyAsSlice(f.allocator, READ_CHUNK));
            f.in_buf.items.len = f.in_buf.items.len - READ_CHUNK + got;
            if (got == 0) {
                f.eof = true;
                // 末尾残余数据可能仍含帧
                if (f.in_buf.items.len == 0) return false;
            }
        }

        var ch_out: c_int = 0;
        var output: [*c][*c]f32 = null;
        var samples: c_int = 0;
        const bytes_used = c.stb_vorbis_decode_frame_pushdata(
            f.vf.?,
            f.in_buf.items.ptr + f.in_pos,
            @intCast(f.in_buf.items.len - f.in_pos),
            &ch_out,
            &output,
            &samples,
        );
        f.in_pos += @intCast(bytes_used);

        if (samples > 0) {
            const n: usize = @intCast(samples);
            const chn: usize = @intCast(ch_out);
            try f.pcm.ensureUnusedCapacity(f.allocator, n * chn);
            var s: usize = 0;
            while (s < n) : (s += 1) {
                var ch: usize = 0;
                while (ch < chn) : (ch += 1) {
                    const v: f32 = output[ch][s];
                    // 对齐 stb_vorbis FAST_SCALED_FLOAT_TO_INT(x,15)：x*2^15 截断 + 限幅
                    var iv: i32 = @intFromFloat(@trunc(v * 32768.0));
                    if (iv < -32768) iv = -32768;
                    if (iv > 32767) iv = 32767;
                    f.pcm.appendAssumeCapacity(@intCast(iv));
                }
            }
            f.samples_done += n;
            return true;
        }

        // 0 字节/0 样本：stb_vorbis 等待更多输入。强制追加读取；EOF 时结束。
        if (bytes_used == 0 and samples == 0) {
            if (f.eof) return false;
            if (f.in_pos > 0) {
                const rem = f.in_buf.items.len - f.in_pos;
                std.mem.copyForwards(u8, f.in_buf.items[0..rem], f.in_buf.items[f.in_pos..]);
                f.in_buf.items.len = rem;
                f.in_pos = 0;
            }
            const got = try f.reader.read(try f.in_buf.addManyAsSlice(f.allocator, READ_CHUNK));
            f.in_buf.items.len = f.in_buf.items.len - READ_CHUNK + got;
            if (got == 0) {
                f.eof = true;
                return false;
            }
            continue;
        }
        // bytes_used > 0 但 0 样本：页重同步，继续
    }
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *VorbisCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / f.sample_rate);
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *VorbisCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0 or f.vf == null) return error.UnsupportedFormat;
    const target: u64 = if (ms <= 0)
        0
    else
        @intCast(@divTrunc(@as(u128, @intCast(ms)) * f.sample_rate, 1000));

    // 用自研 Ogg 解复用按 granule 定位目标页（granule = 累计已解码样本数）。
    // 找到 granule <= target 的最后那一页，seek 到该页起点，flush 后由
    // stb_vorbis 重同步，再解码丢弃到精确目标。
    try f.reader.seek(0, .start);
    var demux = ogg.Demux{ .allocator = f.allocator, .reader = f.reader };
    defer {
        // 临时解复用器不拥有 fd（与 f.reader 共享）：中和 reader 避免双重关闭
        demux.reader = .{ .kind = .memory, .data = &.{} };
        demux.deinit();
    }
    var page_off: u64 = 0;
    while (try demux.nextPacket()) |pkt| {
        if (pkt.granule <= @as(i64, @intCast(target))) {
            // 目标样本落在该页：seek 到此页起点，flush 后重同步
            page_off = demux.page_start;
        } else {
            break;
        }
    }
    if (page_off == 0) return error.SeekFailed;

    // 重建 stb_vorbis 输入状态：seek 到目标页，flush，重置解码缓冲
    try f.reader.seek(@intCast(page_off), .start);
    f.in_buf.clearRetainingCapacity();
    f.in_pos = 0;
    f.pcm.clearRetainingCapacity();
    f.pcm_pos = 0;
    f.eof = false;
    c.stb_vorbis_flush_pushdata(f.vf.?);

    // 解码并丢弃，直到样本位置 >= target。重同步后由 get_sample_offset 给出
    // 精确位置（含 MDCT overlap/priming 修正），以其为基准计算丢弃量。
    var pos: i64 = c.stb_vorbis_get_sample_offset(f.vf.?);
    var guard: usize = 0;
    while (pos < 0) : (guard += 1) {
        if (!try decodeMore(f)) return error.SeekFailed;
        // 重同步期间的帧位置未锚定：丢弃其 pcm，重新开始
        f.pcm.clearRetainingCapacity();
        f.pcm_pos = 0;
        pos = c.stb_vorbis_get_sample_offset(f.vf.?);
        if (guard > 100000) return error.SeekFailed;
    }
    // pos = 下一帧起始样本位置（current_loc）。从该处解码并丢弃 (target-pos) 样本。
    var to_discard: i64 = @as(i64, @intCast(target)) - pos;
    var iters: usize = 0;
    while (to_discard > 0) {
        iters += 1;
        if (iters > 200000) return error.SeekFailed;
        const total: i64 = @intCast(@divExact(f.pcm.items.len, f.channels));
        const remaining: i64 = total - @as(i64, @intCast(f.pcm_pos));
        if (remaining <= 0) {
            if (!try decodeMore(f)) return error.SeekFailed;
            continue;
        }
        const skip: i64 = @min(to_discard, remaining);
        f.pcm_pos += @intCast(skip);
        to_discard -= skip;
    }
    f.samples_done = target;
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *VorbisCtx = @ptrCast(@alignCast(ctx));
    if (f.vf) |vf| c.stb_vorbis_close(vf);
    freeMeta(f.allocator, &f.meta);
    f.in_buf.deinit(f.allocator);
    f.pcm.deinit(f.allocator);
    f.reader.deinit();
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "vorbis: 集成解码（open + 读取 + 时长）" {
    const data = @embedFile("tiny.ogg");
    var reader = io.Reader.openMem(data);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try std.testing.expectEqual(@as(u8, 2), info.channels);
    try std.testing.expectEqual(@as(u32, 44100), info.sample_rate);
    // 末页 granule 4410 @44100 = 0.1s（EOS 页 → exact）
    try std.testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try std.testing.expectEqual(@as(i64, 100_000), info.duration_us);

    var buf: [8192]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, 2048, &ch);
        if (n == 0) break;
        total += n * ch * 2;
        if (total > 1024 * 1024) break;
    }
    try std.testing.expect(total > 0);
    try std.testing.expectEqual(@as(u8, 2), ch);
}

/// 末页（OggS）起始偏移（构造无 EOS 变体用）
fn lastPageStart(data: []const u8) usize {
    var last: usize = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..4], "OggS")) last = i;
    }
    return last;
}

test "vorbis: EOS 页缺失 → estimate 降级（退前一音频页）" {
    const data = @embedFile("multi.ogg");
    const cut = lastPageStart(data);
    try testing.expect(cut > 100);
    var reader = io.Reader.openMem(data[0..cut]);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    // 前一音频页 granule 仍可用 → estimate
    try testing.expectEqual(decoder.DurationKnown.estimate, info.duration_known);
    try testing.expect(info.duration_us > 0 and info.duration_us < 2_012_993);
}

test "vorbis: 多页流 exact（末页 granule = 累计样本数）" {
    const data = @embedFile("multi.ogg");
    var reader = io.Reader.openMem(data);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try testing.expectEqual(@as(i64, 2_012_993), info.duration_us); // granule 88773 @44100
}

test "vorbis: seek 定位" {
    const data = @embedFile("tiny.ogg");
    var reader = io.Reader.openMem(data);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try dc.seekMs(50);
    var buf: [8192]u8 = undefined;
    var ch: u8 = 0;
    const n = try dc.read(&buf, 1024, &ch);
    try std.testing.expect(n > 0);
}

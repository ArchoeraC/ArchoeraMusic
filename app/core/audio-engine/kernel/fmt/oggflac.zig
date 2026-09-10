// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! Ogg 容器内 FLAC 流（Ogg-FLAC mapping，RFC 5334）
//!
//! 文档（docs/audio-kernel-zig.md §9.3）：Ogg-FLAC 首个 packet =
//! `0x7F "FLAC"` + version(1) + header_packet_type(1=0 fLaC) + `"fLaC"` + metadata
//! blocks（STREAMINFO 必须居首）；后续每个 packet = 一个完整 FLAC 音频帧。
//!
//! 接入方式：用 `fmt/ogg.zig` Demux 逐包取帧，通过 **callback Reader**
//! （`io.Reader` on_read/on_seek 回调）把剥离映射头后的 packet1（"fLaC"+blocks）
//! 与后续帧拼接成连续字节流，喂给现有 `fmt/flac/lib.zig` 解码器 —— 元数据
//! （VORBIS_COMMENT/PICTURE/时长）与帧解码全部复用，零代码重复。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");
const ogg = @import("ogg.zig");
const flac = @import("flac/lib.zig");

const Allocator = std.mem.Allocator;

const OggFlacCtx = struct {
    allocator: Allocator,
    /// 内层 FLAC 解码器（callback reader 喂包；deinit 释放）
    flac: decoder.Decoder,
    /// Ogg 容器（packet 源；deinit 关闭文件）
    demux: ogg.Demux,
    /// on_read/on_seek 回调上下文
    stream: FlacStream,
    /// callback reader 的 peek 缓冲（io.Reader.buffer，16KB）
    peek_buf: []u8,
};

const FlacStream = struct {
    demux: *ogg.Demux,
    /// 全部 metadata（"fLaC" + STREAMINFO/VORBIS_COMMENT 等，已剥离 mapping 头）
    first: []u8,
    first_done: bool = false,
    /// 预读的第一个音频帧（open 定位时读到；拷在 pkt_buf）
    pending: []u8 = &.{},
    /// 当前 packet 缓冲（demux.nextPacket 内部缓冲会失效，须拷贝）
    cur: []u8 = &.{},
    cur_pos: usize = 0,
    pkt_buf: []u8 = &.{},
    eof: bool = false,
};

fn streamRead(ctx: *anyopaque, buf: []u8) usize {
    const s: *FlacStream = @ptrCast(@alignCast(ctx));
    if (s.eof) return 0;
    var out: usize = 0;
    var guard: usize = 0;
    while (out < buf.len) : (guard += 1) {
        if (guard > 1_000_000) return out;
        if (s.cur_pos >= s.cur.len) {
            if (!s.first_done) {
                s.first_done = true;
                s.cur = s.first;
                s.cur_pos = 0;
                if (s.cur.len == 0) continue;
            } else if (s.pending.len > 0) {
                s.cur = s.pending;
                s.pending = &.{};
                s.cur_pos = 0;
                if (s.cur.len == 0) continue;
            } else {
                const pkt = s.demux.nextPacket() catch {
                    s.eof = true;
                    break;
                } orelse {
                    s.eof = true;
                    break;
                };
                if (pkt.data.len > s.pkt_buf.len) {
                    s.eof = true;
                    break;
                }
                @memcpy(s.pkt_buf[0..pkt.data.len], pkt.data);
                s.cur = s.pkt_buf[0..pkt.data.len];
                s.cur_pos = 0;
            }
        }
        const n = @min(buf.len - out, s.cur.len - s.cur_pos);
        @memcpy(buf[out..][0..n], s.cur[s.cur_pos..][0..n]);
        s.cur_pos += n;
        out += n;
    }
    return out;
}

fn streamSeek(ctx: *anyopaque, off: i64, whence: i32, buffered: usize) bool {
    // 仅支持相对当前位置向前小步跳过（metadata block 内部定位；坏帧重同步向后不支持）。
    if (whence != 1 or off < 0) return false;
    // io.zig 已把 buffered 字节（peek 缓冲中未消费）丢弃；从流源再跳过 off - buffered。
    var remaining: i64 = off - @as(i64, @intCast(buffered));
    if (remaining <= 0) return true;
    var tmp: [4096]u8 = undefined;
    while (remaining > 0) {
        const n = @min(@as(usize, @intCast(remaining)), tmp.len);
        const got = streamRead(ctx, tmp[0..n]);
        if (got == 0) break;
        remaining -= @as(i64, @intCast(got));
    }
    return true;
}

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

pub fn open(allocator: Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const ctx = try allocator.create(OggFlacCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .flac = undefined,
        .demux = .{ .allocator = allocator, .reader = reader.* },
        .stream = undefined,
        .peek_buf = &.{},
    };
    errdefer ctx.demux.deinit();

    const head_pkt = (try ctx.demux.nextPacket()) orelse return error.Corrupt;
    if (head_pkt.data.len < 8) return error.Corrupt;
    if (head_pkt.data[0] != 0x7F or !std.mem.eql(u8, head_pkt.data[1..5], "FLAC")) return error.Corrupt;
    // mapping 头（0x7F"FLAC"+version+header_type，muxer 细节不定）后跟 "fLaC"+metadata
    // blocks —— 以 "fLaC" 定位（含跨版本差异），其后即标准 FLAC 元数据。
    const flac_magic_idx = std.mem.indexOf(u8, head_pkt.data, "fLaC") orelse return error.Corrupt;
    // 收集全部 metadata：packet0（STREAMINFO）+ 后续 metadata packet（VORBIS_COMMENT 等，
    // 以 block header 起始，非 0xFF 帧同步）直到 last-block 位置位。
    var first_buf = std.ArrayList(u8).empty;
    defer first_buf.deinit(allocator);
    try first_buf.appendSlice(allocator, head_pkt.data[flac_magic_idx..]);
    var last_block = false;
    {
        var off: usize = 0;
        while (off + 4 <= first_buf.items.len) {
            const h = first_buf.items[off];
            const ln: usize = (@as(usize, first_buf.items[off + 1]) << 16) | (@as(usize, first_buf.items[off + 2]) << 8) | first_buf.items[off + 3];
            off += 4 + ln;
            if (h & 0x80 != 0) last_block = true;
        }
    }
    var total_data: u64 = first_buf.items.len;
    while (!last_block) {
        const p = try ctx.demux.nextPacket() orelse break;
        if (p.data.len < 4 or p.data[0] == 0xFF) break; // 帧同步 → metadata 结束
        try first_buf.appendSlice(allocator, p.data);
        total_data += p.data.len;
        if (p.data[0] & 0x80 != 0) last_block = true;
    }
    const first = try first_buf.toOwnedSlice(allocator);
    errdefer allocator.free(first);

    // FLAC 帧上限（blocksize 65535 × 8ch × 4B ≈ 2MB；Ogg-FLAC 单包一般远小）
    const pkt_buf = try allocator.alloc(u8, 1 << 21);
    errdefer allocator.free(pkt_buf);
    // callback reader 的 peek 缓冲（io.zig peek_buffer_size=16KB；peek 前须已分配）
    const peek_buf = try allocator.alloc(u8, 16384);
    errdefer allocator.free(peek_buf);
    ctx.peek_buf = peek_buf;
    ctx.stream = .{
        .demux = &ctx.demux,
        .first = first,
        .pkt_buf = pkt_buf,
    };

    // 预扫描累计全部音频帧 packet 数据长度 → callback size_hint（EOF 判定）。
    while (true) {
        const p = try ctx.demux.nextPacket() orelse break;
        total_data += p.data.len;
    }
    try ctx.demux.reset();
    // 跳过 mapping 头 + 全部 metadata packet（已并入 first）→ 预读第一个音频帧
    // （streamRead 的 first 之后输出 pending，再逐包喂帧）
    var pending_len: usize = 0;
    while (true) {
        const p = try ctx.demux.nextPacket() orelse return error.Corrupt;
        if (p.data.len >= 2 and p.data[0] == 0xFF) {
            if (p.data.len > pkt_buf.len) return error.Corrupt;
            @memcpy(pkt_buf[0..p.data.len], p.data);
            pending_len = p.data.len;
            break;
        }
    }
    ctx.stream.pending = pkt_buf[0..pending_len];

    // callback reader：把 "fLaC"+blocks + 帧拼接喂给 FLAC 解码器
    var flac_reader = io.Reader{
        .kind = .callback,
        .on_read = streamRead,
        .on_seek = streamSeek,
        .ctx = &ctx.stream,
        .buffer = ctx.peek_buf,
        .size_hint = total_data,
    };
    ctx.flac = try flac.open(allocator, &flac_reader, info);
    // 时长补齐：Ogg-FLAC 的 STREAMINFO total_samples 常为 0（流式 muxer，
    // 如 ffmpeg 写 Ogg 时无法预知总样本数）→ FLAC 层报 unknown。用尾窗扫描
    // 末页 granule 补齐（Ogg-FLAC mapping：granule = 末帧末样本绝对编号，
    // granule/rate 与 ffprobe 容器时长一致）。EOS 页 → exact；EOS 缺失/损坏
    // → 退 .estimate；callback/扫描失败 → 维持 FLAC 层（STREAMINFO）结果。
    if (info.duration_known != .exact) {
        if ((ogg.scanTailPage(&ctx.demux.reader, ctx.demux.serial) catch null)) |tail| {
            const rate = info.sample_rate;
            const granule_max: i64 = @as(i64, @intCast(rate)) * 12 * 3600;
            if (tail.granule > 0 and rate > 0 and tail.granule < granule_max) {
                info.duration_us = @intCast((@as(u128, @intCast(tail.granule)) * 1_000_000) / rate);
                info.duration_known = if (tail.eos) .exact else .estimate;
            }
        }
    }
    info.format_name = "ogg-flac";
    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// 元数据专用快路径（probe-only，§8.4.2①）：收集 Ogg-FLAC metadata packet →
// 内存 reader 调 flac.openMeta（不构造 FLAC 帧解码器）。
// ---------------------------------------------------------------------------

const MetaCtx = struct {
    allocator: Allocator,
    demux: ogg.Demux,
    /// 合成的 "fLaC"+metadata blocks（供内层 flac 会话解析）
    first: []u8,
    flac: decoder.MetadataSession,
};

fn metaDeinit(p: *anyopaque) void {
    const f: *MetaCtx = @ptrCast(@alignCast(p));
    f.flac.deinit();
    f.allocator.free(f.first);
    f.demux.deinit();
    f.allocator.destroy(f);
}

pub fn openMeta(allocator: Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.MetadataSession {
    var demux: ogg.Demux = .{ .allocator = allocator, .reader = reader.* };
    errdefer demux.deinit();

    const head_pkt = (try demux.nextPacket()) orelse return error.Corrupt;
    if (head_pkt.data.len < 8) return error.Corrupt;
    if (head_pkt.data[0] != 0x7F or !std.mem.eql(u8, head_pkt.data[1..5], "FLAC")) return error.Corrupt;
    const flac_magic_idx = std.mem.indexOf(u8, head_pkt.data, "fLaC") orelse return error.Corrupt;

    var first_buf = std.ArrayList(u8).empty;
    defer first_buf.deinit(allocator);
    try first_buf.appendSlice(allocator, head_pkt.data[flac_magic_idx..]);
    var last_block = false;
    {
        var off: usize = 0;
        while (off + 4 <= first_buf.items.len) {
            const h = first_buf.items[off];
            const ln: usize = (@as(usize, first_buf.items[off + 1]) << 16) |
                (@as(usize, first_buf.items[off + 2]) << 8) | first_buf.items[off + 3];
            off += 4 + ln;
            if (h & 0x80 != 0) last_block = true;
        }
    }
    while (!last_block) {
        const p = try demux.nextPacket() orelse break;
        if (p.data.len < 4 or p.data[0] == 0xFF) break;
        try first_buf.appendSlice(allocator, p.data);
        if (p.data[0] & 0x80 != 0) last_block = true;
    }
    const first = try first_buf.toOwnedSlice(allocator);
    errdefer allocator.free(first);

    var mem = io.Reader.openMem(first);
    const sess = try flac.openMeta(allocator, &mem, info);
    errdefer sess.deinit();

    // 时长补齐：STREAMINFO total_samples 常为 0 → 尾页 granule（同完整 open）
    if (info.duration_known != .exact) {
        if ((ogg.scanTailPage(&demux.reader, demux.serial) catch null)) |tail| {
            const rate = info.sample_rate;
            const granule_max: i64 = @as(i64, @intCast(rate)) * 12 * 3600;
            if (tail.granule > 0 and rate > 0 and tail.granule < granule_max) {
                info.duration_us = @intCast((@as(u128, @intCast(tail.granule)) * 1_000_000) / rate);
                info.duration_known = if (tail.eos) .exact else .estimate;
            }
        }
    }
    info.format_name = "ogg-flac";

    const ctx = try allocator.create(MetaCtx);
    ctx.* = .{ .allocator = allocator, .demux = demux, .first = first, .flac = sess };
    return .{ .ctx = @ptrCast(ctx), .deinit_fn = metaDeinit };
}

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {    const f: *OggFlacCtx = @ptrCast(@alignCast(ctx));
    const r = f.flac.read(out, max_samples, out_channels) catch |err| {
        // Ogg-FLAC 流末尾：packet 耗尽后 FLAC 解码器无法定位下一帧（Corrupt/SeekFailed）。
        // 当底层流已 EOF → 视为正常结束（返回 0），否则透传。
        if (f.stream.eof and (err == error.Corrupt or err == error.SeekFailed or err == error.IoError)) return 0;
        return err;
    };
    return r;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    // Ogg-FLAC seek：需按 Ogg granule 定位帧 + 配合内层 FLAC 状态重建
    _ = ctx;
    _ = ms;
    return error.UnsupportedFormat;
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *OggFlacCtx = @ptrCast(@alignCast(ctx));
    return f.flac.positionMs();
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *OggFlacCtx = @ptrCast(@alignCast(ctx));
    f.flac.deinit();
    f.demux.deinit();
    f.allocator.free(f.stream.first);
    f.allocator.free(f.stream.pkt_buf);
    f.allocator.free(f.peek_buf);
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 末页（OggS）起始偏移（构造无 EOS 变体用）
fn lastPageStart(data: []const u8) usize {
    var last: usize = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..4], "OggS")) last = i;
    }
    return last;
}

/// ffmpeg 生成（0.5s 440Hz 正弦 44100 mono，`-c:a flac -f ogg`）：STREAMINFO
/// total_samples = 0（流式 muxer），末页 EOS granule 22050 = 0.5s
const sample_oga = @embedFile("samples/oggflac_tiny.oga");

/// ffmpeg 生成（2.013s 44100 mono）：末页 EOS granule 88773（多音频页形态）
const multi_oga = @embedFile("samples/oggflac_multi.oga");

test "oggflac: open Info 时长（末页 granule 补齐 STREAMINFO total_samples=0）" {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(sample_oga);
    var dc = try open(testing.allocator, &reader, &info);
    defer dc.deinit();
    try testing.expectEqualStrings("ogg-flac", info.format_name);
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    // STREAMINFO total_samples = 0 → 尾页 granule 22050 @44100 = 0.5s exact
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try testing.expectEqual(@as(i64, 500_000), info.duration_us);
    // 扫描不污染读取：open 后解码正常产出
    var buf: [8192]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, 2048, &ch);
        if (n == 0) break;
        total += n;
    }
    try testing.expect(total > 20000); // ≈0.5s 单声道 s16
}

test "oggflac: EOS 页缺失 → estimate 降级" {
    const cut = lastPageStart(multi_oga); // 砍掉音频 EOS 页
    try testing.expect(cut > 100);
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(multi_oga[0..cut]);
    var dc = try open(testing.allocator, &reader, &info);
    defer dc.deinit();
    // STREAMINFO total_samples = 0；尾页无 EOS → 退前一音频页 granule 估计
    try testing.expectEqual(decoder.DurationKnown.estimate, info.duration_known);
    try testing.expect(info.duration_us > 0 and info.duration_us < 2_012_993);
}

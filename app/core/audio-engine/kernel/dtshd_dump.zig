// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DTS-HD（.dtshd 容器 / 裸 DTS core 流）解码对照导出工具
//!
//! 容器层解析 DTSHDHDR 块 → STRMDATA 载荷；载荷内以 core sync（0x7FFE8001）
//! 定位访问单元，每单元 = core 帧 +（可选）EXSS 子流。逐单元解码：
//!   - core 帧 → 既有定点 core 解码（扬声器平面）；
//!   - EXSS asset 含 XLL 分量 → XLL 无损解码 + 与 core 上混；
//!   - 否则仅 core 输出。
//! 与 `ffmpeg -flags +bitexact -f s32le` 对齐（含首 2 访问单元 pad 丢弃，
//! 容器 AUPR-HDR delay = 2 个 core 帧）。输出 s24<<8(s32le)/s16le。
//!
//! 用法：
//!   zig build-exe kernel/dtshd_dump.zig -lc -O ReleaseSafe -femit-bin=./dtshd_dump
//!   ./dtshd_dump <file.dtshd|file.dts> [-s16] [-skip N] > out.s32
//!
//! X96（CSS/EXSS）、XCH/XXCH（CSS/EXSS 附加声道）与 XLL 均完整接入。

const std = @import("std");
const io = @import("io.zig");
const coremod = @import("fmt/dts/core.zig");
const exss = @import("fmt/dts/exss.zig");
const xll = @import("fmt/dts/xll.zig");
const t = @import("fmt/dts/tables.zig");

const SpeakerPlanes = [xll.SPEAKER_COUNT]?[]const i32;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try init.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("usage: dtshd_dump <file> [-s16] [-skip N] [-o2o1]\n", .{});
        return error.InvalidArgs;
    }
    var out_s16 = false;
    var skip_units: usize = 2;
    var o2o = true;
    var verbose = false;
    var ai: usize = 2;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if (std.mem.eql(u8, arg, "-s16")) out_s16 = true;
        if (std.mem.eql(u8, arg, "-o2o0")) o2o = false;
        if (std.mem.eql(u8, arg, "-v")) verbose = true;
        if (std.mem.eql(u8, arg, "-skip")) {
            ai += 1;
            skip_units = try std.fmt.parseInt(usize, args[ai], 10);
        }
    }

    var reader = try io.Reader.openPath(args[1]);
    defer reader.deinit();
    const sz = try reader.size();
    if (sz <= 0 or sz > 1024 * 1024 * 1024) return error.InvalidData;
    const data = try a.alloc(u8, @intCast(sz));
    var got: usize = 0;
    while (got < data.len) {
        const n = try reader.read(data[got..]);
        if (n == 0) break;
        got += n;
    }
    const buf: []const u8 = data[0..got];

    const payload = extractStreamPayload(buf) catch |e| {
        std.debug.print("container error: {s}\n", .{@errorName(e)});
        return e;
    };

    const units = try collectUnits(a, payload);
    std.debug.print("-- units={d}  payload={d}B\n", .{ units.len, payload.len });

    var core_dec = coremod.DcaDecoder.init(gpa);
    defer core_dec.deinit();
    var xll_dec = xll.XllDecoder.init(gpa);
    defer xll_dec.deinit();

    var out_buf: [65536]u8 = undefined;
    var first_out = true;

    var ui: usize = 0;
    for (units) |u| {
        const core_len = u.core_len;
        const core_buf = payload[u.off .. u.off + core_len];
        var frame: coremod.DecodedFrame = undefined;
        core_dec.parseCore(core_buf) catch |e| {
            std.debug.print("unit {d} core parse err {s}\n", .{ ui, @errorName(e) });
            ui += 1;
            continue;
        };

        var em: u16 = 0;
        var xxch_off: usize = 0;
        var xxch_sz: usize = 0;
        var x96_off: usize = 0;
        var x96_sz: usize = 0;
        var xll_parse_ok = false;
        var storage: u8 = 24;

        const exss_off = u.exss_off;
        if (exss_off != null) {
            const exss_buf = payload[exss_off.? .. u.end];
            var asset: exss.Asset = .{};
            if (exss.parse(exss_buf, &asset)) |_| {
                em = asset.extension_mask;
                xxch_off = asset.xxch_offset;
                xxch_sz = asset.xxch_size;
                x96_off = asset.x96_offset;
                x96_sz = asset.x96_size;
                if (em & exss.ext_xll != 0 and asset.xll_size != 0) {
                    const xdata = exss_buf[asset.xll_offset .. asset.xll_offset + asset.xll_size];
                    if (xll_dec.parseFrame(xdata, asset.one_to_one_map_ch_to_spkr and o2o)) {
                        if (verbose) {
                            std.debug.print("unit {d} xll ok nchsets={d} nfs={d} nsegs={d}\n", .{ ui, xll_dec.nchsets, xll_dec.nframesamples, xll_dec.nsegsamples });
                            for (0..xll_dec.nchsets) |ci| {
                                const cs = &xll_dec.chset[ci];
                                std.debug.print("  chset{d}: nch={d} res=0x{x} pcm={d} stor={d} mask=0x{x} nfreq={d} dmix={} emb={} hier={}\n", .{ ci, cs.nchannels, cs.residual_encode, cs.pcm_bit_res, cs.storage_bit_res, cs.ch_mask, cs.nfreqbands, cs.dmix_coeffs_present, cs.dmix_embedded, cs.hier_chset });
                            }
                        }
                        xll_parse_ok = true;
                    } else |err| {
                        if (err != error.NoSync and err != error.Corrupt and err != error.Invalid and err != error.Unsupported)
                            std.debug.print("unit {d} xll parse err {s}\n", .{ ui, @errorName(err) });
                    }
                }
            } else |err| {
                std.debug.print("unit {d} exss parse err {s}\n", .{ ui, @errorName(err) });
            }
        }

        // core 扩展声道（CSS XCH/XXCH / EXSS XXCH）与 X96（EXSS/CSS）
        core_dec.parseCoreExss(core_buf,
            if (u.exss_off != null) payload[u.exss_off.? .. u.end] else null,
            em, xxch_off, xxch_sz, x96_off, x96_sz, xll_parse_ok) catch |e| {
            std.debug.print("unit {d} core exss err {s}\n", .{ ui, @errorName(e) });
        };

        // XLL 激活时 core 合成采样率由 XLL 决定
        var x96_synth = core_dec.x96_active;
        if (xll_parse_ok and xll_dec.chset[0].freq == 96000 and core_dec.sample_rate == 48000)
            x96_synth = true;

        core_dec.filter(&frame, x96_synth) catch |e| {
            std.debug.print("unit {d} core filter err {s}\n", .{ ui, @errorName(e) });
            ui += 1;
            continue;
        };

        var spk_planes: SpeakerPlanes = [_]?[]const i32{null} ** xll.SPEAKER_COUNT;
        for (0..xll.SPEAKER_COUNT) |s| spk_planes[s] = core_dec.speakerPlane(s);

        var xll_ok = false;
        var out_sr: u32 = frame.sample_rate;
        var out_mask: u32 = core_dec.ch_mask;
        if (xll_parse_ok) {
            if (xll_dec.filterFrame(&spk_planes)) {
                xll_ok = true;
                out_sr = xll_dec.outputSampleRate();
                storage = xll_dec.outputStorageBitRes();
                out_mask = xll_dec.outputMask();
            } else |err| {
                if (verbose) std.debug.print("unit {d} xll filter err {s}\n", .{ ui, @errorName(err) });
            }
        }

        if (ui < skip_units) {
            ui += 1;
            continue;
        }
        if (first_out) {
            std.debug.print("-- out: sr={d} storage={d} mask=0x{x} xll={}\n", .{ out_sr, storage, out_mask, xll_ok });
            first_out = false;
        }

        var pos: usize = 0;
        var nsamples_out: usize = 0;
        if (xll_ok) {
            nsamples_out = xll_dec.outputNsamples();
            var order: [8]u32 = undefined;
            const nch = coremod.remapOrder(out_mask, &order);
            for (0..nsamples_out) |n| {
                var c: usize = 0;
                while (c < nch) : (c += 1) {
                    const pl = xll_dec.plane(order[c]) orelse {
                        std.debug.print("missing xll plane for speaker {d}\n", .{order[c]});
                        return error.Corrupt;
                    };
                    var v = pl[n];
                    if (storage > 16) {
                        v = std.math.clamp(v, -(1 << 23), (1 << 23) - 1);
                        if (out_s16) {
                            std.mem.writeInt(i16, out_buf[pos..][0..2], @intCast(v >> 8), .little);
                            pos += 2;
                        } else {
                            std.mem.writeInt(i32, out_buf[pos..][0..4], v << 8, .little);
                            pos += 4;
                        }
                    } else {
                        v = std.math.clamp(v, -32768, 32767);
                        if (out_s16) {
                            std.mem.writeInt(i16, out_buf[pos..][0..2], @intCast(v), .little);
                            pos += 2;
                        } else {
                            std.mem.writeInt(i32, out_buf[pos..][0..4], @as(i32, @intCast(v)) << 16, .little);
                            pos += 4;
                        }
                    }
                }
            }
        } else {
            nsamples_out = frame.nsamples;
            for (0..frame.nsamples) |n| {
                for (0..frame.nch) |ch| {
                    const raw = frame.planes[ch][n];
                    // 与 ffmpeg filter_frame_fixed 一致：clip23 后再缩放
                    const v = std.math.clamp(raw, -(1 << 23), (1 << 23) - 1);
                    if (out_s16) {
                        std.mem.writeInt(i16, out_buf[pos..][0..2], @intCast(v >> 8), .little);
                        pos += 2;
                    } else {
                        std.mem.writeInt(i32, out_buf[pos..][0..4], v << 8, .little);
                        pos += 4;
                    }
                }
            }
        }
        writeStdout(out_buf[0..pos]) catch return error.WriteFailed;
        ui += 1;
    }
}

fn writeStdout(buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, buf[off..].ptr, buf.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// .dtshd 容器：定位 STRMDATA 载荷；裸流：原样
fn extractStreamPayload(buf: []const u8) ![]const u8 {
    if (buf.len < 8) return error.Corrupt;
    if (!std.mem.eql(u8, buf[0..8], "DTSHDHDR")) return buf;
    var off: usize = 0;
    while (off + 16 <= buf.len) {
        const tag = buf[off .. off + 8];
        const size = std.mem.readInt(u64, buf[off + 8 ..][0..8], .big);
        if (size < 4 or size > buf.len) return error.Corrupt;
        if (std.mem.eql(u8, tag, "STRMDATA")) {
            const start = off + 16;
            if (start + size > buf.len) return error.Corrupt;
            return buf[start .. start + @as(usize, @intCast(size))];
        }
        off += 16 + @as(usize, @intCast(size));
    }
    return error.Corrupt;
}

const Unit = struct {
    off: usize,
    core_len: usize,
    exss_off: ?usize,
    end: usize,
};

const core_sync_be = [_]u8{ 0x7F, 0xFE, 0x80, 0x01 };
const exss_sync_be = [_]u8{ 0x64, 0x58, 0x20, 0x25 };

fn coreFrameSize(payload: []const u8, off: usize) usize {
    // 帧头：sync32 + normal1 deficit5 crc1 npcm7 → frame_size14 自帧头 bit46
    var v: u64 = 0;
    for (0..8) |i| v = (v << 8) | payload[off + 4 + i];
    const fs = @as(usize, @intCast((v >> 36) & 0x3fff)) + 1;
    return fs;
}

fn collectUnits(a: std.mem.Allocator, payload: []const u8) ![]Unit {
    var list = std.ArrayList(Unit).empty;
    defer list.deinit(a);
    var starts = std.ArrayList(struct { off: usize, core_len: usize }).empty;
    defer starts.deinit(a);
    var i: usize = 0;
    while (i + 4 <= payload.len) : (i += 1) {
        if (std.mem.eql(u8, payload[i .. i + 4], &core_sync_be)) {
            try starts.append(a, .{ .off = i, .core_len = coreFrameSize(payload, i) });
            i += 4;
        }
    }
    for (starts.items, 0..) |s, k| {
        const end = if (k + 1 < starts.items.len) starts.items[k + 1].off else payload.len;
        var exss_off: ?usize = null;
        const core_end = s.off + s.core_len;
        var j = core_end;
        while (j + 4 <= end) : (j += 1) {
            if (std.mem.eql(u8, payload[j .. j + 4], &exss_sync_be)) {
                exss_off = j;
                break;
            }
        }
        const uend = if (exss_off != null) end else core_end;
        try list.append(a, .{ .off = s.off, .core_len = s.core_len, .exss_off = exss_off, .end = uend });
    }
    return list.toOwnedSlice(a);
}

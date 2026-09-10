// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DTS-HD 扩展子流（EXSS）解析（DTS-HD MA / HRA asset 描述）
//!
//! 对照 FFmpeg n9.0.1 dca_exss.c（ff_dca_exss_parse / parse_descriptor /
//! set_exss_offsets / parse_xll_parameters）。位流 MSB-first。
//!
//! 输入为一段自 EXSS sync（0x64582025）起的数据，size 为该子流的可用字节数
//! （通常即 exss_size，demux 层保证）。输出首个（唯一支持）asset 的各分量
//! 偏移/大小（均相对 EXSS 子流起点）。
//!
//! CRC16（header / asset descriptor）不校验 —— 位流中 CRC 不消费数据位，
//! 帧内读取位置只依赖 header_size/descr_size 字段，故与 FFmpeg 逐位一致。

const std = @import("std");
const BitReader = @import("../aac/bitreader.zig").BitReader;
const dt = @import("dca_tables.zig");

/// 与 dca.h DCA_EXSS_* 一致的扩展分量位
pub const ext_core: u16 = 0x010;
pub const ext_xbr: u16 = 0x020;
pub const ext_xxch: u16 = 0x040;
pub const ext_x96: u16 = 0x080;
pub const ext_lbr: u16 = 0x100;
pub const ext_xll: u16 = 0x200;

/// coding_mode（dca_exss.c asset->coding_mode）
pub const mode_multi: u8 = 0;
pub const mode_xll_only: u8 = 1;
pub const mode_lbr: u8 = 2;
pub const mode_aux: u8 = 3;

/// DCAExssAsset 移植（只留解码所需字段）
pub const Asset = struct {
    asset_offset: usize = 0,
    asset_size: usize = 0,
    asset_index: u8 = 0,

    pcm_bit_res: u8 = 0,
    max_sample_rate: u32 = 0,
    nchannels_total: u8 = 0,
    one_to_one_map_ch_to_spkr: bool = false,
    embedded_stereo: bool = false,
    embedded_6ch: bool = false,
    spkr_mask_enabled: bool = false,
    spkr_mask: u32 = 0,
    representation_type: u8 = 0,

    coding_mode: u8 = 0,
    extension_mask: u16 = 0,

    core_offset: usize = 0,
    core_size: usize = 0,
    xbr_offset: usize = 0,
    xbr_size: usize = 0,
    xxch_offset: usize = 0,
    xxch_size: usize = 0,
    x96_offset: usize = 0,
    x96_size: usize = 0,
    lbr_offset: usize = 0,
    lbr_size: usize = 0,
    xll_offset: usize = 0,
    xll_size: usize = 0,
    xll_sync_present: bool = false,
    xll_delay_nframes: u32 = 0,
    xll_sync_offset: usize = 0,

    hd_stream_id: u8 = 0,
};

pub const ParseError = error{ Corrupt, Unsupported, OutOfMemory };

fn rb(br: *BitReader, n: u6) ParseError!u32 {
    const v = br.readBits(n) catch return error.Corrupt;
    return v;
}

fn rb1(br: *BitReader) ParseError!u1 {
    const v = br.readBits(1) catch return error.Corrupt;
    return @intCast(v);
}

fn skipBits(br: *BitReader, n: u32) ParseError!void {
    return br.skipBits(n) catch error.Corrupt;
}

fn seekBits(br: *BitReader, bit_pos: usize) ParseError!void {
    if (bit_pos < br.bit_pos) return error.Corrupt;
    return skipBits(br, @intCast(bit_pos - br.bit_pos));
}

fn popcount(m: u32) usize {
    var mm = m;
    var c: usize = 0;
    while (mm != 0) : (mm >>= 1) c += @intCast(mm & 1);
    return c;
}

fn countForMask(mask: u32) usize {
    return popcount(mask);
}

fn parseXllParameters(br: *BitReader, a: *Asset, size_nbits: u6) ParseError!void {
    a.xll_size = (try rb(br, size_nbits)) + 1;
    a.xll_sync_present = (try rb1(br)) != 0;
    if (a.xll_sync_present) {
        _ = try rb(br, 4); // PBR buffer size
        const delay_nbits: u6 = @intCast((try rb(br, 5)) + 1);
        a.xll_delay_nframes = try rb(br, delay_nbits);
        a.xll_sync_offset = try rb(br, size_nbits);
    } else {
        a.xll_delay_nframes = 0;
        a.xll_sync_offset = 0;
    }
}

fn parseLbrParameters(br: *BitReader, a: *Asset) ParseError!void {
    a.lbr_size = (try rb(br, 14)) + 1;
    if ((try rb1(br)) != 0) _ = try rb(br, 2); // LBR sync distance
}

fn parseDescriptor(
    br: *BitReader,
    a: *Asset,
    static_fields: bool,
    mix_enabled: bool,
    n_mix: usize,
    nmixoutchs: []const u8,
    size_nbits: u6,
) ParseError!void {
    const descr_pos = br.bit_pos;
    const descr_size: usize = (try rb(br, 9)) + 1;

    a.asset_index = @intCast(try rb(br, 3));

    if (static_fields) {
        if ((try rb1(br)) != 0) _ = try rb(br, 4);
        if ((try rb1(br)) != 0) _ = try rb(br, 24);
        if ((try rb1(br)) != 0) {
            const tsize: u32 = (try rb(br, 10)) + 1;
            try skipBits(br, tsize * 8);
        }
        a.pcm_bit_res = @intCast((try rb(br, 5)) + 1);
        a.max_sample_rate = dt.ff_dca_sampling_freqs[@intCast(try rb(br, 4))];
        a.nchannels_total = @intCast((try rb(br, 8)) + 1);
        a.one_to_one_map_ch_to_spkr = (try rb1(br)) != 0;
        if (a.one_to_one_map_ch_to_spkr) {
            a.embedded_stereo = a.nchannels_total > 2 and (try rb1(br)) != 0;
            a.embedded_6ch = a.nchannels_total > 6 and (try rb1(br)) != 0;
            a.spkr_mask_enabled = (try rb1(br)) != 0;
            var spkr_mask_nbits: u6 = 0;
            if (a.spkr_mask_enabled) {
                spkr_mask_nbits = @as(u6, @intCast((try rb(br, 2)) + 1)) << 2;
                a.spkr_mask = try rb(br, spkr_mask_nbits);
            }
            const n_remap: usize = try rb(br, 3);
            if (n_remap != 0 and !a.spkr_mask_enabled) return error.Corrupt;
            var nspeakers: [8]usize = undefined;
            for (0..n_remap) |i| nspeakers[i] = countForMask(try rb(br, spkr_mask_nbits));
            for (0..n_remap) |i| {
                const nch: u6 = @intCast((try rb(br, 5)) + 1);
                var j: usize = 0;
                while (j < nspeakers[i]) : (j += 1) {
                    const m = try rb(br, nch);
                    try skipBits(br, @as(u32, @intCast(popcount(m))) * 5);
                }
            }
        } else {
            a.embedded_stereo = false;
            a.embedded_6ch = false;
            a.spkr_mask_enabled = false;
            a.spkr_mask = 0;
            a.representation_type = @intCast(try rb(br, 3));
        }
    }

    // DRC / 对白归一 / 混音元数据
    const drc_present = (try rb1(br)) != 0;
    if (drc_present) _ = try rb(br, 8);
    if ((try rb1(br)) != 0) _ = try rb(br, 5);
    if (drc_present and a.embedded_stereo) _ = try rb(br, 8);

    if (mix_enabled and (try rb1(br)) != 0) {
        _ = try rb1(br);
        _ = try rb(br, 6);
        if ((try rb(br, 2)) == 3)
            _ = try rb(br, 8)
        else
            _ = try rb(br, 3);

        var nchannels_dmix: usize = a.nchannels_total;
        if (a.embedded_6ch) nchannels_dmix += 6;
        if (a.embedded_stereo) nchannels_dmix += 2;

        if ((try rb1(br)) != 0) {
            for (0..n_mix) |i| try skipBits(br, 6 * @as(u32, nmixoutchs[i]));
        } else {
            try skipBits(br, 6 * @as(u32, @intCast(n_mix)));
        }
        for (0..n_mix) |i| {
            var j: usize = 0;
            while (j < nchannels_dmix) : (j += 1) {
                const m = try rb(br, @intCast(nmixoutchs[i]));
                try skipBits(br, @as(u32, @intCast(popcount(m))) * 6);
            }
        }
    }

    a.coding_mode = @intCast(try rb(br, 2));
    switch (a.coding_mode) {
        mode_multi => {
            a.extension_mask = @intCast(try rb(br, 12));
            if (a.extension_mask & ext_core != 0) {
                a.core_size = (try rb(br, 14)) + 1;
                if ((try rb1(br)) != 0) _ = try rb(br, 2);
            }
            if (a.extension_mask & ext_xbr != 0) a.xbr_size = (try rb(br, 14)) + 1;
            if (a.extension_mask & ext_xxch != 0) a.xxch_size = (try rb(br, 14)) + 1;
            if (a.extension_mask & ext_x96 != 0) a.x96_size = (try rb(br, 12)) + 1;
            if (a.extension_mask & ext_lbr != 0) try parseLbrParameters(br, a);
            if (a.extension_mask & ext_xll != 0) try parseXllParameters(br, a, size_nbits);
            if (a.extension_mask & 0x400 != 0) _ = try rb(br, 16);
            if (a.extension_mask & 0x800 != 0) _ = try rb(br, 16);
        },
        mode_xll_only => {
            a.extension_mask = ext_xll;
            try parseXllParameters(br, a, size_nbits);
        },
        mode_lbr => {
            a.extension_mask = ext_lbr;
            try parseLbrParameters(br, a);
        },
        mode_aux => {
            a.extension_mask = 0;
            _ = try rb(br, 14);
            _ = try rb(br, 8);
            if ((try rb1(br)) != 0) _ = try rb(br, 3);
        },
        else => return error.Corrupt,
    }

    if (a.extension_mask & ext_xll != 0) a.hd_stream_id = @intCast(try rb(br, 3));

    // 跳到 descriptor 末尾（其余为一对一混音标志/保留/补零）
    return seekBits(br, descr_pos + descr_size * 8);
}

/// 解析整个 EXSS 子流。size = 可用字节数。成功后 a 填充首个 asset。
pub fn parse(buf: []const u8, a: *Asset) ParseError!void {
    var br = BitReader.init(buf);
    if (buf.len < 6) return error.Corrupt;
    if (try rb(&br, 32) != 0x64582025) return error.Corrupt;

    _ = try rb(&br, 8); // user defined bits
    const exss_index: u8 = @intCast(try rb(&br, 2));
    const wide_hdr = (try rb1(&br)) != 0;
    const header_size: usize = (try rb(&br, if (wide_hdr) @as(u6, 12) else 8)) + 1;

    const size_nbits: u6 = if (wide_hdr) 20 else 16;
    const exss_size: usize = (try rb(&br, size_nbits)) + 1;
    if (exss_size > buf.len) return error.Corrupt;

    const static_fields = (try rb1(&br)) != 0;
    var n_assets: usize = 1;
    var n_presents: usize = 1;
    var mix_enabled = false;
    var n_mix: usize = 0;
    var nmixoutchs: [4]u8 = undefined;
    if (static_fields) {
        _ = try rb(&br, 2);
        _ = try rb(&br, 3);
        if ((try rb1(&br)) != 0) _ = try rb(&br, 36);
        n_presents = (try rb(&br, 3)) + 1;
        n_assets = (try rb(&br, 3)) + 1;
        if (n_presents > 1 or n_assets > 1) return error.Unsupported;

        var active: [1]u32 = undefined;
        for (0..n_presents) |i| active[i] = try rb(&br, @intCast(exss_index + 1));
        for (0..n_presents) |i| try skipBits(&br, @as(u32, @intCast(popcount(active[i]))) * 8);

        mix_enabled = (try rb1(&br)) != 0;
        if (mix_enabled) {
            _ = try rb(&br, 2);
            const spkr_nbits: u6 = @as(u6, @intCast((try rb(&br, 2)) + 1)) << 2;
            n_mix = (try rb(&br, 2)) + 1;
            for (0..n_mix) |i| nmixoutchs[i] = @intCast(countForMask(try rb(&br, spkr_nbits)));
        }
    }

    // asset 尺寸
    var offset: usize = header_size;
    var asset_offset: usize = 0;
    var asset_size: usize = 0;
    for (0..n_assets) |_| {
        asset_offset = offset;
        asset_size = (try rb(&br, size_nbits)) + 1;
        offset += asset_size;
        if (offset > exss_size) return error.Corrupt;
    }
    a.asset_offset = asset_offset;
    a.asset_size = asset_size;

    try parseDescriptor(&br, a, static_fields, mix_enabled, n_mix, &nmixoutchs, size_nbits);

    // 设置分量偏移（顺序同 set_exss_offsets）
    var offs = a.asset_offset;
    var size = a.asset_size;
    if (a.extension_mask & ext_core != 0) {
        a.core_offset = offs;
        if (a.core_size > size) return error.Corrupt;
        offs += a.core_size;
        size -= a.core_size;
    }
    if (a.extension_mask & ext_xbr != 0) {
        a.xbr_offset = offs;
        if (a.xbr_size > size) return error.Corrupt;
        offs += a.xbr_size;
        size -= a.xbr_size;
    }
    if (a.extension_mask & ext_xxch != 0) {
        a.xxch_offset = offs;
        if (a.xxch_size > size) return error.Corrupt;
        offs += a.xxch_size;
        size -= a.xxch_size;
    }
    if (a.extension_mask & ext_x96 != 0) {
        a.x96_offset = offs;
        if (a.x96_size > size) return error.Corrupt;
        offs += a.x96_size;
        size -= a.x96_size;
    }
    if (a.extension_mask & ext_lbr != 0) {
        a.lbr_offset = offs;
        if (a.lbr_size > size) return error.Corrupt;
        offs += a.lbr_size;
        size -= a.lbr_size;
    }
    if (a.extension_mask & ext_xll != 0) {
        a.xll_offset = offs;
        if (a.xll_size > size) return error.Corrupt;
        offs += a.xll_size;
        size -= a.xll_size;
    }
}

const testing = std.testing;

test "exss: 非法数据" {
    var a: Asset = .{};
    try testing.expectError(error.Corrupt, parse("abcd", &a));
    var buf: [8]u8 = [_]u8{0} ** 8;
    try testing.expectError(error.Corrupt, parse(&buf, &a));
}

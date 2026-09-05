//! AAC 配置解析：AudioSpecificConfig（ISO 14496-3 §1.6.2.1）+ ADTS 帧头。
//!
//! 语义对齐 FFmpeg n9.0.1 mpeg4audio.c ff_mpeg4audio_get_config_gb 与
//! adts_header.c ff_adts_header_parse（参考对照非复制）：
//!   - get_object_type：5 位；31 (escape) → 32 + 6 位扩展；
//!   - get_sample_rate：4 位索引（0xF → 24 位显式值）；
//!   - 隐式 SBR/PS 信令（AOT 5 / 29 前置）与显式信令（sync extension 0x2b7）；
//!   - GASpecificConfig 的 frameLengthFlag（960/1024）；
//!   - ADTS：syncword/profile/sf_index/chan_config/frame_length/rdb，
//!     samples = (rdb+1)*1024；
//!   - sbr/ps 三态：-1 未声明 / 0 无 / 1 有——内核当前仅支持无 SBR/PS 的
//!     AAC-LC（其余 UnsupportedFormat 回退 FFmpeg 主后端，§8.3）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const brmod = @import("bitreader.zig");
const t = @import("tables.zig");

// Audio Object Type（ISO 14496-3 Table 1.56 子集）
pub const AOT_ESCAPE: u8 = 31;
pub const AOT_NULL: u8 = 0;
pub const AOT_AAC_MAIN: u8 = 1;
pub const AOT_AAC_LC: u8 = 2;
pub const AOT_AAC_SSR: u8 = 3;
pub const AOT_AAC_LTP: u8 = 4;
pub const AOT_SBR: u8 = 5;
pub const AOT_ER_AAC_LC: u8 = 17;
pub const AOT_ER_BSAC: u8 = 22;
pub const AOT_PS: u8 = 29;
pub const AOT_ALS: u8 = 36;
pub const AOT_ER_AAC_ELD: u8 = 39;
pub const AOT_USAC: u8 = 42;

pub const M4ACfg = struct {
    object_type: u8 = 0,
    sample_rate: u32 = 0,
    sampling_index: u4 = 0,
    /// 24 位显式采样率标志
    sampling_explicit: bool = false,
    chan_config: u4 = 0,
    channels: u8 = 0,
    /// -1 未声明 / 0 无 / 1 有
    sbr: i8 = -1,
    ps: i8 = -1,
    ext_object_type: u8 = AOT_NULL,
    ext_sample_rate: u32 = 0,
    ext_sampling_index: u4 = 0,
    ext_chan_config: u4 = 0,
    frame_length_short: bool = false,
    frame_length: u16 = 1024,

    /// HE-AAC v1/v2（SBR 或 PS 存在）——内核暂不支持，回退 FFmpeg
    pub fn isHeAac(self: *const M4ACfg) bool {
        return self.sbr == 1 or self.ps == 1;
    }
};

fn getObject(br: *brmod.BitReader) Error!u8 {
    var ot: u8 = @intCast(try br.readBits(5));
    if (ot == AOT_ESCAPE) ot = @intCast(@as(u32, 32) + try br.readBits(6));
    return ot;
}

fn getSampleRate(br: *brmod.BitReader, index: *u4, explicit: *bool) Error!u32 {
    const idx: u4 = @intCast(try br.readBits(4));
    index.* = idx;
    if (idx == 0xF) {
        explicit.* = true;
        return try br.readBits(24);
    }
    explicit.* = false;
    return t.sample_rates[idx];
}

pub const AscResult = struct { cfg: M4ACfg, payload_bit_offset: usize };

/// 解析 AudioSpecificConfig，返回配置与 raw_data_block 起始位偏移。
/// `sync_extension` 允许扫描显式 SBR/PS 信令（m4a extradata 场景）。
pub fn parseAsc(data: []const u8, sync_extension: bool) Error!AscResult {
    var br = brmod.BitReader.init(data);
    return parseAscBr(&br, sync_extension);
}

pub fn parseAscBr(br: *brmod.BitReader, sync_extension: bool) Error!AscResult {
    const start_bit = br.bit_pos;
    var c: M4ACfg = .{};

    c.object_type = try getObject(br);
    c.sample_rate = try getSampleRate(br, &c.sampling_index, &c.sampling_explicit);
    if (c.sample_rate == 0) return error.Corrupt;

    c.chan_config = @intCast(try br.readBits(4));
    if (c.chan_config >= t.channels.len) return error.Corrupt;
    c.channels = t.channels[c.chan_config];

    c.sbr = -1;
    c.ps = -1;

    // 隐式 SBR/PS 信令（AOT 5 / 29 前置；W6132 MP3onMP4 检查）
    const implicit_sbr = c.object_type == AOT_SBR or blk: {
        if (c.object_type != AOT_PS) break :blk false;
        // !(show(3)&0x03 && !(show(9)&0x3F))
        const s3 = try br.showBits(3);
        const s9 = try br.showBits(9);
        break :blk !((s3 & 0x03 != 0) and (s9 & 0x3F == 0));
    };
    if (implicit_sbr) {
        if (c.object_type == AOT_PS) c.ps = 1;
        c.ext_object_type = AOT_SBR;
        c.sbr = 1;
        c.ext_sample_rate = try getSampleRate(br, &c.ext_sampling_index, &c.sampling_explicit);
        c.object_type = try getObject(br);
        if (c.object_type == AOT_ER_BSAC)
            c.ext_chan_config = @intCast(try br.readBits(4));
    }

    const payload_offset = br.bit_pos - start_bit;

    // GASpecificConfig（对照 ffmpeg decode_ga_specific_config）：
    // frameLengthFlag + dependsOnCoreCoder(1) [+ coreCoderDelay(14)] + extensionFlag(1)
    // + [layerNr(3)，SCALABLE]
    switch (c.object_type) {
        AOT_AAC_MAIN, AOT_AAC_LC, AOT_AAC_SSR, AOT_AAC_LTP, AOT_ER_AAC_LC => {
            c.frame_length_short = (try br.readBits(1)) != 0;
            c.frame_length = if (c.frame_length_short) 960 else 1024;
            if ((try br.readBits(1)) != 0) _ = try br.skipBits(14); // dependsOnCoreCoder + coreCoderDelay
            _ = try br.readBits(1); // extensionFlag（其后的 SBR/PS sync extension 由下方扫描处理）
        },
        else => {},
    }

    // 显式信令（sync extension）
    if (c.ext_object_type != AOT_SBR and sync_extension) {
        while (br.remainingBits() > 15) {
            const peek = try br.showBits(11);
            if (peek == 0x2b7) {
                _ = try br.readBits(11);
                c.ext_object_type = try getObject(br);
                if (c.ext_object_type == AOT_SBR) {
                    c.sbr = if ((try br.readBits(1)) != 0) 1 else 0;
                    if (c.sbr == 1) {
                        c.ext_sample_rate = try getSampleRate(br, &c.ext_sampling_index, &c.sampling_explicit);
                        if (c.ext_sample_rate == c.sample_rate) c.sbr = -1;
                    }
                }
                if (br.remainingBits() > 11 and (try br.readBits(11)) == 0x548)
                    c.ps = if ((try br.readBits(1)) != 0) 1 else 0;
                break;
            } else {
                _ = try br.readBits(1); // skip
            }
        }
    }

    // PS requires SBR
    if (c.sbr == 0) c.ps = 0;
    // 隐式 PS 仅限 HE-AACv2 单声道
    if ((c.ps == -1 and c.object_type != AOT_AAC_LC) or (c.channels & ~@as(u8, 0x01)) != 0)
        c.ps = 0;

    return .{ .cfg = c, .payload_bit_offset = payload_offset };
}

// ---------------- ADTS ----------------

pub const AdtsHeader = struct {
    /// profile + 1
    object_type: u8 = 0,
    sampling_index: u4 = 0,
    sample_rate: u32 = 0,
    chan_config: u4 = 0,
    crc_absent: bool = true,
    /// number_of_raw_data_blocks_in_frame + 1
    num_aac_frames: u8 = 1,
    /// 完整 ADTS 帧长（含头）
    frame_length: u16 = 0,
    /// 每帧样本数 (rdb+1)*1024
    samples: u16 = 1024,

    pub const header_size = 7;
};

/// 解析 7 字节 ADTS 固定+可变头（不含 CRC 扩展）。同步字不匹配 → error.Corrupt。
pub fn parseAdts(data: []const u8) Error!AdtsHeader {
    if (data.len < AdtsHeader.header_size) return error.Corrupt;
    var br = brmod.BitReader.init(data[0..AdtsHeader.header_size]);

    if ((try br.readBits(12)) != 0xfff) return error.Corrupt;
    _ = try br.readBits(1); // id（MPEG-4=0/MPEG-2=1，均接受）
    const layer = try br.readBits(2);
    if (layer != 0) return error.Corrupt; // AAC 层必须为 0
    const crc_absent = (try br.readBits(1)) != 0;
    const aot: u8 = @intCast((try br.readBits(2)) + 1);
    const sr_idx: u4 = @intCast(try br.readBits(4));
    if (t.sample_rates[sr_idx] == 0) return error.Corrupt;
    _ = try br.readBits(1); // private_bit
    const ch: u4 = @intCast(try br.readBits(3));
    _ = try br.readBits(2); // original/copy, home
    _ = try br.readBits(2); // copyright_identification_bit/start
    const size: u16 = @intCast(try br.readBits(13));
    if (size < AdtsHeader.header_size) return error.Corrupt;
    _ = try br.readBits(11); // adts_buffer_fullness
    const rdb: u8 = @intCast(try br.readBits(2));

    return .{
        .object_type = aot,
        .sampling_index = sr_idx,
        .sample_rate = t.sample_rates[sr_idx],
        .chan_config = ch,
        .crc_absent = crc_absent,
        .num_aac_frames = rdb + 1,
        .frame_length = size,
        .samples = (@as(u16, rdb) + 1) * 1024,
    };
}

// ---------------- 测试 ----------------

const testing = std.testing;

/// 测试用 MSB-first 位写入器
const BitWriter = struct {
    buf: [64]u8 = [_]u8{0} ** 64,
    pos: usize = 0,

    fn put(self: *BitWriter, value: u32, n: u6) void {
        var k: u6 = n;
        while (k > 0) {
            k -= 1;
            const bit: u1 = @intCast((value >> @intCast(k)) & 1);
            if (bit == 1) self.buf[self.pos >> 3] |= @as(u8, 1) << @intCast(7 - (self.pos & 7));
            self.pos += 1;
        }
    }
};

test "ASC: AAC-LC 立体声 44.1kHz" {
    var w: BitWriter = .{};
    w.put(2, 5); // object_type = LC
    w.put(4, 4); // sampling_index = 4 (44100)
    w.put(2, 4); // chan_config = 2 (stereo)
    w.put(0, 1); // frame_length_short = 0 (1024)

    const r = try parseAsc(w.buf[0..8], false);
    try testing.expectEqual(AOT_AAC_LC, r.cfg.object_type);
    try testing.expectEqual(@as(u32, 44100), r.cfg.sample_rate);
    try testing.expectEqual(@as(u4, 4), r.cfg.sampling_index);
    try testing.expectEqual(@as(u4, 2), r.cfg.chan_config);
    try testing.expectEqual(@as(u8, 2), r.cfg.channels);
    try testing.expectEqual(@as(i8, -1), r.cfg.sbr);
    try testing.expectEqual(@as(i8, 0), r.cfg.ps); // 多声道隐式 PS 关闭
    try testing.expectEqual(@as(u16, 1024), r.cfg.frame_length);
    // payload 起始于 GASpecificConfig 前（frameLengthFlag 不计入，对齐 FFmpeg specific_config_bitindex）
    try testing.expectEqual(@as(usize, 13), r.payload_bit_offset); // 5+4+4
}

test "ASC: escape 对象类型 + 24 位显式采样率" {
    var w: BitWriter = .{};
    w.put(AOT_ESCAPE, 5);
    w.put(2, 6); // 32 + 2 = 34 (XHE-AAC 等)
    w.put(0xF, 4);
    w.put(48000, 24);
    w.put(1, 4);

    const r = try parseAsc(w.buf[0..], false);
    try testing.expectEqual(@as(u8, 34), r.cfg.object_type);
    try testing.expectEqual(@as(u32, 48000), r.cfg.sample_rate);
    try testing.expectEqual(@as(u4, 0xF), r.cfg.sampling_index);
}

test "ASC: 显式 SBR 信令（sync extension）" {
    var w: BitWriter = .{};
    w.put(2, 5); // LC
    w.put(4, 4); // 44100
    w.put(1, 4); // mono
    w.put(0, 1); // frame_length_flag
    w.put(0, 1); // depends_on_core_coder
    w.put(0, 1); // extension_flag
    // sync extension
    w.put(0x2b7, 11);
    w.put(AOT_SBR, 5);
    w.put(1, 1); // sbr present
    w.put(3, 4); // ext sampling_index = 3 (48000)
    w.put(0x548, 11);
    w.put(1, 1); // ps present

    const r = try parseAsc(w.buf[0..], true);
    try testing.expect(r.cfg.isHeAac());
    try testing.expectEqual(@as(i8, 1), r.cfg.sbr);
    try testing.expectEqual(@as(i8, 1), r.cfg.ps);
    try testing.expectEqual(@as(u32, 48000), r.cfg.ext_sample_rate);
}

test "ASC: 隐式 SBR 前置（AOT 5 开头）" {
    // 字段顺序（FFmpeg mpeg4audio.c 解析序）：
    // AOT(5)=SBR → sf_index(4) → chan_cfg(4) → ext_sf_index(4) → 真实 AOT(5) → frameLengthFlag
    var w: BitWriter = .{};
    w.put(AOT_SBR, 5);
    w.put(4, 4); // base sampling index = 44100
    w.put(1, 4); // mono
    w.put(3, 4); // extension sampling index = 48000
    w.put(2, 5); // 真实对象类型 LC
    w.put(0, 1); // frame_length_flag
    w.put(0, 1); // depends_on_core_coder
    w.put(0, 1); // extension_flag

    const r = try parseAsc(w.buf[0..], false);
    try testing.expectEqual(AOT_AAC_LC, r.cfg.object_type);
    try testing.expectEqual(@as(u32, 44100), r.cfg.sample_rate);
    try testing.expectEqual(@as(i8, 1), r.cfg.sbr);
    try testing.expectEqual(@as(u32, 48000), r.cfg.ext_sample_rate);
    try testing.expectEqual(@as(u16, 1024), r.cfg.frame_length);
}

test "ADTS: 合成帧头往返" {
    var w: BitWriter = .{};
    w.put(0xfff, 12); // syncword
    w.put(0, 1); // MPEG-4
    w.put(0, 2); // layer
    w.put(1, 1); // protection_absent
    w.put(1, 2); // profile = LC - 1
    w.put(4, 4); // sf_index 44100
    w.put(0, 1); // private
    w.put(2, 3); // stereo
    w.put(0, 1); // original
    w.put(0, 1); // home
    w.put(0, 1); // copyright_id_bit
    w.put(0, 1); // copyright_id_start
    w.put(200, 13); // frame_length
    w.put(0x7ff, 11); // buffer fullness
    w.put(0, 2); // rdb = 0 → 1 block

    const hdr = try parseAdts(w.buf[0..7]);
    try testing.expectEqual(@as(u8, 2), hdr.object_type);
    try testing.expectEqual(@as(u32, 44100), hdr.sample_rate);
    try testing.expectEqual(@as(u4, 2), hdr.chan_config);
    try testing.expect(hdr.crc_absent);
    try testing.expectEqual(@as(u16, 1024), hdr.samples);
    try testing.expectEqual(@as(u16, 200), hdr.frame_length);
}

test "ADTS: 同步字错误拒绝" {
    const bad = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde };
    try testing.expectError(error.Corrupt, parseAdts(&bad));
}

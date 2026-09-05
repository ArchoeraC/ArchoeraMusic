//! AC-3 / E-AC-3 帧头解析（对照 FFmpeg ac3_parser.c ff_ac3_parse_header）
//!
//! 同步字 0x0B77；预读 29 位取 bitstream_id 区分 AC-3（bsid≤10）与 E-AC-3（16）。

const std = @import("std");
const BitReader = @import("../aac/bitreader.zig").BitReader;
const t = @import("tables.zig");

pub const Header = struct {
    sync_word: u16 = 0,
    crc1: u16 = 0,
    sr_code: u8 = 0,
    bitstream_id: u8 = 0,
    bitstream_mode: u8 = 0,
    channel_mode: u8 = 0,
    lfe_on: u8 = 0,
    frame_type: u8 = 0,
    substreamid: i32 = 0,
    center_mix_level: i32 = 0,
    surround_mix_level: i32 = 0,
    channel_map_present: u8 = 0,
    channel_map: u16 = 0,
    num_blocks: i32 = 0,
    dolby_surround_mode: i32 = 0,
    sr_shift: u8 = 0,
    sample_rate: u32 = 0,
    bit_rate: u32 = 0,
    channels: u8 = 0,
    frame_size: u16 = 0,
    ac3_bit_rate_code: i8 = 0,
    dialog_normalization: [2]i8 = .{ 0, 0 },
    compression_exists: [2]u8 = .{ 0, 0 },
    heavy_dynamic_range: [2]u8 = .{ 0, 0 },
    center_mix_level_ltrt: u8 = 0,
    surround_mix_level_ltrt: u8 = 0,
    dolby_headphone_mode: u8 = 0,
    dolby_surround_ex_mode: u8 = 0,
    lfe_mix_level_exists: u8 = 0,
    lfe_mix_level: u8 = 0,
    preferred_downmix: u8 = 0,
    eac3_extension_type_a: u8 = 0,
    complexity_index_type_a: u8 = 0,
    /// 帧头已消费位数（decode_audio_block 从该位开始）
    consumed_bits: usize = 0,
};

pub const ParseError = error{ Sync, Bsid, SampleRate, FrameSize, FrameType, ChannelMap, Corrupt };

const eac3_blocks = [4]u8{ 1, 2, 3, 6 };
const center_levels = [4]u8{ 4, 5, 6, 5 };
const surround_levels = [4]u8{ 4, 6, 7, 6 };

fn clip3(a: i32, mn: i32, mx: i32) i32 {
    return std.math.clamp(a, mn, mx);
}

/// AC-3 的 bsi 剩余部分（双单声道时读两次）
fn parseAc3Bsi(gb: *BitReader, hdr: *Header) ParseError!void {
    var i: usize = 0;
    while (i < (if (hdr.channel_mode != 0) @as(usize, 1) else 2)) : (i += 1) {
        hdr.dialog_normalization[i] = -@as(i8, @intCast(gb.readBits(5) catch return error.Corrupt));
        hdr.compression_exists[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
        if (hdr.compression_exists[i] != 0)
            hdr.heavy_dynamic_range[i] = @intCast(gb.readBits(8) catch return error.Corrupt);
        if ((gb.readBits(1) catch return error.Corrupt) != 0) {
            _ = gb.readBits(8) catch return error.Corrupt; // langcod
        }
        if ((gb.readBits(1) catch return error.Corrupt) != 0) {
            _ = gb.readBits(7) catch return error.Corrupt; // audprodie
        }
    }
    _ = gb.readBits(2) catch return error.Corrupt; // copyright/original

    if (hdr.bitstream_id != 6) {
        if ((gb.readBits(1) catch return error.Corrupt) != 0) {
            _ = gb.readBits(14) catch return error.Corrupt;
        }
        if ((gb.readBits(1) catch return error.Corrupt) != 0) {
            _ = gb.readBits(14) catch return error.Corrupt;
        }
    } else {
        if ((gb.readBits(1) catch return error.Corrupt) != 0) {
            hdr.preferred_downmix = @intCast(gb.readBits(2) catch return error.Corrupt);
            hdr.center_mix_level_ltrt = @intCast(gb.readBits(3) catch return error.Corrupt);
            hdr.surround_mix_level_ltrt = @intCast(clip3(@as(i32, @intCast(gb.readBits(3) catch return error.Corrupt)), 3, 7));
            hdr.center_mix_level = @intCast(gb.readBits(3) catch return error.Corrupt);
            hdr.surround_mix_level = @intCast(clip3(@as(i32, @intCast(gb.readBits(3) catch return error.Corrupt)), 3, 7));
        }
        if ((gb.readBits(1) catch return error.Corrupt) != 0) {
            hdr.dolby_surround_ex_mode = @intCast(gb.readBits(2) catch return error.Corrupt);
            hdr.dolby_headphone_mode = @intCast(gb.readBits(2) catch return error.Corrupt);
            _ = gb.readBits(10) catch return error.Corrupt;
        }
    }

    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        var j: i32 = @intCast(gb.readBits(6) catch return error.Corrupt);
        while (j >= 0) : (j -= 1) {
            _ = gb.readBits(8) catch return error.Corrupt;
        }
    }
}

/// 从帧首字节解析头（buf 至少 8 字节，通常给整帧）。
pub fn parse(buf: []const u8) ParseError!Header {
    var hdr: Header = .{};
    var gb = BitReader.init(buf);
    hdr.sync_word = @intCast(gb.readBits(16) catch return error.Sync);
    if (hdr.sync_word != 0x0B77) return error.Sync;

    // 预读 29 位取 bsid（crc1(16)+sr_code(2)+frmsizecod(6)+bsid(5)）
    hdr.bitstream_id = @intCast((gb.showBits(29) catch return error.Corrupt) & 0x1F);
    if (hdr.bitstream_id > 16) return error.Bsid;

    hdr.num_blocks = 6;
    hdr.ac3_bit_rate_code = -1;
    hdr.center_mix_level = 5;
    hdr.surround_mix_level = 6;
    hdr.dolby_surround_mode = t.AC3_DSURMOD_NOTINDICATED;

    if (hdr.bitstream_id <= 10) {
        // 标准 AC-3
        hdr.crc1 = @intCast(gb.readBits(16) catch return error.Corrupt);
        hdr.sr_code = @intCast(gb.readBits(2) catch return error.Corrupt);
        if (hdr.sr_code == 3) return error.SampleRate;
        const frame_size_code: u32 = gb.readBits(6) catch return error.Corrupt;
        if (frame_size_code > 37) return error.FrameSize;
        hdr.ac3_bit_rate_code = @intCast(frame_size_code >> 1);
        _ = gb.readBits(5) catch return error.Corrupt; // bsid（已预读）
        hdr.bitstream_mode = @intCast(gb.readBits(3) catch return error.Corrupt);
        hdr.channel_mode = @intCast(gb.readBits(3) catch return error.Corrupt);
        if (hdr.channel_mode == t.AC3_CHMODE_STEREO) {
            hdr.dolby_surround_mode = @intCast(gb.readBits(2) catch return error.Corrupt);
        } else {
            if ((hdr.channel_mode & 1) != 0 and hdr.channel_mode != t.AC3_CHMODE_MONO) {
                hdr.center_mix_level = center_levels[gb.readBits(2) catch return error.Corrupt];
            }
            if ((hdr.channel_mode & 4) != 0) {
                hdr.surround_mix_level = surround_levels[gb.readBits(2) catch return error.Corrupt];
            }
        }
        hdr.lfe_on = @intCast(gb.readBits(1) catch return error.Corrupt);
        hdr.sr_shift = @max(hdr.bitstream_id, 8) - 8;
        hdr.sample_rate = t.sample_rate_tab[hdr.sr_code] >> @as(u4, @intCast(hdr.sr_shift));
        hdr.bit_rate = (@as(u32, t.bitrate_tab[@as(usize, @intCast(hdr.ac3_bit_rate_code))]) * 1000) >> @as(u4, @intCast(hdr.sr_shift));
        hdr.channels = t.channels_tab[hdr.channel_mode] + hdr.lfe_on;
        hdr.frame_size = @as(u16, t.frame_size_tab[frame_size_code][hdr.sr_code]) * 2;
        hdr.frame_type = t.EAC3_FRAME_TYPE_AC3_CONVERT;
        hdr.substreamid = 0;
        try parseAc3Bsi(&gb, &hdr);
    } else {
        // E-AC-3（Dolby Digital Plus）
        hdr.crc1 = 0;
        hdr.frame_type = @intCast(gb.readBits(2) catch return error.Corrupt);
        if (hdr.frame_type == t.EAC3_FRAME_TYPE_RESERVED) return error.FrameType;
        hdr.substreamid = @intCast(gb.readBits(3) catch return error.Corrupt);
        hdr.frame_size = @intCast((@as(u32, gb.readBits(11) catch return error.Corrupt) + 1) << 1);
        if (hdr.frame_size < 8) return error.FrameSize;        hdr.sr_code = @intCast(gb.readBits(2) catch return error.Corrupt);
        if (hdr.sr_code == 3) {
            const sr_code2: u32 = gb.readBits(2) catch return error.Corrupt;
            if (sr_code2 == 3) return error.SampleRate;
            hdr.sample_rate = t.sample_rate_tab[sr_code2] / 2;
            hdr.sr_shift = 1;
        } else {
            hdr.num_blocks = eac3_blocks[gb.readBits(2) catch return error.Corrupt];
            hdr.sample_rate = t.sample_rate_tab[hdr.sr_code];
            hdr.sr_shift = 0;
        }
        hdr.channel_mode = @intCast(gb.readBits(3) catch return error.Corrupt);
        hdr.lfe_on = @intCast(gb.readBits(1) catch return error.Corrupt);
        hdr.bit_rate = @intCast(8 * @as(u64, hdr.frame_size) * hdr.sample_rate /
            (@as(u64, @intCast(hdr.num_blocks)) * 256));
        hdr.channels = t.channels_tab[hdr.channel_mode] + hdr.lfe_on;
        try parseEac3Bsi(&gb, &hdr);
    }
    hdr.consumed_bits = gb.bit_pos;
    return hdr;
}

/// E-AC-3 的 bsi 剩余部分（对照 eac3_parse_header）
fn parseEac3Bsi(gb: *BitReader, hdr: *Header) ParseError!void {
    _ = gb.readBits(5) catch return error.Corrupt; // bitstream id（已预读）

    // 音量控制
    var i: usize = 0;
    while (i < (if (hdr.channel_mode != 0) @as(usize, 1) else 2)) : (i += 1) {
        hdr.dialog_normalization[i] = -@as(i8, @intCast(gb.readBits(5) catch return error.Corrupt));
        hdr.compression_exists[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
        if (hdr.compression_exists[i] != 0)
            hdr.heavy_dynamic_range[i] = @intCast(gb.readBits(8) catch return error.Corrupt);
    }

    // 依赖流声道映射
    if (hdr.frame_type == t.EAC3_FRAME_TYPE_DEPENDENT) {
        hdr.channel_map_present = @intCast(gb.readBits(1) catch return error.Corrupt);
        if (hdr.channel_map_present != 0) {
            hdr.channel_map = @intCast(gb.readBits(16) catch return error.Corrupt);
        }
    }

    // 混音元数据
    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        if (hdr.channel_mode > t.AC3_CHMODE_STEREO) {
            hdr.preferred_downmix = @intCast(gb.readBits(2) catch return error.Corrupt);
            if ((hdr.channel_mode & 1) != 0) {
                hdr.center_mix_level_ltrt = @intCast(gb.readBits(3) catch return error.Corrupt);
                hdr.center_mix_level = @intCast(gb.readBits(3) catch return error.Corrupt);
            }
            if ((hdr.channel_mode & 4) != 0) {
                hdr.surround_mix_level_ltrt = @intCast(clip3(@as(i32, @intCast(gb.readBits(3) catch return error.Corrupt)), 3, 7));
                hdr.surround_mix_level = @intCast(clip3(@as(i32, @intCast(gb.readBits(3) catch return error.Corrupt)), 3, 7));
            }
        }
        if (hdr.lfe_on != 0) {
            hdr.lfe_mix_level_exists = @intCast(gb.readBits(1) catch return error.Corrupt);
            if (hdr.lfe_mix_level_exists != 0)
                hdr.lfe_mix_level = @intCast(gb.readBits(5) catch return error.Corrupt);
        }
        if (hdr.frame_type == t.EAC3_FRAME_TYPE_INDEPENDENT) {
            i = 0;
            while (i < (if (hdr.channel_mode != 0) @as(usize, 1) else 2)) : (i += 1) {
                if ((gb.readBits(1) catch return error.Corrupt) != 0) {
                    _ = gb.readBits(6) catch return error.Corrupt; // program scale factor
                }
            }
            if ((gb.readBits(1) catch return error.Corrupt) != 0) {
                _ = gb.readBits(6) catch return error.Corrupt; // external program scale factor
            }
            switch (gb.readBits(2) catch return error.Corrupt) {
                1 => _ = gb.readBits(5) catch return error.Corrupt,
                2 => _ = gb.readBits(12) catch return error.Corrupt,
                3 => {
                    const mix_data_size = ((gb.readBits(5) catch return error.Corrupt) + 2) << 3;
                    _ = gb.readBits(@intCast(mix_data_size)) catch return error.Corrupt;
                },
                else => {},
            }
            if (hdr.channel_mode < t.AC3_CHMODE_STEREO) {
                i = 0;
                while (i < (if (hdr.channel_mode != 0) @as(usize, 1) else 2)) : (i += 1) {
                    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
                        _ = gb.readBits(8) catch return error.Corrupt;
                        _ = gb.readBits(6) catch return error.Corrupt;
                    }
                }
            }
            if ((gb.readBits(1) catch return error.Corrupt) != 0) {
                var blk: usize = 0;
                while (blk < @as(usize, @intCast(hdr.num_blocks))) : (blk += 1) {
                    if (hdr.num_blocks == 1 or (gb.readBits(1) catch return error.Corrupt) != 0) {
                        _ = gb.readBits(5) catch return error.Corrupt;
                    }
                }
            }
        }
    }

    // 信息元数据
    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        hdr.bitstream_mode = @intCast(gb.readBits(3) catch return error.Corrupt);
        _ = gb.readBits(2) catch return error.Corrupt; // copyright/original
        if (hdr.channel_mode == t.AC3_CHMODE_STEREO) {
            hdr.dolby_surround_mode = @intCast(gb.readBits(2) catch return error.Corrupt);
            hdr.dolby_headphone_mode = @intCast(gb.readBits(2) catch return error.Corrupt);
        }
        if (hdr.channel_mode >= t.AC3_CHMODE_2F2R) {
            hdr.dolby_surround_ex_mode = @intCast(gb.readBits(2) catch return error.Corrupt);
        }
        i = 0;
        while (i < (if (hdr.channel_mode != 0) @as(usize, 1) else 2)) : (i += 1) {
            if ((gb.readBits(1) catch return error.Corrupt) != 0) {
                _ = gb.readBits(8) catch return error.Corrupt;
            }
        }
        if (hdr.sr_code != t.EAC3_SR_CODE_REDUCED) {
            _ = gb.readBits(1) catch return error.Corrupt;
        }
    }

    // 转换器同步标志（num_blocks<6 时）
    if (hdr.frame_type == t.EAC3_FRAME_TYPE_INDEPENDENT and hdr.num_blocks != 6) {
        _ = gb.readBits(1) catch return error.Corrupt;
    }

    // 原始帧大小码（AC-3 转换）
    if (hdr.frame_type == t.EAC3_FRAME_TYPE_AC3_CONVERT and
        (hdr.num_blocks == 6 or (gb.readBits(1) catch return error.Corrupt) != 0))
    {
        _ = gb.readBits(6) catch return error.Corrupt;
    }

    // 附加位流信息（含 Atmos 扩展类型）
    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        const addbsil: u32 = gb.readBits(6) catch return error.Corrupt;
        i = 0;
        while (i < @as(usize, @intCast(addbsil)) + 1) : (i += 1) {
            if (i == 0) {
                _ = gb.readBits(7) catch return error.Corrupt;
                hdr.eac3_extension_type_a = @intCast(gb.readBits(1) catch return error.Corrupt);
                if (hdr.eac3_extension_type_a != 0) {
                    hdr.complexity_index_type_a = @intCast(gb.readBits(8) catch return error.Corrupt);
                    i += 1;
                }
            } else {
                _ = gb.readBits(8) catch return error.Corrupt;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "ac3: 帧头解析" {
    // 用真实 test.ac3 首帧前 64 字节（44.1kHz, 448kbps, 立体声）
    const data = @embedFile("test_head.bin");
    const h = try parse(data);
    try std.testing.expectEqual(@as(u32, 44100), h.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), h.channels);
    try std.testing.expectEqual(@as(u8, 2), h.channel_mode);
    try std.testing.expect(h.frame_size == 1950 or h.frame_size == 1952);
}

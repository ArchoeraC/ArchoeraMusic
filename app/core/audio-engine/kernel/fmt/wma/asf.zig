// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ASF（Advanced Systems Format）容器解析——WMA v1/v2 层（阶段 A）。
//!
//! 本模块只做：ASF Header 解析（File Properties + 音频 Stream Properties →
//! WAVEFORMATEX 参数）并定位 Data Object；数据包去包与 WMA 帧重组在后续阶段。
//! 布局对齐 FFmpeg libavformat/asfdec_f.c + libavcodec/wmadec.c（GUID 字节序按
//! ff_asf_guid 字面量，[0..16] 直接 eql）。

const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const asf_header_guid = [16]u8{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };
const asf_file_props_guid = [16]u8{ 0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };
const asf_stream_props_guid = [16]u8{ 0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };
const asf_audio_stream_guid = [16]u8{ 0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B };
const asf_data_header_guid = [16]u8{ 0x36, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };

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

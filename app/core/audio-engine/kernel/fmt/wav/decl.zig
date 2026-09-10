// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 格式声明解析（docs/audio-kernel-zig.md §9.1）
//!
//! 解析 WAV `fmt ` chunk（含 WAVEFORMATEXTENSIBLE）与 AIFF `COMM` chunk
//! （含 AIFF-C 压缩类型与 80-bit extended 采样率），统一产出 `WavFmt`：
//!   - 编码判定：PCM 整数 / IEEE float / A-LAW / mu-LAW / ADPCM
//!     （IMA WAV tag 0x11、MS tag 2、OKI tag 0x10/0x17、Yamaha tag 0x20、
//!     Creative CT tag 0x200、AIFF-C "ima4"）；其余 → UnsupportedFormat，
//!     引擎回退 FFmpeg，§8.3；
//!   - 字节序：RIFX 与 AIFF 为 big-endian，RIFF/RF64/W64/AIFC-"sowt" 为 little；
//!     WAV 8-bit PCM 为**无符号**（pcm_u8），AIFF 8-bit 为**有符号**（pcm_s8），
//!     AIFC-"raw " 才是无符号 —— 由调用方依据容器 + tag 决定 codec_name。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const gsm = @import("gsm.zig");
const mace = @import("mace.zig");

/// 编码类别（决定 read 路径：PCM 直通 vs G.711 解码 vs ADPCM 块/连续流解码）
pub const Codec = enum {
    pcm_int,
    pcm_float,
    /// F16LE（tag 1 + bits 32 + block_align ch*4 + extradata 2B [01 00]）：
    /// 4 字节槽位 le32（float32 位模式）× 2⁻¹⁵，输出 f32（镜像 FFmpeg pcm_f16le）
    pcm_f16,
    /// F24LE（tag 1 + bits 24 + block_align ch*4）：4 字节槽位 le32 × 2⁻²³，输出 f32
    pcm_f24,
    alaw,
    mulaw,
    adpcm_ms,
    adpcm_ima,
    adpcm_ima_qt,
    adpcm_oki,
    adpcm_yamaha,
    adpcm_ct,
    /// IMA DK4（tag 0x61）：块式 4B/通道头 + nibble 数据，≤2 声道
    adpcm_dk4,
    /// IMA DK3（tag 0x0062）：块式 10B 跳过 + 2×predictor(2B) + 2×step_index(1B)，
    /// sum/diff 立体声编解码（仅 2 声道），输出 s16（见 adpcm.zig decodeDk3）
    adpcm_dk3,
    /// XBOX ADPCM（tag 0x0069）：块式 4B/通道头（predictor + step_index），
    /// 每轮每通道 4B → 8 样本，输出每块减 1 样本，输出 s16
    adpcm_xbox,
    /// SANYO LD-ADPCM（tag 0x0125）：块式 4B/通道头（predictor + step），
    /// 位流 LSB 优先，每样本 bits(3/4/5) 位；每块样本数存于 fmt 扩展区 LE16
    adpcm_sanyo,
    /// XAN DPCM（tag 0x594A）：块式，每块 2B/通道 predictor 头 + 每字节 1 样本
    /// （声道交替），shift[2] 每块重置 {4,4}，输出 s16（见 dpcm.zig）
    xan,
    /// GSM 06.10：WAV tag 0x31/0x32/0x1500（GSM_MS，LSB 位序）+ AIFF-C "GSM "（纯 GSM，MSB）
    gsm,
    /// MACE（Macintosh Audio Compression/Expansion）：AIFC "MAC3"（3:1）/ "MAC6"（6:1），
    /// 块式（MAC3 2B/声道、MAC6 1B/声道，每块 6 样本/声道），输出 s16，≤2 声道
    mace3,
    mace6,
    /// ZORK DPCM（tag 0x0011 + bits==8，riffdec.c 289-290）：连续流，每字节
    /// 8-bit 控制量 → 1 交错样本，状态跨调用保持，输出 s16（见 adpcm.zig decodeZork）
    adpcm_zork,
    /// SWF ADPCM（tag 0x5346，riff.c 616）：MSB-first 位流（首 2 bit = nbits 2..5），
    /// 块头 22*ch bits，每块 ≤4096 样本/通道，状态跨调用保持，输出 s16
    adpcm_swf,
    /// G.722（tag 0x028F，riff.c 583）：每字节高 2 位 ihigh + 低 6 位 ilow →
    /// 2 帧 s16，仅单声道，状态跨调用保持
    adpcm_g722,
    /// G.726（tag 0x0045/0x0014/0x0040/0x0064，riff.c 550-562）：MSB-first 位流，
    /// 每样本 code_size 位 → 1 帧 s16；code_size = byte_rate*8/sample_rate 覆盖
    /// （riffdec.c 254-256），2..5；仅单声道，状态跨调用保持
    adpcm_g726,
};

/// 统一格式声明
pub const WavFmt = struct {
    codec: Codec,
    channels: u8,
    sample_rate: u32,
    /// 原生位深（PCM 8..64；alaw/mulaw = 8；pcm_f16/f24 为编码位深 16/24，输出恒 32）
    bits: u16,
    /// 一帧字节数（PCM: ch*bits/8；alaw/mulaw: ch）
    block_align: usize,
    /// fmt 扩展区（cbSize 字节，镜像 ff_get_wav_header 语义；上限 64）
    /// 当前仅 F16LE 判定需要（extradata_len == 2 && LE16 == 1）
    extradata: [64]u8 = .{0} ** 64,
    extradata_len: u8 = 0,
};

/// AIFF/AIFF-C 的 COMM 解析结果。
/// `tag` 为压缩类型四字符码（纯 AIFF 视为 "NONE"），调用方据此判定
/// 样本字节序（"sowt"=LE，其余=BE）与 8-bit 符号性（"raw "=unsigned，其余=signed）。
pub const AiffComm = struct {
    fmt: WavFmt,
    tag: [4]u8,
};

/// WAVEFORMATEXTENSIBLE 的 SubFormat GUID 尾段（12 字节，匹配即取 GUID 头 4 字节为 tag）。
/// 取值镜像 FFmpeg riff.h 的 FF_MEDIASUBTYPE_BASE_GUID / FF_AMBISONIC_BASE_GUID /
/// FF_BROKEN_BASE_GUID（重构参考，非直接使用）。
const mediasubtype_base_guid: [12]u8 = .{ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };
const ambisonic_base_guid: [12]u8 = .{ 0x21, 0x07, 0xD3, 0x11, 0x86, 0x44, 0xC8, 0xC1, 0xCA, 0x00, 0x00, 0x00 };
const broken_base_guid: [12]u8 = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA };

/// 解析 WAV `fmt ` chunk payload（csize >= 16）。含 EXTENSIBLE 时读扩展区并跳过
/// 剩余字节；未知子格式 / 非法字段 → error.UnsupportedFormat / error.Corrupt。
pub fn parseWavFmt(reader: *io.Reader, csize: u64, endian: std.builtin.Endian) Error!WavFmt {
    if (csize < 16) return error.Corrupt;
    var f: [16]u8 = undefined;
    if (!try readExact(reader, &f)) return error.Corrupt;

    var tag = readU16(f[0..2], endian);
    const channels = readU16(f[2..4], endian);
    const sample_rate = readU32(f[4..8], endian);
    // avg_bytes_per_sec（WAV 专用；G.726 code_size 覆盖依赖，riffdec.c 254-256）
    const byte_rate = readU32(f[8..12], endian);
    const block_align = readU16(f[12..14], endian);
    var bits = readU16(f[14..16], endian);
    var rest = csize - 16;

    var extradata: [64]u8 = .{0} ** 64;
    var extradata_len: u8 = 0;

    if (tag == 0xFFFE) {
        // WAVEFORMATEXTENSIBLE：cbSize(2) + wValidBits(2) + channelMask(4) + SubFormat GUID(16)
        if (rest < 24) return error.Corrupt;
        var ext: [24]u8 = undefined;
        if (!try readExact(reader, &ext)) return error.Corrupt;
        const valid_bits = readU16(ext[2..4], endian);
        if (valid_bits != 0) bits = valid_bits;
        const subformat = ext[8..24];
        tag = subformatTag(subformat) orelse return error.UnsupportedFormat;
        rest -= 24;
        // 22 字节扩展之后的 cbSize 余量作为 extradata（镜像 ff_get_extradata）
        const cb_size = readU16(ext[0..2], .little);
        const n = if (cb_size >= 22) @min(@as(u64, cb_size) - 22, rest) else 0;
        extradata_len = try readExtradata(reader, n, &extradata);
        rest -= n;
    } else if (endian == .little and rest >= 2) {
        // WAVEFORMATEX：cbSize(2) + extradata（LE；F16LE 判定依赖该区）
        var cb: [2]u8 = undefined;
        if (!try readExact(reader, &cb)) return error.Corrupt;
        const cb_size = readU16(&cb, .little);
        rest -= 2;
        // cbSize 封顶到剩余字节（镜像 FFmpeg cbSize = FFMIN(size, cbSize)）
        const n = @min(@as(u64, cb_size), rest);
        extradata_len = try readExtradata(reader, n, &extradata);
        rest -= n;
    }
    try skipBytes(reader, rest);

    return buildFmt(tag, channels, sample_rate, byte_rate, block_align, bits, extradata[0..extradata_len], endian);
}

/// 读取 fmt 扩展区（上限 64 字节，超出部分跳过），返回实际读入字节数
fn readExtradata(reader: *io.Reader, n: u64, out: *[64]u8) Error!u8 {
    const cap = @min(n, 64);
    if (cap > 0) {
        if (!try readExact(reader, out[0..@intCast(cap)])) return error.Corrupt;
    }
    if (n > cap) try skipBytes(reader, n - cap);
    return @intCast(cap);
}

/// 从 EXTENSIBLE SubFormat GUID 提取 format tag（匹配三大 base GUID 尾段之一）
fn subformatTag(subformat: []const u8) ?u16 {
    const tail = subformat[4..16];
    if (std.mem.eql(u8, tail, &mediasubtype_base_guid) or
        std.mem.eql(u8, tail, &ambisonic_base_guid) or
        std.mem.eql(u8, tail, &broken_base_guid))
    {
        return readU16(subformat[0..2], .little);
    }
    return null;
}

/// 解析 AIFF/AIFF-C `COMM` chunk payload。
/// `is_aifc` 为 true 时读取 compressionType(4) 与压缩名（pascal，pad 到偶）。
pub fn parseAiffComm(reader: *io.Reader, csize: u64, is_aifc: bool) Error!AiffComm {
    if (csize < 18) return error.Corrupt;
    var f: [18]u8 = undefined;
    if (!try readExact(reader, &f)) return error.Corrupt;

    const channels = readU16(f[0..2], .big);
    const sample_rate = try parseExtended80(f[8..18]);
    const bits = readU16(f[6..8], .big);
    var rest = csize - 18;

    var tag: [4]u8 = "NONE".*;
    if (is_aifc) {
        if (rest < 4) return error.Corrupt;
        if (!try readExact(reader, &tag)) return error.Corrupt;
        rest -= 4;
        // compressionType 以 little-endian 存储的四字符码
        if (std.mem.eql(u8, &tag, "NONE") or
            std.mem.eql(u8, &tag, "sowt") or
            std.mem.eql(u8, &tag, "raw ") or
            std.mem.eql(u8, &tag, "in24") or
            std.mem.eql(u8, &tag, "in32"))
        {
            // PCM 整数
        } else if (std.mem.eql(u8, &tag, "fl32") or std.mem.eql(u8, &tag, "fl64")) {
            // IEEE float
        } else if (std.mem.eql(u8, &tag, "alaw")) {
            // A-LAW
        } else if (std.mem.eql(u8, &tag, "ulaw")) {
            // mu-LAW
        } else if (std.mem.eql(u8, &tag, "ima4")) {
            // IMA QT ADPCM
        } else if (std.mem.eql(u8, &tag, "GSM ")) {
            // GSM 06.10（纯 GSM，MSB 位序）
        } else if (std.mem.eql(u8, &tag, "MAC3") or std.mem.eql(u8, &tag, "MAC6")) {
            // MACE 3:1 / 6:1
        } else {
            return error.UnsupportedFormat;
        }
        // 压缩名：pascal（1 字节 len + 文本），pad 到偶
        if (rest >= 1) {
            var len_buf: [1]u8 = undefined;
            if (!try readExact(reader, &len_buf)) return error.Corrupt;
            rest -= 1;
            const name_len: u64 = len_buf[0];
            const skip = name_len + (name_len & 1);
            if (skip > rest) return error.Corrupt;
            try skipBytes(reader, skip);
            rest -= skip;
        }
    }
    try skipBytes(reader, rest);

    const codec: Codec = if (std.mem.eql(u8, &tag, "alaw"))
        .alaw
    else if (std.mem.eql(u8, &tag, "ulaw"))
        .mulaw
    else if (std.mem.eql(u8, &tag, "ima4"))
        .adpcm_ima_qt
    else if (std.mem.eql(u8, &tag, "GSM "))
        .gsm
    else if (std.mem.eql(u8, &tag, "MAC3"))
        .mace3
    else if (std.mem.eql(u8, &tag, "MAC6"))
        .mace6
    else if (std.mem.eql(u8, &tag, "fl32") or std.mem.eql(u8, &tag, "fl64"))
        .pcm_float
    else
        .pcm_int;

    const fmt: WavFmt = switch (codec) {
        .alaw, .mulaw => .{ .codec = codec, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 8, .block_align = channels },
        // ima4：块 = 每通道 2B 头 + 32B 数据 = 34B/通道，每块 64 样本
        .adpcm_ima_qt => .{ .codec = codec, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = @as(usize, channels) * 34 },
        // 纯 GSM：每块 33B（1 帧 = 160 样本），输出 s16
        .gsm => .{ .codec = codec, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 16, .block_align = gsm.block_size },
        // MACE：块 = 2B/声道（MAC3）或 1B/声道（MAC6），每块 6 样本/声道；输出 s16
        .mace3 => .{ .codec = codec, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 16, .block_align = @as(usize, channels) * mace.block_size_mace3 },
        .mace6 => .{ .codec = codec, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 16, .block_align = @as(usize, channels) * mace.block_size_mace6 },
        else => .{ .codec = codec, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = bits, .block_align = @as(usize, channels) * (bits / 8) },
    };
    try validate(fmt);
    return .{ .fmt = fmt, .tag = tag };
}

/// 由 WAV format tag + 字段构建 WavFmt（含范围/位深校验与 F16/F24 判定）
fn buildFmt(
    tag: u16,
    channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits: u16,
    extradata: []const u8,
    endian: std.builtin.Endian,
) Error!WavFmt {
    var fmt: WavFmt = switch (tag) {
        1 => .{ .codec = .pcm_int, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = bits, .block_align = @as(usize, channels) * (bits / 8) },
        3 => .{ .codec = .pcm_float, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = bits, .block_align = @as(usize, channels) * (bits / 8) },
        6 => .{ .codec = .alaw, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 8, .block_align = channels },
        7 => .{ .codec = .mulaw, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 8, .block_align = channels },
        // ADPCM：block_align = 每块字节数（含块头），不能由位深推导
        2 => .{ .codec = .adpcm_ms, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        0x11 => if (bits == 8)
            // riffdec.c 289-290：ADPCM_IMA_WAV && bits==8 → ADPCM_ZORK（连续流）
            .{ .codec = .adpcm_zork, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 8, .block_align = block_align }
        else
            .{ .codec = .adpcm_ima, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        // 连续流 ADPCM（无块头，block_align 仅作保留字段，读取按数据区连续解码）
        0x10, 0x17 => .{ .codec = .adpcm_oki, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        0x20 => .{ .codec = .adpcm_yamaha, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        0x200 => .{ .codec = .adpcm_ct, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        // IMA DK4（0x61）：块式，4B/通道头 + nibble 数据，≤2 声道
        0x61 => .{ .codec = .adpcm_dk4, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        // IMA DK3（0x62）：块式 sum/diff 立体声，块头 16B（10B 跳过 + 2×pred + 2×idx）
        0x62 => .{ .codec = .adpcm_dk3, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        // XBOX ADPCM（0x69）：块式，4B/通道头 + 每轮每通道 4B → 8 样本
        0x69 => .{ .codec = .adpcm_xbox, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = bits, .block_align = block_align },
        // SANYO LD-ADPCM（0x125）：块式，位流 3/4/5 位；块样本数在 fmt 扩展区 LE16
        0x125 => .{ .codec = .adpcm_sanyo, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = bits, .block_align = block_align },
        // XAN DPCM（0x594A）：块式，块头 2B/通道 + 每字节 1 样本；输出 s16
        0x594A => .{ .codec = .xan, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 16, .block_align = block_align },
        // SWF ADPCM（0x5346，riff.c 616）：MSB-first 位流（首 2 bit = nbits 2..5），
        // 无块头连续位流，block_align 仅作保留字段；输出 s16
        0x5346 => .{ .codec = .adpcm_swf, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 4, .block_align = block_align },
        // GSM 06.10（GSM_MS）：块 = block_align 字节（41..65）含 2 帧 = 320 样本；输出 s16
        0x31, 0x32, 0x1500 => .{ .codec = .gsm, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 16, .block_align = block_align },
        // G.722（0x028F，riff.c 583）：bits_per_codeword 默认 8（无 extradata）→
        // 每字节高 2 位 + 低 6 位 → 2 帧 s16；仅单声道；block_align 仅保留字段
        0x028F => .{ .codec = .adpcm_g722, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = 16, .block_align = block_align },
        // G.726（0x0045/0x0014/0x0040/0x0064，riff.c 550-562）：fmt bits 字段须 2..5，
        // 实际 code_size 由 byte_rate/sample_rate 覆盖（riffdec.c 254-256）后同样须 2..5；
        // 每样本 code_size 位 → 1 帧 s16；仅单声道
        0x0045, 0x0014, 0x0040, 0x0064 => blk: {
            if (bits < 2 or bits > 5) return error.UnsupportedFormat;
            if (sample_rate == 0) return error.Corrupt;
            const code_size: u16 = @intCast(@as(u64, byte_rate) * 8 / sample_rate);
            if (code_size < 2 or code_size > 5) return error.Corrupt; // g726_decode_init EINVAL
            break :blk .{ .codec = .adpcm_g726, .channels = @intCast(channels), .sample_rate = sample_rate, .bits = code_size, .block_align = block_align };
        },
        else => return error.UnsupportedFormat,
    };
    // 拷贝 fmt 扩展区（镜像 ff_get_extradata 语义，上限 64；F16LE 判定与
    // SANYO 每块样本数依赖该区，须随 WavFmt 存储）
    const ext_n = @min(extradata.len, 64);
    fmt.extradata_len = @intCast(ext_n);
    @memcpy(fmt.extradata[0..ext_n], extradata[0..ext_n]);
    // fmt chunk 里的 block_align 可能损坏（FFmpeg 修复逻辑）：取二者较大
    fmt.block_align = @max(fmt.block_align, block_align);
    // F16/F24 判定（镜像 FFmpeg wavdec.c 664-675，仅 little-endian）：
    // 4 字节槽位（block_align == ch*4）的 PCM 实为缩放 float：
    //   - F24LE：tag 1 + bits 24；
    //   - F16LE：tag 1 + bits 32 + extradata 2B == LE16(1)。
    // 注意与 3 字节槽位的普通 S24LE（bits 24 + block_align ch*3）区分。
    if (endian == .little and tag == 1 and fmt.block_align == @as(usize, channels) * 4) {
        if (bits == 24) {
            fmt.codec = .pcm_f24;
        } else if (bits == 32 and extradata.len == 2 and
            std.mem.readInt(u16, extradata[0..2], .little) == 1)
        {
            fmt.codec = .pcm_f16;
            // 文件 bits 字段为 32（槽位宽度）；归一为编码位深 16（镜像 FFmpeg wavdec 670）
            fmt.bits = 16;
        }
    }
    try validate(fmt);
    return fmt;
}

/// 范围校验（§13.3）。供 fmt 解析（WAV/AIFF/CAF/AU）共用。
pub fn validate(fmt: WavFmt) Error!void {
    if (fmt.channels < 1 or fmt.channels > 8) return error.Corrupt;
    // 采样率上限放宽至 4 MHz：覆盖 DXD 768k 与高频专业 PCM（§9.1 边界）
    if (fmt.sample_rate < 1 or fmt.sample_rate > 4_000_000) return error.Corrupt;
    switch (fmt.codec) {
        .pcm_int => if (!switch (fmt.bits) {
            8, 16, 24, 32, 64 => true,
            else => false,
        }) return error.UnsupportedFormat,
        .pcm_float => if (!switch (fmt.bits) {
            // 16 = IEEE half（2 字节）；24 拒绝 → FFmpeg 兜底：tag 3 + bits 24 无
            // 映射（FFmpeg 亦 NONE）；float24 的正确形态是 F24LE（tag 1 + 4B 槽位），
            // 已在 buildFmt 判定为 .pcm_f24，见下
            16, 32, 64 => true,
            else => false,
        }) return error.UnsupportedFormat,
        // F16/F24：4 字节槽位已由 buildFmt 判定（block_align == ch*4）；输出恒 f32
        .pcm_f16, .pcm_f24 => {},
        .alaw, .mulaw => {}, // 固定 8-bit
        // ADPCM 块式：通道 ≤8，块头字节数约束
        .adpcm_ms => if (fmt.channels > 8 or fmt.block_align < 7 * fmt.channels)
            return error.Corrupt, // 块头 7B/通道
        .adpcm_ima => if (fmt.channels > 8 or fmt.block_align < 4 * fmt.channels)
            return error.Corrupt, // 块头 4B/通道
        .adpcm_ima_qt => if (fmt.channels > 8 or fmt.block_align < 34 * fmt.channels)
            return error.Corrupt, // 块 34B/通道
        // DK4 块式：解码循环仅用 status[0]/status[st]，只支持 1-2 声道
        .adpcm_dk4 => if (fmt.channels > 2 or fmt.block_align < 4 * fmt.channels)
            return error.Corrupt, // 块头 4B/通道
        // DK3 块式：sum/diff 立体声编解码（镜像 FFmpeg 1748-1798 用 status[0]/status[1]），
        // 仅 2 声道；块头 16B（10B 跳过 + 2×pred + 2×idx）
        .adpcm_dk3 => if (fmt.channels != 2 or fmt.block_align < 16)
            return error.Corrupt,
        // XBOX 块式：4-bit（镜像 FFmpeg 327-330 bits_per_coded_sample == 4），
        // 块头 4B/通道；通道 ≤8
        .adpcm_xbox => if (fmt.channels > 8 or fmt.bits != 4 or fmt.block_align < 4 * fmt.channels)
            return error.Corrupt,
        // SANYO 块式：≤2 声道（镜像 FFmpeg 267-269）；位深 3/4/5（324-326）；
        // 每块样本数须在 fmt 扩展区（2B LE，1428-1432）；块头 4B/通道
        .adpcm_sanyo => if (fmt.channels > 2 or fmt.bits < 3 or fmt.bits > 5 or
            fmt.extradata_len != 2 or fmt.block_align < 4 * fmt.channels)
            return error.Corrupt,
        // XAN 块式：解码器 predictor/shift 为 [2]，只支持 1-2 声道；块头 2B/通道
        .xan => if (fmt.channels > 2 or fmt.block_align < 2 * fmt.channels)
            return error.Corrupt,
        // 连续流 ADPCM：仅支持 ≤2 声道（镜像 FFmpeg 仅解 status[0]/status[st]）
        .adpcm_oki, .adpcm_yamaha, .adpcm_ct => if (fmt.channels > 2)
            return error.Corrupt,
        // GSM 06.10：仅单声道（FFmpeg gsmdec 同）；块长须合法：
        //   WAV GSM_MS = 41..65 步进 3；AIFF 纯 GSM = 33（解码时再按容器选择）
        .gsm => {
            if (fmt.channels != 1) return error.UnsupportedFormat;
            if (fmt.block_align != gsm.block_size and
                (fmt.block_align < gsm.msn_min_block_size or fmt.block_align > gsm.ms_block_size or
                    (fmt.block_align - gsm.msn_min_block_size) % 3 != 0))
            {
                return error.Corrupt;
            }
        },
        // MACE：仅 ≤2 声道（FFmpeg mace_decode_init 限制 1-2）；块长须为 2B/声道（MAC3）
        // 或 1B/声道（MAC6）
        .mace3 => if (fmt.channels > 2 or fmt.block_align != 2 * fmt.channels)
            return error.Corrupt,
        .mace6 => if (fmt.channels > 2 or fmt.block_align != 1 * fmt.channels)
            return error.Corrupt,
        // ZORK 连续流：8-bit 控制量（镜像 FFmpeg init 331-334 bits==8）；≤2 声道
        .adpcm_zork => if (fmt.channels > 2 or fmt.bits != 8)
            return error.Corrupt,
        // SWF 位流：4-bit（av_get_bits_per_sample 返回 4，utils.c 555-574）；≤2 声道
        .adpcm_swf => if (fmt.channels > 2 or fmt.bits != 4)
            return error.Corrupt,
        // G.722：仅单声道（g722dec.c 63-65 强制 MONO）；输出 s16
        .adpcm_g722 => if (fmt.channels != 1) return error.UnsupportedFormat,
        // G.726：仅单声道（g726.c 432-435）；code_size（fmt.bits，已由
        // byte_rate/sample_rate 覆盖）须 2..5（g726_decode_init 441-445）
        .adpcm_g726 => {
            if (fmt.channels != 1) return error.UnsupportedFormat;
            if (fmt.bits < 2 or fmt.bits > 5) return error.Corrupt;
        },
    }
}

/// 80-bit extended float（IEEE 754 extended，2 字节符号+指数 + 8 字节尾数）→ u32
/// 采样率（AIFF COMM，大端）。算法镜像 FFmpeg aiffdec.c（exp 偏移 16383，双移）
fn parseExtended80(b: []const u8) Error!u32 {
    const exp_field = readU16(b[0..2], .big);
    if (exp_field & 0x8000 != 0) return error.Corrupt; // 负采样率非法
    const exp: i32 = @as(i32, exp_field & 0x7FFF) - 16383 - 63;
    const mantissa = readU64(b[2..10], .big);
    if (exp < -63 or exp > 63) return error.Corrupt;
    const rate: u64 = if (exp >= 0)
        mantissa << @intCast(exp)
    else
        (mantissa + (@as(u64, 1) << @intCast(-exp - 1))) >> @intCast(-exp);
    if (rate < 1 or rate > 4_000_000) return error.Corrupt;
    return @intCast(rate);
}

fn readExact(reader: *io.Reader, buf: []u8) Error!bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try reader.read(buf[got..]);
        if (n == 0) return false;
        got += n;
    }
    return true;
}

fn skipBytes(reader: *io.Reader, n: u64) Error!void {
    try reader.seek(@intCast(n), .current);
}

inline fn readU16(b: []const u8, endian: std.builtin.Endian) u16 {
    return std.mem.readInt(u16, b[0..2], endian);
}

inline fn readU32(b: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, b[0..4], endian);
}

inline fn readU64(b: []const u8, endian: std.builtin.Endian) u64 {
    return std.mem.readInt(u64, b[0..8], endian);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fmtBytes(tag: u16, channels: u16, rate: u32, byte_rate: u32, block_align: u16, bits: u16, endian: std.builtin.Endian) [16]u8 {
    var f: [16]u8 = undefined;
    std.mem.writeInt(u16, f[0..2], tag, endian);
    std.mem.writeInt(u16, f[2..4], channels, endian);
    std.mem.writeInt(u32, f[4..8], rate, endian);
    std.mem.writeInt(u32, f[8..12], byte_rate, endian);
    std.mem.writeInt(u16, f[12..14], block_align, endian);
    std.mem.writeInt(u16, f[14..16], bits, endian);
    return f;
}

test "decl: WAV PCM 16-bit" {
    var f = fmtBytes(1, 2, 44100, 176400, 4, 16, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.pcm_int, fmt.codec);
    try testing.expectEqual(@as(u8, 2), fmt.channels);
    try testing.expectEqual(@as(u32, 44100), fmt.sample_rate);
    try testing.expectEqual(@as(usize, 4), fmt.block_align);
}

test "decl: WAV mu-LAW（tag 7）" {
    var f = fmtBytes(7, 1, 8000, 8000, 1, 8, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.mulaw, fmt.codec);
    try testing.expectEqual(@as(usize, 1), fmt.block_align);
}

test "decl: WAVEFORMATEXTENSIBLE 子格式 PCM" {
    // fmt + cbSize(22): wValidBits(16) mask(3) + GUID(01 00 00 00 + MEDIASUBTYPE 尾段)
    var buf: [40]u8 = undefined;
    const base = fmtBytes(0xFFFE, 2, 48000, 192000, 8, 24, .little);
    @memcpy(buf[0..16], &base);
    std.mem.writeInt(u16, buf[16..18], 22, .little); // cbSize
    std.mem.writeInt(u16, buf[18..20], 24, .little); // wValidBits
    std.mem.writeInt(u32, buf[20..24], 3, .little); // channelMask (stereo)
    @memcpy(buf[24..28], &[_]u8{ 0x01, 0x00, 0x00, 0x00 }); // SubFormat tag = PCM(1)
    @memcpy(buf[28..40], &mediasubtype_base_guid);

    var reader = io.Reader.openMem(&buf);
    const fmt = try parseWavFmt(&reader, 40, .little);
    // 该布局（bits 24 + block_align 8 == ch*4）镜像 FFmpeg wavdec 判定 → F24LE
    try testing.expectEqual(Codec.pcm_f24, fmt.codec);
    try testing.expectEqual(@as(u16, 24), fmt.bits);
    // block_align 取 max(计算值 6, 文件值 8) = 8（破损修复逻辑）
    try testing.expectEqual(@as(usize, 8), fmt.block_align);
}

test "decl: EXTENSIBLE 未知子格式 → Unsupported" {
    var buf: [40]u8 = undefined;
    const base = fmtBytes(0xFFFE, 2, 48000, 192000, 8, 16, .little);
    @memcpy(buf[0..16], &base);
    std.mem.writeInt(u16, buf[16..18], 22, .little);
    std.mem.writeInt(u16, buf[18..20], 16, .little);
    std.mem.writeInt(u32, buf[20..24], 3, .little);
    @memcpy(buf[24..28], &[_]u8{ 0x00, 0x50, 0x00, 0x00 }); // 未知 tag 0x5000
    @memcpy(buf[28..40], &mediasubtype_base_guid);
    var reader = io.Reader.openMem(&buf);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader, 40, .little));
}

test "decl: 非法位深（PCM 12-bit）→ Unsupported" {
    var f = fmtBytes(1, 1, 8000, 12000, 2, 12, .little);
    var reader = io.Reader.openMem(&f);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader, 16, .little));
}

test "decl: 80-bit extended 采样率解析" {
    // 8000 Hz：exp = 16383 + 12，尾数 8000 << 51
    var b: [10]u8 = undefined;
    std.mem.writeInt(u16, b[0..2], 16383 + 12, .big);
    std.mem.writeInt(u64, b[2..10], @as(u64, 8000) << 51, .big);
    try testing.expectEqual(@as(u32, 8000), parseExtended80(&b));
}

test "decl: AIFF COMM 纯 AIFF（大端 PCM 16）" {
    // channels(2) frames(4) bits(2) rate(10)
    var buf: [18]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big);
    std.mem.writeInt(u32, buf[2..6], 100, .big);
    std.mem.writeInt(u16, buf[6..8], 16, .big);
    std.mem.writeInt(u16, buf[8..10], 16383 + 12, .big);
    std.mem.writeInt(u64, buf[10..18], @as(u64, 8000) << 51, .big);
    var reader = io.Reader.openMem(&buf);
    const comm = try parseAiffComm(&reader, 18, false);
    try testing.expectEqual(Codec.pcm_int, comm.fmt.codec);
    try testing.expectEqual(@as(u32, 8000), comm.fmt.sample_rate);
    try testing.expectEqual(@as(u16, 16), comm.fmt.bits);
    try testing.expectEqualStrings("NONE", &comm.tag);
}

test "decl: AIFF-C ulaw" {
    var buf: [22]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big);
    std.mem.writeInt(u32, buf[2..6], 100, .big);
    std.mem.writeInt(u16, buf[6..8], 8, .big);
    std.mem.writeInt(u16, buf[8..10], 16383 + 12, .big);
    std.mem.writeInt(u64, buf[10..18], @as(u64, 8000) << 51, .big);
    @memcpy(buf[18..22], "ulaw"); // compressionType（LE 四字符码）
    var reader = io.Reader.openMem(&buf);
    const comm = try parseAiffComm(&reader, 22, true);
    try testing.expectEqual(Codec.mulaw, comm.fmt.codec);
    try testing.expectEqual(@as(usize, 1), comm.fmt.block_align);
}

test "decl: WAV float16（tag 3 + bits 16）放行" {
    var f = fmtBytes(3, 2, 48000, 192000, 4, 16, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.pcm_float, fmt.codec);
    try testing.expectEqual(@as(u16, 16), fmt.bits);
    try testing.expectEqual(@as(usize, 4), fmt.block_align);
}

test "decl: WAV float24（tag 3 + bits 24）→ Unsupported" {
    // tag 3 + bits 24 无映射（FFmpeg 亦 NONE）；float24 的正确形态 F24LE
    // 走 tag 1 + 4B 槽位路径（见下）
    var f = fmtBytes(3, 1, 48000, 144000, 3, 24, .little);
    var reader = io.Reader.openMem(&f);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader, 16, .little));
}

test "decl: WAV float24 F24LE（tag 1 + bits 24 + block_align ch*4）" {
    // F24LE：PCM tag 1 + bits 24 + 4 字节槽位（镜像 FFmpeg wavdec 671-674）
    var f = fmtBytes(1, 2, 48000, 384000, 8, 24, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.pcm_f24, fmt.codec);
    try testing.expectEqual(@as(u16, 24), fmt.bits); // 编码位深（输出恒 32）
    try testing.expectEqual(@as(usize, 8), fmt.block_align);
}

test "decl: WAV float16 F16LE（tag 1 + bits 32 + extradata [01 00]）" {
    // F16LE：tag 1 + bits 32 + 4B 槽位 + extradata 2B == 1（镜像 wavdec 664-670）
    var buf: [20]u8 = undefined;
    const base = fmtBytes(1, 2, 48000, 384000, 8, 32, .little);
    @memcpy(buf[0..16], &base);
    std.mem.writeInt(u16, buf[16..18], 2, .little); // cbSize = 2
    @memcpy(buf[18..20], &[_]u8{ 1, 0 }); // F16 标记
    var reader = io.Reader.openMem(&buf);
    const fmt = try parseWavFmt(&reader, 20, .little);
    try testing.expectEqual(Codec.pcm_f16, fmt.codec);
    try testing.expectEqual(@as(u16, 16), fmt.bits);
    try testing.expectEqual(@as(usize, 8), fmt.block_align);
}

test "decl: F16 判定负例（extradata != [01 00]）→ 保持 pcm_int s32" {
    var buf: [20]u8 = undefined;
    const base = fmtBytes(1, 2, 48000, 384000, 8, 32, .little);
    @memcpy(buf[0..16], &base);
    std.mem.writeInt(u16, buf[16..18], 2, .little);
    @memcpy(buf[18..20], &[_]u8{ 2, 0 }); // 非 1 → 普通 s32
    var reader = io.Reader.openMem(&buf);
    const fmt = try parseWavFmt(&reader, 20, .little);
    try testing.expectEqual(Codec.pcm_int, fmt.codec);
    try testing.expectEqual(@as(u16, 32), fmt.bits);
}

test "decl: RIFX 大端不触发 F16/F24 判定" {
    // 大端（RIFX）4B 槽位保持普通 PCM（FFmpeg 无 RIFX F16/F24 变体）
    var f = fmtBytes(1, 2, 48000, 384000, 8, 24, .big);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .big);
    try testing.expectEqual(Codec.pcm_int, fmt.codec);
    try testing.expectEqual(@as(u16, 24), fmt.bits);
}

test "decl: WAV XAN DPCM（tag 0x594A）解析" {
    var f = fmtBytes(0x594A, 1, 8000, 16000, 4, 16, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.xan, fmt.codec);
    try testing.expectEqual(@as(usize, 4), fmt.block_align);
    try testing.expectEqual(@as(u16, 16), fmt.bits);

    // 立体声 XAN：block_align 8
    var f2 = fmtBytes(0x594A, 2, 8000, 16000, 8, 16, .little);
    var reader2 = io.Reader.openMem(&f2);
    const fmt2 = try parseWavFmt(&reader2, 16, .little);
    try testing.expectEqual(Codec.xan, fmt2.codec);
    try testing.expectEqual(@as(usize, 8), fmt2.block_align);

    // 三声道 XAN → Corrupt（解码器 predictor/shift 仅 [2]，镜像 FFmpeg）
    var f3 = fmtBytes(0x594A, 3, 8000, 24000, 12, 16, .little);
    var reader3 = io.Reader.openMem(&f3);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader3, 16, .little));
}

test "decl: ADPCM DK3（tag 0x62）解析与通道限制" {
    // 立体声 DK3：block_align 16
    var f = fmtBytes(0x62, 2, 22050, 22050, 16, 4, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.adpcm_dk3, fmt.codec);
    try testing.expectEqual(@as(usize, 16), fmt.block_align);

    // 单声道 DK3 → Corrupt（sum/diff 需 2 声道）
    var f2 = fmtBytes(0x62, 1, 22050, 22050, 8, 4, .little);
    var reader2 = io.Reader.openMem(&f2);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader2, 16, .little));
    // block_align < 16 → Corrupt
    var f3 = fmtBytes(0x62, 2, 22050, 22050, 12, 4, .little);
    var reader3 = io.Reader.openMem(&f3);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader3, 16, .little));
}

test "decl: ADPCM XBOX（tag 0x69）解析与位深限制" {
    // 立体声 XBOX：block_align 32（4B×2 头 + 3 轮 ×8B）
    var f = fmtBytes(0x69, 2, 48000, 1536000, 32, 4, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.adpcm_xbox, fmt.codec);
    try testing.expectEqual(@as(usize, 32), fmt.block_align);
    try testing.expectEqual(@as(u16, 4), fmt.bits);

    // 位深 != 4 → Corrupt（镜像 FFmpeg init 327-330）
    var f2 = fmtBytes(0x69, 2, 48000, 1536000, 32, 8, .little);
    var reader2 = io.Reader.openMem(&f2);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader2, 16, .little));
}

test "decl: ADPCM SANYO（tag 0x125）解析与扩展区校验" {
    // mono 3-bit SANYO：fmt + cbSize=2 + 每块样本数 LE16 = 200
    var buf: [20]u8 = undefined;
    const base = fmtBytes(0x125, 1, 8000, 8000, 79, 3, .little);
    @memcpy(buf[0..16], &base);
    std.mem.writeInt(u16, buf[16..18], 2, .little); // cbSize
    std.mem.writeInt(u16, buf[18..20], 200, .little); // 每块样本数
    var reader = io.Reader.openMem(&buf);
    const fmt = try parseWavFmt(&reader, 20, .little);
    try testing.expectEqual(Codec.adpcm_sanyo, fmt.codec);
    try testing.expectEqual(@as(u16, 3), fmt.bits);
    try testing.expectEqual(@as(usize, 79), fmt.block_align);
    try testing.expectEqual(@as(u8, 2), fmt.extradata_len);

    // 缺扩展区（csize 16）→ Corrupt（镜像 FFmpeg 1429）
    var f2 = fmtBytes(0x125, 1, 8000, 8000, 79, 3, .little);
    var reader2 = io.Reader.openMem(&f2);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader2, 16, .little));
    // 位深 2 非法 → Corrupt
    var f3 = fmtBytes(0x125, 1, 8000, 8000, 79, 2, .little);
    var reader3 = io.Reader.openMem(&f3);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader3, 16, .little));
    // 三声道 → Corrupt（≤2 声道）
    var f4 = fmtBytes(0x125, 3, 8000, 8000, 79, 3, .little);
    var reader4 = io.Reader.openMem(&f4);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader4, 16, .little));
}

test "decl: 采样率上限放宽至 4 MHz（DXD 768k 通过 / 超限拒绝）" {
    var f = fmtBytes(1, 1, 768000, 1536000, 2, 16, .little); // DXD 768k
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(@as(u32, 768000), fmt.sample_rate);

    var f2 = fmtBytes(1, 1, 4_000_001, 8000002, 2, 16, .little); // 超上限
    var reader2 = io.Reader.openMem(&f2);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader2, 16, .little));
}

test "decl: WAV GSM_MS（tag 0x31）解析" {
    // 真实 gsm_ref.wav 头：tag 0x31、mono、8000Hz、byte_rate 1625、align 65、bits 2
    var f = fmtBytes(0x31, 1, 8000, 1625, 65, 2, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.gsm, fmt.codec);
    try testing.expectEqual(@as(usize, 65), fmt.block_align);
    try testing.expectEqual(@as(u8, 1), fmt.channels);
    try testing.expectEqual(@as(u32, 8000), fmt.sample_rate);

    // 非法块长：64 非步进 3 → Corrupt
    var f2 = fmtBytes(0x31, 1, 8000, 1600, 64, 2, .little);
    var reader2 = io.Reader.openMem(&f2);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader2, 16, .little));
    // 立体声 GSM_MS：GSM 仅单声道 → Unsupported
    var f3 = fmtBytes(0x31, 2, 8000, 3250, 65, 2, .little);
    var reader3 = io.Reader.openMem(&f3);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader3, 16, .little));
}

test "decl: AIFF-C GSM 压缩类型（'GSM '）解析" {
    // COMM 18B + compressionType "GSM "
    var buf: [22]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big); // channels
    std.mem.writeInt(u32, buf[2..6], 960, .big); // frames
    std.mem.writeInt(u16, buf[6..8], 0, .big); // bits（压缩类型下无效）
    std.mem.writeInt(u16, buf[8..10], 16383 + 12, .big);
    std.mem.writeInt(u64, buf[10..18], @as(u64, 8000) << 51, .big);
    @memcpy(buf[18..22], "GSM ");
    var reader = io.Reader.openMem(&buf);
    const comm = try parseAiffComm(&reader, 22, true);
    try testing.expectEqual(Codec.gsm, comm.fmt.codec);
    try testing.expectEqual(@as(usize, 33), comm.fmt.block_align); // 纯 GSM 33B/块
    try testing.expectEqual(@as(u16, 16), comm.fmt.bits);
    try testing.expectEqualStrings("GSM ", &comm.tag);
}

test "decl: AIFF-C MACE 压缩类型（'MAC3'/'MAC6'）解析" {
    // COMM 18B + compressionType（22B，无压缩名）
    var buf: [22]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big); // channels
    std.mem.writeInt(u32, buf[2..6], 600, .big); // frames
    std.mem.writeInt(u16, buf[6..8], 0, .big); // bits（压缩类型下无效）
    std.mem.writeInt(u16, buf[8..10], 16383 + 12, .big);
    std.mem.writeInt(u64, buf[10..18], @as(u64, 8000) << 51, .big);

    @memcpy(buf[18..22], "MAC3");
    var r3 = io.Reader.openMem(&buf);
    const c3 = try parseAiffComm(&r3, 22, true);
    try testing.expectEqual(Codec.mace3, c3.fmt.codec);
    try testing.expectEqual(@as(usize, 2), c3.fmt.block_align); // MAC3 = 2B/声道
    try testing.expectEqual(@as(u16, 16), c3.fmt.bits);
    try testing.expectEqualStrings("MAC3", &c3.tag);

    @memcpy(buf[18..22], "MAC6");
    var r6 = io.Reader.openMem(&buf);
    const c6 = try parseAiffComm(&r6, 22, true);
    try testing.expectEqual(Codec.mace6, c6.fmt.codec);
    try testing.expectEqual(@as(usize, 1), c6.fmt.block_align); // MAC6 = 1B/声道
    try testing.expectEqualStrings("MAC6", &c6.tag);

    // 立体声 MAC6：block_align = 2
    std.mem.writeInt(u16, buf[0..2], 2, .big);
    var r6s = io.Reader.openMem(&buf);
    const c6s = try parseAiffComm(&r6s, 22, true);
    try testing.expectEqual(Codec.mace6, c6s.fmt.codec);
    try testing.expectEqual(@as(usize, 2), c6s.fmt.block_align);

    // 非法：MAC3 三声道 → Corrupt（FFmpeg mace 仅 1-2 声道）
    std.mem.writeInt(u16, buf[0..2], 3, .big);
    @memcpy(buf[18..22], "MAC3");
    var r3x = io.Reader.openMem(&buf);
    try testing.expectError(error.Corrupt, parseAiffComm(&r3x, 22, true));
}

test "decl: WAV G.722（tag 0x028F）解析与单声道限制" {
    // 真实 g722_mono.wav 头：tag 0x028F、mono、16kHz、byte_rate 16000、align 1、bits 4
    var f = fmtBytes(0x028F, 1, 16000, 16000, 1, 4, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.adpcm_g722, fmt.codec);
    try testing.expectEqual(@as(u8, 1), fmt.channels);
    try testing.expectEqual(@as(u32, 16000), fmt.sample_rate);
    try testing.expectEqual(@as(u16, 16), fmt.bits); // 输出 s16

    // 立体声 G.722 → UnsupportedFormat（g722dec 仅单声道）
    var f2 = fmtBytes(0x028F, 2, 16000, 32000, 2, 4, .little);
    var reader2 = io.Reader.openMem(&f2);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader2, 16, .little));
}

test "decl: WAV G.726（tag 0x0045/0x0014）解析与 code_size 覆盖" {
    // 真实 g726_4.wav 头：tag 0x0045、mono、8kHz、byte_rate 4000、bits 4
    // code_size = byte_rate*8/sample_rate = 4000*8/8000 = 4
    var f = fmtBytes(0x0045, 1, 8000, 4000, 1, 4, .little);
    var reader = io.Reader.openMem(&f);
    const fmt = try parseWavFmt(&reader, 16, .little);
    try testing.expectEqual(Codec.adpcm_g726, fmt.codec);
    try testing.expectEqual(@as(u16, 4), fmt.bits); // 已覆盖为 code_size

    // 另一 tag 0x0014 + code_size 2（byte_rate 2000 → 2）
    var f2 = fmtBytes(0x0014, 1, 8000, 2000, 1, 2, .little);
    var reader2 = io.Reader.openMem(&f2);
    const fmt2 = try parseWavFmt(&reader2, 16, .little);
    try testing.expectEqual(Codec.adpcm_g726, fmt2.codec);
    try testing.expectEqual(@as(u16, 2), fmt2.bits);

    // code_size 越界（byte_rate 1000 → 1）→ Corrupt
    var f3 = fmtBytes(0x0045, 1, 8000, 1000, 1, 4, .little);
    var reader3 = io.Reader.openMem(&f3);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader3, 16, .little));
    // fmt bits 字段越界（8）→ UnsupportedFormat（riffdec.c 254-255 先校验文件字段）
    var f4 = fmtBytes(0x0045, 1, 8000, 4000, 1, 8, .little);
    var reader4 = io.Reader.openMem(&f4);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader4, 16, .little));
    // 立体声 G.726（byte_rate 4000 → code_size 4 有效）→ UnsupportedFormat（仅单声道）
    var f5 = fmtBytes(0x0045, 2, 8000, 4000, 2, 4, .little);
    var reader5 = io.Reader.openMem(&f5);
    try testing.expectError(error.UnsupportedFormat, parseWavFmt(&reader5, 16, .little));
    // 立体声 G.726 + code_size 越界（byte_rate 8000 → 8）→ Corrupt（buildFmt 先于 validate）
    var f6 = fmtBytes(0x0045, 2, 8000, 8000, 2, 4, .little);
    var reader6 = io.Reader.openMem(&f6);
    try testing.expectError(error.Corrupt, parseWavFmt(&reader6, 16, .little));
}

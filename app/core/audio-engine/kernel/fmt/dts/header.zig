//! DTS core 帧头解析（阶段一：16-bit core 子流，BE 或 16-bit 字交换 LE）
//!
//! 对照 FFmpeg dca.c ff_dca_parse_core_frame_header / dca_core.c
//! parse_frame_header + parse_coding_header（主声道头首 7 位）。
//!
//! 位流 MSB-first。文件形态差异仅在于每个 16-bit 字的字节序：
//!   - BE16：sync 文件字节 7F FE 80 01（RB32 = 0x7FFE8001）；
//!   - LE16：sync 文件字节 FE 7F 01 80（RB32 = 0xFE7F0180，= 每 16-bit 字
//!     内字节交换，avpriv_dca_convert_bitstream 的 DCA_SYNCWORD_CORE_LE 路径）。
//! 解析前先将 LE 字交换回 BE（只交换前若干字节窗口即可）。
//!
//! 14-bit 打包（0x1FFFE800 / 0xFF1F00E8）为旧式位流，阶段一不支持 → Unsupported14Bit。

const std = @import("std");
const BitReader = @import("../aac/bitreader.zig").BitReader;
const t = @import("tables.zig");

/// 解析窗口：core 帧头 104 位（含 CRC 时为 120 位）+ 主声道头 nsubframes(4)+
/// nchannels(3)，最坏到第 127 位 → 需 16 字节；取 FFmpeg 同款 18 字节余量。
pub const header_window: usize = 18;

pub const ParseError = error{
    Sync,
    DeficitSamples,
    PcmBlocks,
    FrameSize,
    AudioMode,
    SampleRate,
    ReservedBit,
    LfeFlag,
    PcmResolution,
    Unsupported14Bit,
    Corrupt,
};

/// 文件 sync 形态（16-bit core 两种 / 14-bit 两种）
pub const ByteOrder = enum { be16, le16, b14_be, b14_le };

/// 由文件头 4 字节判定位流形态（无匹配 → null）
pub fn detectOrder(head: []const u8) ?ByteOrder {
    if (head.len < 4) return null;
    const w = std.mem.readInt(u32, head[0..4], .big);
    return switch (w) {
        t.syncword_core_be => .be16,
        t.syncword_core_le => .le16,
        t.syncword_core_14b_be => .b14_be,
        t.syncword_core_14b_le => .b14_le,
        else => null,
    };
}

/// 已解析的 core 帧头字段（字段语义见注释）
pub const Header = struct {
    // ---- 位流头（dca.c ff_dca_parse_core_frame_header）----
    order: ByteOrder = .be16,
    /// Frame type（1 = 普通帧；0 = 首帧/低采样率残帧等）
    normal_frame: bool = false,
    /// samples_deficit（5 位 +1；FFmpeg 仅接受 32）
    deficit_samples: u8 = 0,
    crc_present: bool = false,
    /// 每帧 PCM 块数（7 位 +1；须为 8 的倍数）
    npcmblocks: u8 = 0,
    /// 主帧字节大小（14 位 +1；含 sync，FFmpeg 后续按 FFALIGN(x,4) 处理 DTS-HD）
    frame_size: u16 = 0,
    /// 声道布置（audio_mode，6 位）
    audio_mode: u8 = 0,
    sr_code: u8 = 0,
    br_code: u8 = 0,
    drc_present: bool = false,
    ts_present: bool = false,
    aux_present: bool = false,
    hdcd_master: bool = false,
    /// 扩展音频描述类型（0=XCH / 2=X96 / 6=XXCH）
    ext_audio_type: u8 = 0,
    /// Extended coding flag（core 帧内是否含扩展子帧）
    ext_audio_present: bool = false,
    sync_ssf: bool = false,
    /// 0=none / 1=128x / 2=64x / 3=非法
    lfe_present: u8 = 0,
    predictor_history: bool = false,
    filter_perfect: bool = false,
    encoder_rev: u8 = 0,
    copy_hist: u8 = 0,
    pcmr_code: u8 = 0,
    sumdiff_front: bool = false,
    sumdiff_surround: bool = false,
    dn_code: u8 = 0,

    // ---- 主声道编码头（dca_core.c parse_coding_header HEADER_CORE 首 7 位）----
    /// 子帧数（4 位 +1；core 每帧 nsubframes 个"子帧"）
    nsubframes: u8 = 0,
    /// 主声道数（3 位 +1；应为 channels_by_amode[audio_mode]）
    nchannels: u8 = 0,

    // ---- 派生 ----
    sample_rate: u32 = 0,
    bit_rate: u32 = 0,
    /// 源 PCM 位深（16/20/24）
    source_pcm_res: u8 = 0,
    /// pcmr_code & 1：DTS-ES 标志（含嵌入下混）
    es_format: bool = false,
    /// 帧头已消费位数（到 dn_code 末，含 16 位 CRC 时 120）
    consumed_bits: usize = 0,
    /// nchannels 与音频模式表不一致
    nchannels_mismatch: bool = false,
};

/// 解析位于帧首的 core 帧头（buf ≥ header_window 字节，文件原字节序）。
/// 只读 18 字节窗口；主声道头前 7 位一并读入。
pub fn parse(buf: []const u8, order: ByteOrder) ParseError!Header {
    if (buf.len < header_window) return error.Corrupt;
    if (order == .b14_be or order == .b14_le) return error.Unsupported14Bit;

    // LE：先做 16-bit 字交换 → BE 位流（仅窗口内）
    var norm: [header_window]u8 = undefined;
    if (order == .le16) {
        var i: usize = 0;
        while (i + 1 < header_window) : (i += 2) {
            norm[i] = buf[i + 1];
            norm[i + 1] = buf[i];
        }
    } else {
        @memcpy(&norm, buf[0..header_window]);
    }

    var gb = BitReader.init(&norm);
    var h: Header = .{ .order = order };

    // BitReader 返回工程级 error.Error（含 Aborted/SeekFailed 等），
    // 此处统一收窄为 ParseError（越界/不足 → Corrupt）。
    const rb = struct {
        fn read(g: *BitReader, n: u6) ParseError!u32 {
            return g.readBits(n) catch error.Corrupt;
        }
    }.read;

    if (try rb(&gb, 32) != t.syncword_core_be) return error.Sync;
    h.normal_frame = (try rb(&gb, 1)) != 0;
    h.deficit_samples = @intCast((try rb(&gb, 5)) + 1);
    if (h.deficit_samples != t.pcmblock_samples) return error.DeficitSamples;

    h.crc_present = (try rb(&gb, 1)) != 0;
    h.npcmblocks = @intCast((try rb(&gb, 7)) + 1);
    if ((h.npcmblocks & (t.subband_samples - 1)) != 0) return error.PcmBlocks;

    h.frame_size = @intCast((try rb(&gb, 14)) + 1);
    if (h.frame_size < 96) return error.FrameSize;

    h.audio_mode = @intCast(try rb(&gb, 6));
    if (h.audio_mode >= t.amode_count) return error.AudioMode;

    h.sr_code = @intCast(try rb(&gb, 4));
    h.sample_rate = t.sampleRateForCode(h.sr_code);
    if (h.sample_rate == 0) return error.SampleRate;

    h.br_code = @intCast(try rb(&gb, 5));
    if ((try rb(&gb, 1)) != 0) return error.ReservedBit; // 保留位须为 0

    h.drc_present = (try rb(&gb, 1)) != 0;
    h.ts_present = (try rb(&gb, 1)) != 0;
    h.aux_present = (try rb(&gb, 1)) != 0;
    h.hdcd_master = (try rb(&gb, 1)) != 0;
    h.ext_audio_type = @intCast(try rb(&gb, 3));
    h.ext_audio_present = (try rb(&gb, 1)) != 0;
    h.sync_ssf = (try rb(&gb, 1)) != 0;
    h.lfe_present = @intCast(try rb(&gb, 2));
    if (h.lfe_present == t.lfe_invalid) return error.LfeFlag;
    h.predictor_history = (try rb(&gb, 1)) != 0;

    if (h.crc_present) _ = try rb(&gb, 16);

    h.filter_perfect = (try rb(&gb, 1)) != 0;
    h.encoder_rev = @intCast(try rb(&gb, 4));
    h.copy_hist = @intCast(try rb(&gb, 2));
    h.pcmr_code = @intCast(try rb(&gb, 3));
    h.source_pcm_res = t.bits_per_sample[h.pcmr_code];
    if (h.source_pcm_res == 0) return error.PcmResolution;
    h.es_format = (h.pcmr_code & 1) != 0;
    h.sumdiff_front = (try rb(&gb, 1)) != 0;
    h.sumdiff_surround = (try rb(&gb, 1)) != 0;
    h.dn_code = @intCast(try rb(&gb, 4));
    h.consumed_bits = gb.bit_pos;

    h.bit_rate = t.bitRateForCode(h.br_code);

    // 主声道编码头前 7 位（nsubframes + nchannels）
    h.nsubframes = @intCast((try rb(&gb, 4)) + 1);
    h.nchannels = @intCast((try rb(&gb, 3)) + 1);
    const expect_ch: u8 = t.channels_by_amode[h.audio_mode];
    h.nchannels_mismatch = h.nchannels != expect_ch;
    return h;
}

/// 帧内容样本数（每声道 PCM 样本 = npcmblocks × 32；含 X96 时为 2×）
pub inline fn frameSamples(h: *const Header) u32 {
    return @as(u32, h.npcmblocks) * t.pcmblock_samples;
}

/// 帧时长微秒（每声道样本 / 采样率）
pub inline fn frameDurationUs(h: *const Header) u64 {
    return (@as(u64, frameSamples(h)) * 1_000_000) / h.sample_rate;
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AC-3 / E-AC-3 解码共享状态（对照 FFmpeg ac3dec.h AC3DecodeContext）
//!
//! 各模块（exponents/mantissa/coupling/rematrix/downmix）以本结构为契约，
//! 用 fmt/aac/bitreader.zig 的 BitReader 读取位流。

const std = @import("std");
const t = @import("tables.zig");
const ba = @import("bitalloc.zig");
const md5impl = @import("md5.zig");
const BitReader = @import("../aac/bitreader.zig").BitReader;

pub const AC3_OUTPUT_LFEON: i32 = 8;

/// 抖动 PRNG：64 状态加性 LFG（语义对照 FFmpeg libavutil/lfg.h 的加性 LFG 序列；
/// 命名/实现为本项目自有）。状态放在 Ctx 内（每解码器实例一份），避免多流并发共享全局
/// 状态导致串扰。
pub const JitterRng = struct {
    state: [64]u32 = [_]u32{0} ** 64,
    index: u32 = 0,

    pub fn init(self: *JitterRng, seed: u32) void {
        var tmp: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 8;
        while (i < 64) : (i += 4) {
            std.mem.writeInt(u32, tmp[0..4], seed, .little);
            tmp[4] = @intCast(i);
            var md5: md5impl.Md5 = .init(.{});
            md5.update(&tmp);
            md5.final(&tmp);
            self.state[i] = std.mem.readInt(u32, tmp[0..4], .little);
            self.state[i + 1] = std.mem.readInt(u32, tmp[4..8], .little);
            self.state[i + 2] = std.mem.readInt(u32, tmp[8..12], .little);
            self.state[i + 3] = std.mem.readInt(u32, tmp[12..16], .little);
        }
        self.index = 0;
    }

    pub fn next(self: *JitterRng) u32 {
        // 加性 LFG 递推（对齐 FFmpeg 现行 libavutil/lfg.h 抽取序列）：
        //   state[i&63] = state[(i-24)&63] + state[(i-55)&63]
        // 注意：不是旧式的 state[i] + state[i-24] + state[i-55]。
        const v = self.state[@intCast((self.index -% 24) & 63)] +% self.state[@intCast((self.index -% 55) & 63)];
        self.state[@intCast(self.index & 63)] = v;
        self.index +%= 1;
        return v;
    }
};

/// 分组尾数状态
pub const MantGroups = struct {
    b1_mant: [2]i32 = .{ 0, 0 },
    b2_mant: [2]i32 = .{ 0, 0 },
    b4_mant: i32 = 0,
    b1: i32 = 0,
    b2: i32 = 0,
    b4: i32 = 0,
};

pub const Ctx = struct {
    /// 位流读取器（指向当前帧缓冲）
    gb: BitReader = undefined,

    /// 抖动 PRNG 状态（jitter；open/seek 时以 seed=0 初始化，语义对照 FFmpeg av_lfg_init）
    jitter: JitterRng = .{},

    // 位流信息
    frame_type: i32 = 0,
    substreamid: i32 = 0,
    frame_size: i32 = 0,
    bit_rate: i32 = 0,
    sample_rate: i32 = 0,
    num_blocks: i32 = 6,
    bitstream_id: i32 = 0,
    bitstream_mode: i32 = 0,
    channel_mode: i32 = 0,
    lfe_on: i32 = 0,
    dialog_normalization: [2]i32 = .{ 0, 0 },
    compression_exists: [2]i32 = .{ 0, 0 },
    channel_map: i32 = 0,
    preferred_downmix: i32 = 0,
    center_mix_level: i32 = 0,
    center_mix_level_ltrt: i32 = 0,
    surround_mix_level: i32 = 0,
    surround_mix_level_ltrt: i32 = 0,
    lfe_mix_level_exists: i32 = 0,
    lfe_mix_level: i32 = 0,
    eac3: i32 = 0,
    eac3_subsbtreamid_found: i32 = 0,
    eac3_extension_type_a: i32 = 0,
    dolby_surround_mode: i32 = 0,
    dolby_surround_ex_mode: i32 = 0,
    dolby_headphone_mode: i32 = 0,

    target_level: i32 = 0,
    level_gain: [2]f32 = .{ 1.0, 1.0 },

    // 帧语法参数
    snr_offset_strategy: i32 = 0,
    block_switch_syntax: i32 = 0,
    dither_flag_syntax: i32 = 0,
    bit_allocation_syntax: i32 = 0,
    fast_gain_syntax: i32 = 0,
    dba_syntax: i32 = 0,
    skip_syntax: i32 = 0,

    // 标准耦合
    cpl_in_use: [t.AC3_MAX_BLOCKS]i32 = [_]i32{0} ** t.AC3_MAX_BLOCKS,
    cpl_strategy_exists: [t.AC3_MAX_BLOCKS]i32 = [_]i32{0} ** t.AC3_MAX_BLOCKS,
    channel_in_cpl: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    phase_flags_in_use: i32 = 0,
    phase_flags: [t.AC3_MAX_CPL_BANDS]i32 = [_]i32{0} ** t.AC3_MAX_CPL_BANDS,
    num_cpl_bands: i32 = 0,
    cpl_band_struct: [t.AC3_MAX_CPL_BANDS]u8 = [_]u8{0} ** t.AC3_MAX_CPL_BANDS,
    cpl_band_sizes: [t.AC3_MAX_CPL_BANDS]u8 = [_]u8{0} ** t.AC3_MAX_CPL_BANDS,
    firstchincpl: i32 = 0,
    first_cpl_coords: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    cpl_coords: [t.AC3_MAX_CHANNELS][t.AC3_MAX_CPL_BANDS]i32 = [_][t.AC3_MAX_CPL_BANDS]i32{[_]i32{0} ** t.AC3_MAX_CPL_BANDS} ** t.AC3_MAX_CHANNELS,

    // 频谱扩展（E-AC-3，暂保留字段）
    spx_in_use: i32 = 0,
    channel_uses_spx: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS,
    spx_atten_code: [t.AC3_MAX_CHANNELS]i8 = [_]i8{0} ** t.AC3_MAX_CHANNELS,
    spx_src_start_freq: i32 = 0,
    spx_dst_end_freq: i32 = 0,
    spx_dst_start_freq: i32 = 0,
    num_spx_bands: i32 = 0,
    spx_band_struct: [17]u8 = [_]u8{0} ** 17,
    spx_band_sizes: [17]u8 = [_]u8{0} ** 17,
    first_spx_coords: [t.AC3_MAX_CHANNELS]u8 = [_]u8{0} ** t.AC3_MAX_CHANNELS,
    spx_noise_blend: [t.AC3_MAX_CHANNELS][17]f32 = [_][17]f32{[_]f32{0} ** 17} ** t.AC3_MAX_CHANNELS,
    spx_signal_blend: [t.AC3_MAX_CHANNELS][17]f32 = [_][17]f32{[_]f32{0} ** 17} ** t.AC3_MAX_CHANNELS,

    channel_uses_aht: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    pre_mantissa: [t.AC3_MAX_CHANNELS][t.AC3_MAX_COEFS][t.AC3_MAX_BLOCKS]i32 = [_][t.AC3_MAX_COEFS][t.AC3_MAX_BLOCKS]i32{[_][t.AC3_MAX_BLOCKS]i32{[_]i32{0} ** t.AC3_MAX_BLOCKS} ** t.AC3_MAX_COEFS} ** t.AC3_MAX_CHANNELS,

    // 声道
    fbw_channels: i32 = 0,
    channels: i32 = 0,
    lfe_ch: i32 = 0,
    downmixed: i32 = 0,
    output_mode: i32 = 0,
    prev_output_mode: i32 = 0,
    out_channels: i32 = 0,

    // 动态范围
    dynamic_range: [2]f32 = .{ 1.0, 1.0 },
    drc_scale: f32 = 1.0,
    heavy_compression: i32 = 0,
    heavy_dynamic_range: [2]f32 = .{ 1.0, 1.0 },

    // 带宽
    start_freq: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    end_freq: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,

    // 重矩阵
    num_rematrixing_bands: i32 = 0,
    rematrixing_flags: [4]i32 = [_]i32{0} ** 4,

    // 指数
    num_exp_groups: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    dexps: [t.AC3_MAX_CHANNELS][t.AC3_MAX_COEFS]i8 = [_][t.AC3_MAX_COEFS]i8{[_]i8{0} ** t.AC3_MAX_COEFS} ** t.AC3_MAX_CHANNELS,
    exp_strategy: [t.AC3_MAX_BLOCKS][t.AC3_MAX_CHANNELS]i32 = [_][t.AC3_MAX_CHANNELS]i32{[_]i32{0} ** t.AC3_MAX_CHANNELS} ** t.AC3_MAX_BLOCKS,

    // 位分配
    bit_alloc_params: ba.BitAllocParams = .{},
    first_cpl_leak: i32 = 0,
    snr_offset: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    fast_gain: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    bap: [t.AC3_MAX_CHANNELS][t.AC3_MAX_COEFS]u8 = [_][t.AC3_MAX_COEFS]u8{[_]u8{0} ** t.AC3_MAX_COEFS} ** t.AC3_MAX_CHANNELS,
    psd: [t.AC3_MAX_CHANNELS][t.AC3_MAX_COEFS]i16 = [_][t.AC3_MAX_COEFS]i16{[_]i16{0} ** t.AC3_MAX_COEFS} ** t.AC3_MAX_CHANNELS,
    band_psd: [t.AC3_MAX_CHANNELS][t.AC3_CRITICAL_BANDS]i16 = [_][t.AC3_CRITICAL_BANDS]i16{[_]i16{0} ** t.AC3_CRITICAL_BANDS} ** t.AC3_MAX_CHANNELS,
    mask: [t.AC3_MAX_CHANNELS][t.AC3_CRITICAL_BANDS]i16 = [_][t.AC3_CRITICAL_BANDS]i16{[_]i16{0} ** t.AC3_CRITICAL_BANDS} ** t.AC3_MAX_CHANNELS,
    dba_mode: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    dba_nsegs: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,
    dba_offsets: [t.AC3_MAX_CHANNELS][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** t.AC3_MAX_CHANNELS,
    dba_lengths: [t.AC3_MAX_CHANNELS][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** t.AC3_MAX_CHANNELS,
    dba_values: [t.AC3_MAX_CHANNELS][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** t.AC3_MAX_CHANNELS,

    // 抖动
    dither_flag: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,

    // IMDCT
    block_switch: [t.AC3_MAX_CHANNELS]i32 = [_]i32{0} ** t.AC3_MAX_CHANNELS,

    // 输出指针
    outptr: [t.AC3_MAX_CHANNELS][*]f32 = undefined,

    // 对齐数组
    coeffs: [t.AC3_MAX_CHANNELS][t.AC3_MAX_COEFS]f32 = [_][t.AC3_MAX_COEFS]f32{[_]f32{0} ** t.AC3_MAX_COEFS} ** t.AC3_MAX_CHANNELS,
    transform_coeffs: [t.AC3_MAX_CHANNELS][t.AC3_MAX_COEFS]f32 = [_][t.AC3_MAX_COEFS]f32{[_]f32{0} ** t.AC3_MAX_COEFS} ** t.AC3_MAX_CHANNELS,
    delay: [t.EAC3_MAX_CHANNELS][t.AC3_BLOCK_SIZE]f32 = [_][t.AC3_BLOCK_SIZE]f32{[_]f32{0} ** t.AC3_BLOCK_SIZE} ** t.EAC3_MAX_CHANNELS,
    window: [t.AC3_BLOCK_SIZE]f32 = [_]f32{0} ** t.AC3_BLOCK_SIZE,
    tmp_output: [t.AC3_BLOCK_SIZE]f32 = [_]f32{0} ** t.AC3_BLOCK_SIZE,
    output: [t.EAC3_MAX_CHANNELS][t.AC3_BLOCK_SIZE]f32 = [_][t.AC3_BLOCK_SIZE]f32{[_]f32{0} ** t.AC3_BLOCK_SIZE} ** t.EAC3_MAX_CHANNELS,
    output_buffer: [t.EAC3_MAX_CHANNELS][t.AC3_BLOCK_SIZE * 6]f32 = [_][t.AC3_BLOCK_SIZE * 6]f32{[_]f32{0} ** (t.AC3_BLOCK_SIZE * 6)} ** t.EAC3_MAX_CHANNELS,

    // 下混系数
    downmix_coeffs: [2][t.AC3_MAX_CHANNELS]f32 = [_][t.AC3_MAX_CHANNELS]f32{[_]f32{0} ** t.AC3_MAX_CHANNELS} ** 2,
};

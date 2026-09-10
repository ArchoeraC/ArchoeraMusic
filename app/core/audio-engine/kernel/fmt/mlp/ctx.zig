// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! MLP/TrueHD 解码上下文（对照 FFmpeg mlpdec.c / mlp.h 结构）

const t = @import("tables.zig");

pub const MAX_CHANNELS = 16;
pub const MAX_MATRICES = 8;
pub const MAX_SUBSTREAMS = 4;
pub const MAX_BLOCKSIZE = 40 * 4;
pub const MAX_BLOCKSIZE_POW2 = 64 * 4;
pub const MAX_FIR_ORDER = 8;
pub const MAX_IIR_ORDER = 4;
pub const NUM_FILTERS = 2;
pub const MAX_MATRICES_MLP = 6;
pub const MAX_MATRICES_TRUEHD = 8;
pub const MAX_MATRIX_CHANNEL_MLP = 5;
pub const MAX_MATRIX_CHANNEL_TRUEHD = 7;
pub const END_OF_STREAM = 0xd234d234;

pub const PARAM_BLOCKSIZE: u8 = 1 << 7;
pub const PARAM_MATRIX: u8 = 1 << 6;
pub const PARAM_OUTSHIFT: u8 = 1 << 5;
pub const PARAM_QUANTSTEP: u8 = 1 << 4;
pub const PARAM_FIR: u8 = 1 << 3;
pub const PARAM_IIR: u8 = 1 << 2;
pub const PARAM_HUFFOFFSET: u8 = 1 << 1;
pub const PARAM_PRESENCE: u8 = 1 << 0;

pub const FIR: usize = 0;
pub const IIR: usize = 1;

pub fn msbMask(n: u32) i32 {
    return -(@as(i32, 1) << @as(u5, @intCast(n)));
}

pub const FilterParams = struct {
    order: u8 = 0,
    shift: u8 = 0,
    state: [MAX_FIR_ORDER]i32 = [_]i32{0} ** MAX_FIR_ORDER,
    coeff_bits: i32 = 0,
    coeff_shift: i32 = 0,
};

pub const ChannelParams = struct {
    filter_params: [NUM_FILTERS]FilterParams = .{ .{}, .{} },
    coeff: [NUM_FILTERS][MAX_FIR_ORDER]i32 = [_][MAX_FIR_ORDER]i32{[_]i32{0} ** MAX_FIR_ORDER} ** NUM_FILTERS,
    huff_offset: i16 = 0,
    sign_huff_offset: i32 = 0,
    codebook: u8 = 0,
    huff_lsbs: u8 = 0,
};

pub const SubStream = struct {
    restart_seen: u8 = 0,
    end_of_stream: u8 = 0,
    noise_type: u16 = 0,
    min_channel: u8 = 0,
    max_channel: u8 = 0,
    coded_channels: u64 = 0,
    max_matrix_channel: u8 = 0,
    ch_assign: [MAX_CHANNELS]u8 = [_]u8{0} ** MAX_CHANNELS,
    mask: u64 = 0,
    channel_params: [MAX_CHANNELS]ChannelParams = [_]ChannelParams{.{}} ** MAX_CHANNELS,
    noise_shift: u8 = 0,
    noisegen_seed: u32 = 0,
    data_check_present: u8 = 0,
    param_presence_flags: u8 = 0,
    num_primitive_matrices: u8 = 0,
    matrix_out_ch: [MAX_MATRICES]u8 = [_]u8{0} ** MAX_MATRICES,
    lsb_bypass: [MAX_MATRICES]u8 = [_]u8{0} ** MAX_MATRICES,
    matrix_coeff: [MAX_MATRICES][MAX_CHANNELS]i32 = [_][MAX_CHANNELS]i32{[_]i32{0} ** MAX_CHANNELS} ** MAX_MATRICES,
    matrix_noise_shift: [MAX_MATRICES]u8 = [_]u8{0} ** MAX_MATRICES,
    quant_step_size: [MAX_CHANNELS]u8 = [_]u8{0} ** MAX_CHANNELS,
    blocksize: u16 = 0,
    blockpos: u16 = 0,
    output_shift: [MAX_CHANNELS]i8 = [_]i8{0} ** MAX_CHANNELS,
    lossless_check_data: i32 = 0,
};

pub const Ctx = struct {
    is_major_sync_unit: i32 = 0,
    major_sync_header_size: i32 = 0,
    params_valid: u8 = 0,
    frame_count: usize = 0,
    num_substreams: u8 = 0,
    extended_substream_info: u8 = 0,
    substream_info: u8 = 0,
    is_atmos: bool = false,
    max_decoded_substream: u8 = 0,
    access_unit_size: i32 = 0,
    access_unit_size_pow2: i32 = 0,
    substream: [MAX_SUBSTREAMS]SubStream = [_]SubStream{.{}} ** MAX_SUBSTREAMS,
    matrix_changed: i32 = 0,
    filter_changed: [MAX_CHANNELS][NUM_FILTERS]i32 = [_][NUM_FILTERS]i32{[_]i32{0} ** NUM_FILTERS} ** MAX_CHANNELS,
    noise_buffer: [MAX_BLOCKSIZE_POW2]i8 = [_]i8{0} ** MAX_BLOCKSIZE_POW2,
    bypassed_lsbs: [MAX_BLOCKSIZE][MAX_CHANNELS]i8 = [_][MAX_CHANNELS]i8{[_]i8{0} ** MAX_CHANNELS} ** MAX_BLOCKSIZE,
    sample_buffer: [MAX_BLOCKSIZE][MAX_CHANNELS]i32 = [_][MAX_CHANNELS]i32{[_]i32{0} ** MAX_CHANNELS} ** MAX_BLOCKSIZE,

    // 流信息
    stream_type: u8 = 0, // 0xbb=MLP 0xba=TrueHD
    group1_bits: u8 = 0,
    group1_samplerate: i32 = 0,
    sample_rate: i32 = 0,
    channels: u8 = 0,
    out_channels: u8 = 0,
    mlp_dbg: usize = 0,
};

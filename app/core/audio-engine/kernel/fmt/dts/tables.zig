// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! DTS（DCA Coherent Acoustics）core 解码常量与表（阶段一：解析层）
//!
//! 对照 FFmpeg：dca_syncwords.h / dca_sample_rate_tab.h / dcadata.c
//! / dca.c / dca_core.h / dca_core.c（audio_mode_ch_mask 等）。
//! 许可登记见 audio-engine/THIRD-PARTY-LICENSES.md：表值按规范与 FFmpeg 表核对。

// ---- dca_syncwords.h ----

/// 核心子流 sync（32 位）文件字节按 16-bit 字大端：7F FE 80 01
pub const syncword_core_be: u32 = 0x7FFE8001;
/// 核心子流 sync，每个 16-bit 字内字节交换后的文件形态：FE 7F 01 80
pub const syncword_core_le: u32 = 0xFE7F0180;
/// 14-bit 打包位流（大端），旧式 DTS（phase 1 不解析）
pub const syncword_core_14b_be: u32 = 0x1FFFE800;
pub const syncword_core_14b_le: u32 = 0xFF1F00E8;
/// DTS-HD EXSS 子流 sync（0x64582025，phase 2）
pub const syncword_substream: u32 = 0x64582025;
/// core 扩展：XCH / X96 / XXCH（dca_syncwords.h）
pub const syncword_xch: u32 = 0x5A5A5A5A;
pub const syncword_xxch: u32 = 0x47004A03;
pub const syncword_x96: u32 = 0x1D95F262;
/// EXSS 扩展分量 sync：XBR / LBR（dca_syncwords.h）
pub const syncword_xbr: u32 = 0x655E315E;
pub const syncword_lbr: u32 = 0x0A801921;

// ---- dca_core.h ----

/// 每 PCM 块的样本数（deficit / audio block 均为 32 样本）
pub const pcmblock_samples: u32 = 32;
/// 每子带样本组数量（core 帧头校验 npcmblocks 须为其整数倍）
pub const subband_samples: u32 = 8;
/// 子带数（core 合成滤波器组）
pub const subbands: u32 = 32;
/// core 每帧主声道上限
pub const core_channels_max: u32 = 6;

/// 声道模式枚举上限（audio_mode 字段须 < count）
pub const amode_count: u8 = 10;

/// core 扩展类型（dca_core.h DCACoreExtAudioType）
pub const ext_xch: u8 = 0;
pub const ext_x96: u8 = 2;
pub const ext_xxch: u8 = 6;

/// LFE 标志
pub const lfe_none: u8 = 0;
pub const lfe_128: u8 = 1; // 128x 抽取
pub const lfe_64: u8 = 2; // 64x 抽取
pub const lfe_invalid: u8 = 3;

// ---- dca_sample_rate_tab.h ----
// ff_dca_sample_rates[16]：索引 4/5/9/10 无对应采样率 → 0
pub const sample_rates = [16]u32{
    0,      8000,  16000, 32000, 0,     0,      11025, 22050,
    44100,  0,     0,      12000, 24000, 48000,  96000, 192000,
};

// ---- dcadata.c / dcadata.h ----
// ff_dca_bit_rates[32]（索引 29/30/31 为 open / variable / lossless 标记）
pub const bit_rates = [32]u32{
    32000,   56000,   64000,   96000,  112000, 128000,
    192000,  224000,  256000,  320000, 384000,
    448000,  512000,  576000,  640000, 768000,
    896000,  1024000, 1152000, 1280000, 1344000,
    1408000, 1411200, 1472000, 1536000, 1920000,
    2048000, 3072000, 3840000, 1,      2,      3,
};

/// br_code 特殊值含义
pub const br_open: u8 = 29;
pub const br_variable: u8 = 30;
pub const br_lossless: u8 = 31;

/// ff_dca_channels[16]：audio_mode → 主声道数（含 XCH/XXCH 前）。
/// 索引即 amode 值（0..9 有效）。
pub const channels_by_amode = [16]u8{
    1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8,
};

// dca.c ff_dca_bits_per_sample[8]（pcmr_code → 源 PCM 位深）
pub const bits_per_sample = [8]u8{
    16, 16, 20, 20, 0, 24, 24, 0,
};

// dca_core.c audio_mode_ch_mask[DCA_AMODE_COUNT]（LFE 位另加）
pub const amode_ch_mask = [10]u32{
    // 0 mono: C
    0x00000001,
    // 1..4 均为立体声家族
    0x00000006, 0x00000006, 0x00000006, 0x00000006,
    // 5 3/0: C L R
    0x00000007,
    // 6 2/1: L R Cs
    0x00000042,
    // 7 3/1: C L R Cs
    0x00000043,
    // 8 2/2: L R Ls Rs
    0x0000001E,
    // 9 3/2 (5.0): C L R Ls Rs
    0x0000001F,
};

/// 扬声器位掩码（dca.h DCASpeakerMask，28 位）
pub const speaker_c: u32 = 0x00000001;
pub const speaker_l: u32 = 0x00000002;
pub const speaker_r: u32 = 0x00000004;
pub const speaker_ls: u32 = 0x00000008;
pub const speaker_rs: u32 = 0x00000010;
pub const speaker_lfe1: u32 = 0x00000020;
pub const speaker_cs: u32 = 0x00000040;
pub const speaker_lsr: u32 = 0x00000080;
pub const speaker_rsr: u32 = 0x00000100;
pub const speaker_lss: u32 = 0x00000200;
pub const speaker_rss: u32 = 0x00000400;
pub const speaker_lc: u32 = 0x00000800;
pub const speaker_rc: u32 = 0x00001000;
pub const speaker_lh: u32 = 0x00002000;
pub const speaker_ch: u32 = 0x00004000;
pub const speaker_rh: u32 = 0x00008000;
pub const speaker_lfe2: u32 = 0x00010000;
pub const speaker_lw: u32 = 0x00020000;
pub const speaker_rw: u32 = 0x00040000;
pub const speaker_oh: u32 = 0x00080000;
pub const speaker_lhs: u32 = 0x00100000;
pub const speaker_rhs: u32 = 0x00200000;
pub const speaker_chr: u32 = 0x00400000;
pub const speaker_lhr: u32 = 0x00800000;
pub const speaker_rhr: u32 = 0x01000000;
pub const speaker_cl: u32 = 0x02000000;
pub const speaker_ll: u32 = 0x04000000;
pub const speaker_rl: u32 = 0x08000000;

/// 扬声器名（按位序；用于打印布局）
pub const speaker_names = [_][]const u8{
    "C", "L", "R", "Ls", "Rs", "LFE", "Cs", "Lsr", "Rsr",
    "Lss", "Rss", "Lc", "Rc", "Lh", "Ch", "Rh", "LFE2", "Lw",
    "Rw", "Oh", "Lhs", "Rhs", "Chr", "Lhr", "Rhr", "Cl", "Ll", "Rl",
};

/// 声道模式显示名（阶段一展示用）
pub const amode_names = [_][]const u8{
    "1/0 (mono)",
    "1+1 (dual mono)",
    "2/0 (stereo)",
    "2/0 sum/diff",
    "Lt/Rt (matrix)",
    "3/0",
    "2/1",
    "3/1",
    "2/2 (quad)",
    "3/2 (5.0)",
};

/// 计数掩码中的扬声器个数（含双声道编码对；与 ff_dca_count_chs_for_mask
/// 等价：2ch 编码对有 1 对 = 2 扬声器，其余按位计数）。
pub fn countChannelsForMask(mask: u32) u8 {
    var count: u8 = 0;
    var m = mask;
    while (m != 0) {
        count += @intCast(m & 1);
        m >>= 1;
    }
    return count;
}

/// 采样率表查找（返回表行）
pub fn sampleRateForCode(code: u8) u32 {
    if (code >= sample_rates.len) return 0;
    return sample_rates[code];
}

/// 位率表查找（br_code → bit/s）
pub fn bitRateForCode(code: u8) u32 {
    if (code >= bit_rates.len) return 0;
    return bit_rates[code];
}

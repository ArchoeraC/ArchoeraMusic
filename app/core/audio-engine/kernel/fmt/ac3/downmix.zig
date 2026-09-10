// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AC-3 / E-AC-3 重矩阵 + 上混延迟 + 立体声下混系数（对照 FFmpeg ac3dec.c，float 路径 USE_FIXED=0）
//!
//! 移植的函数（以 /tmp/ac3dec.c 为唯一参考源）：
//!   setDownmixCoeffs — set_downmix_coeffs（255-311）：依据帧头声道模式与下混电平
//!                      计算立体声（或单声道）下混系数，写 s.downmix_coeffs[2][fbw]
//!   doRematrixing    — do_rematrixing（597-614）：立体声重矩阵，恢复被编码器合并的
//!                      两声道（§7.5.4）
//!   ac3UpmixDelay    — ac3_upmix_delay（662-706）：混合变换块下，把已下混的 delay
//!                      缓冲区上混回原声道布局
//!
//! 与 C 的差异（务必知悉）：
//!   - C 的 do_rematrixing 在调用点（decode_audio_block 1328-1329）以
//!     `channel_mode == AC3_CHMODE_STEREO` 守卫；本实现把该守卫收进函数体，
//!     非立体声时直接返回（对输出无影响，行为一致）。
//!   - 任务描述里 doRematrixing 作用于 transform_coeffs[1]/[2]，但 C 作用于
//!     s->coeffs[1]/[2]。两者算术完全相同（见下），仅数组不同；因 STEREO 模式
//!     下 C 的增益缩放对 ch1/ch2 相同（audio_channel=0），重矩阵与缩放可交换，
//!     作用于 transform_coeffs 与作用于 coeffs 数值结果一致。
//!   - 任务描述把 doRematrixing 写成 (n0-n1)/2、(n0+n1)/2，并称 ac3UpmixDelay
//!     用 downmix_coeffs 做线性组合；这两处与实际 C 不符（C 为 ch1=n0+n1、
//!     ch2=n0-n1；ac3_upmix_delay 仅 memcpy/memset）。为与 C 数值逐位一致，
//!     本实现严格照搬 C。
//!   - C 的 set_downmix_coeffs 返回 int（仅 malloc 失败），float 路径 FIXR12 为
//!     恒等映射，故此处为 void 且直接存 f32。
//!   - C 仅写 downmix_coeffs 的 [0, fbw_channels) 项（LFE 不参与），本实现同。

const t = @import("tables.zig");
const Ctx = @import("ctx.zig").Ctx;

/// 立体声（或单声道）下混系数（对照 C `set_downmix_coeffs`，§7.8.2）。
///
/// cmix/smix 从 gain_levels 按 center/surround_mix_level 取；先取
/// default_coeffs[channel_mode] 的默认对，再按下混电平覆盖（3F/3F1R/3F2R 的
/// 中置、含环绕的 1R/2R 声道），对左右两行分别归一化；output_mode==MONO 时
/// 两行合并为一行 ×LEVEL_MINUS_3DB。结果写 s.downmix_coeffs[2][0..fbw_channels)。
pub fn setDownmixCoeffs(s: *Ctx) void {
    const cmix: f32 = t.gain_levels[@as(usize, @intCast(s.center_mix_level))];
    const smix: f32 = t.gain_levels[@as(usize, @intCast(s.surround_mix_level))];

    var dm: [2][t.AC3_MAX_CHANNELS]f32 = [_][t.AC3_MAX_CHANNELS]f32{[_]f32{0} ** t.AC3_MAX_CHANNELS} ** 2;

    const chm: usize = @intCast(s.channel_mode);
    const fbw: usize = @intCast(s.fbw_channels);
    var i: usize = 0;
    while (i < fbw) : (i += 1) {
        dm[0][i] = t.gain_levels[@as(usize, t.default_coeffs[chm][i][0])];
        dm[1][i] = t.gain_levels[@as(usize, t.default_coeffs[chm][i][1])];
    }

    // 中置声道（索引 1）用帧头的 center_mix_level 覆盖默认值
    if (s.channel_mode > 1 and (s.channel_mode & 1) != 0) {
        dm[0][1] = cmix;
        dm[1][1] = cmix;
    }
    // 单环绕（2F1R/3F1R）：环绕声道（index channel_mode-2）两行同值，×(-3dB)
    if (s.channel_mode == @as(i32, t.AC3_CHMODE_2F1R) or s.channel_mode == @as(i32, t.AC3_CHMODE_3F1R)) {
        const nf: usize = @intCast(s.channel_mode - 2);
        dm[0][nf] = smix * t.LEVEL_MINUS_3DB;
        dm[1][nf] = smix * t.LEVEL_MINUS_3DB;
    }
    // 双环绕（2F2R/3F2R）：左环绕入左行、右环绕入右行（cross）
    if (s.channel_mode == @as(i32, t.AC3_CHMODE_2F2R) or s.channel_mode == @as(i32, t.AC3_CHMODE_3F2R)) {
        const nf: usize = @intCast(s.channel_mode - 4);
        dm[0][nf] = smix;
        dm[1][nf + 1] = smix;
    }

    // 左右行分别归一化
    var norm0: f32 = 0.0;
    var norm1: f32 = 0.0;
    i = 0;
    while (i < fbw) : (i += 1) {
        norm0 += dm[0][i];
        norm1 += dm[1][i];
    }
    norm0 = 1.0 / norm0;
    norm1 = 1.0 / norm1;
    i = 0;
    while (i < fbw) : (i += 1) {
        dm[0][i] *= norm0;
        dm[1][i] *= norm1;
    }

    // 单声道输出：两行相加并再衰减 -3dB（只写第 0 行，与 C 一致）
    if (s.output_mode == @as(i32, t.AC3_CHMODE_MONO)) {
        i = 0;
        while (i < fbw) : (i += 1) {
            dm[0][i] = (dm[0][i] + dm[1][i]) * t.LEVEL_MINUS_3DB;
        }
    }

    i = 0;
    while (i < fbw) : (i += 1) {
        s.downmix_coeffs[0][i] = dm[0][i];
        s.downmix_coeffs[1][i] = dm[1][i];
    }
}

/// 立体声重矩阵（对照 C `do_rematrixing`，§7.5.4）。
///
/// 仅 channel_mode==STEREO 生效（对应 C 调用点守卫）。对每个置位
/// rematrixing_flags 的带，bin 从 rematrix_band_tab[bnd] 到
/// min(end, rematrix_band_tab[bnd+1])（end=min(end_freq[1], end_freq[2])）：
///   ch1 = n0 + n1；ch2 = n0 - n1
/// 恢复编码器 rematrix 前的原始 L/R（编码器存 X=(L+R)/2、Y=(L-R)/2，
/// 解码端 L=X+Y、R=X-Y）。操作 transform_coeffs[1]/[2]。
pub fn doRematrixing(s: *Ctx) void {
    if (s.channel_mode != @as(i32, t.AC3_CHMODE_STEREO)) return;

    const end: usize = @min(
        @as(usize, @intCast(s.end_freq[1])),
        @as(usize, @intCast(s.end_freq[2])),
    );

    var bnd: usize = 0;
    while (bnd < @as(usize, @intCast(s.num_rematrixing_bands))) : (bnd += 1) {
        if (s.rematrixing_flags[bnd] != 0) {
            const bndend: usize = @min(end, @as(usize, t.rematrix_band_tab[bnd + 1]));
            var i: usize = t.rematrix_band_tab[bnd];
            while (i < bndend) : (i += 1) {
                const tmp0 = s.transform_coeffs[1][i];
                s.transform_coeffs[1][i] += s.transform_coeffs[2][i];
                s.transform_coeffs[2][i] = tmp0 - s.transform_coeffs[2][i];
            }
        }
    }
}

/// 上混 delay 样本回原声道布局（对照 C `ac3_upmix_delay`）。
///
/// 混合变换块（different_transforms）下 delay 已按输出声道下混过，上混重建
/// 各声道以便下混前逐声道 IMDCT。C 的实现只做 memcpy/memset（不用
/// downmix_coeffs，并非可逆重建），本实现严格照搬：
///   DUALMONO/STEREO：delay[1] = delay[0]
///   2F2R            ：delay[3] = 0（fallthrough）→ delay[2] = 0
///   2F1R            ：delay[2] = 0
///   3F2R            ：delay[4] = 0（fallthrough）→ delay[3] = 0 → delay[2] = delay[1]；delay[1] = 0
///   3F1R            ：delay[3] = 0 → delay[2] = delay[1]；delay[1] = 0
///   3F              ：delay[2] = delay[1]；delay[1] = 0
pub fn ac3UpmixDelay(s: *Ctx) void {
    switch (@as(u8, @intCast(s.channel_mode))) {
        t.AC3_CHMODE_DUALMONO, t.AC3_CHMODE_STEREO => {
            // upmix mono to stereo
            @memcpy(&s.delay[1], &s.delay[0]);
        },
        t.AC3_CHMODE_2F2R => {
            @memset(&s.delay[3], 0);
            @memset(&s.delay[2], 0);
        },
        t.AC3_CHMODE_2F1R => {
            @memset(&s.delay[2], 0);
        },
        t.AC3_CHMODE_3F2R => {
            @memset(&s.delay[4], 0);
            @memset(&s.delay[3], 0);
            @memcpy(&s.delay[2], &s.delay[1]);
            @memset(&s.delay[1], 0);
        },
        t.AC3_CHMODE_3F1R => {
            @memset(&s.delay[3], 0);
            @memcpy(&s.delay[2], &s.delay[1]);
            @memset(&s.delay[1], 0);
        },
        t.AC3_CHMODE_3F => {
            @memcpy(&s.delay[2], &s.delay[1]);
            @memset(&s.delay[1], 0);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// 单元测试（`zig test downmix.zig`）
// ---------------------------------------------------------------------------

const std = @import("std");

test "setDownmixCoeffs: STEREO 默认系数 = gain_levels 手工值" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_STEREO;
    s.output_mode = t.AC3_CHMODE_STEREO;
    s.fbw_channels = 2;
    setDownmixCoeffs(&s);
    // default_coeffs[2] = { {2,7},{7,2} }；gain[2]=1.0 gain[7]=0.0；
    // 各行和为 1.0 → 归一化不变
    try std.testing.expectEqual(@as(f32, t.gain_levels[2]), s.downmix_coeffs[0][0]);
    try std.testing.expectEqual(@as(f32, t.gain_levels[7]), s.downmix_coeffs[0][1]);
    try std.testing.expectEqual(@as(f32, t.gain_levels[7]), s.downmix_coeffs[1][0]);
    try std.testing.expectEqual(@as(f32, t.gain_levels[2]), s.downmix_coeffs[1][1]);
}

test "setDownmixCoeffs: 5.1(3F2R)→stereo 与手工矩阵一致" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_3F2R;
    s.output_mode = t.AC3_CHMODE_3F2R;
    s.fbw_channels = 5;
    s.center_mix_level = 4; // gain = 2^-0.5 = 0.7071067811865476
    s.surround_mix_level = 6; // gain = 0.5
    setDownmixCoeffs(&s);
    const inv: f32 = 1.0 / (1.0 + 0.7071067811865476 + 0.0 + 0.5 + 0.0);
    try std.testing.expectApproxEqAbs(t.gain_levels[2] * inv, s.downmix_coeffs[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(0.7071067811865476 * inv, s.downmix_coeffs[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.downmix_coeffs[0][2], 1e-6);
    try std.testing.expectApproxEqAbs(0.5 * inv, s.downmix_coeffs[0][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.downmix_coeffs[0][4], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.downmix_coeffs[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(0.7071067811865476 * inv, s.downmix_coeffs[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(t.gain_levels[2] * inv, s.downmix_coeffs[1][2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.downmix_coeffs[1][3], 1e-6);
    try std.testing.expectApproxEqAbs(0.5 * inv, s.downmix_coeffs[1][4], 1e-6);
}

test "setDownmixCoeffs: 3F 中置覆盖 + 单声道合并" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_3F;
    s.output_mode = t.AC3_CHMODE_MONO;
    s.fbw_channels = 3;
    s.center_mix_level = 4;
    s.surround_mix_level = 0;
    setDownmixCoeffs(&s);
    // 归一化后：row0 = row1 = {1, 0.7071, 0} / (1+0.7071) = {0.585786, 0.414214, 0}
    const n: f32 = 1.0 / (1.0 + 0.7071067811865476);
    // 单声道合并（只改第 0 行）：(row0+row1)*LEVEL_MINUS_3DB
    //   [0] = (1*n + 0)*k = n*k；[1] = (0.7071n+0.7071n)*k = n（2*0.7071*k=1）；
    //   [2] = (0 + 1*n)*k = n*k；k=LEVEL_MINUS_3DB
    try std.testing.expectApproxEqAbs(n * t.LEVEL_MINUS_3DB, s.downmix_coeffs[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(n, s.downmix_coeffs[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(n * t.LEVEL_MINUS_3DB, s.downmix_coeffs[0][2], 1e-6);
    // 第 1 行保持归一化后原值
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.downmix_coeffs[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(0.7071067811865476 * n, s.downmix_coeffs[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(1.0 * n, s.downmix_coeffs[1][2], 1e-6);
}

test "doRematrixing: 立体声带内 (n0+n1)/(n0-n1)" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_STEREO;
    s.end_freq[1] = 70;
    s.end_freq[2] = 70;
    s.num_rematrixing_bands = 4;
    s.rematrixing_flags = [_]i32{ 1, 0, 1, 1 };
    // 合成系数：c1[i]=i+0.5，c2[i]=0.25-1.5i（全部精确可表示）
    for (0..256) |i| {
        const fi: f32 = @floatFromInt(i);
        s.transform_coeffs[1][i] = fi + 0.5;
        s.transform_coeffs[2][i] = 0.25 - 1.5 * fi;
    }
    doRematrixing(&s);
    // 带 0 [13,25)：ch1=n0+n1，ch2=n0-n1
    for (13..25) |i| {
        const n0: f32 = @floatFromInt(i);
        const n1: f32 = 0.25 - 1.5 * @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(n0 + 0.5 + n1, s.transform_coeffs[1][i], 1e-6);
        try std.testing.expectApproxEqAbs(n0 + 0.5 - n1, s.transform_coeffs[2][i], 1e-6);
    }
    // 带 1 [25,37) 未置位：保持原值
    for (25..37) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(i)) + 0.5, s.transform_coeffs[1][i], 1e-6);
    }
    // 带 2 [37,61)：同样变换
    for (37..61) |i| {
        const n0: f32 = @floatFromInt(i);
        const n1: f32 = 0.25 - 1.5 * @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(n0 + 0.5 + n1, s.transform_coeffs[1][i], 1e-6);
        try std.testing.expectApproxEqAbs(n0 + 0.5 - n1, s.transform_coeffs[2][i], 1e-6);
    }
    // 带 3 [61,70)：变换
    for (61..70) |i| {
        const n0: f32 = @floatFromInt(i);
        const n1: f32 = 0.25 - 1.5 * @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(n0 + 0.5 + n1, s.transform_coeffs[1][i], 1e-6);
        try std.testing.expectApproxEqAbs(n0 + 0.5 - n1, s.transform_coeffs[2][i], 1e-6);
    }
}

test "doRematrixing: 非立体声不动作" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_3F;
    s.end_freq[1] = 70;
    s.end_freq[2] = 70;
    s.num_rematrixing_bands = 4;
    s.rematrixing_flags = [_]i32{ 1, 1, 1, 1 };
    for (0..256) |i| {
        const fi: f32 = @floatFromInt(i);
        s.transform_coeffs[1][i] = fi;
        s.transform_coeffs[2][i] = -fi;
    }
    doRematrixing(&s);
    for (0..256) |i| {
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), s.transform_coeffs[1][i]);
        try std.testing.expectEqual(@as(f32, -@as(f32, @floatFromInt(i))), s.transform_coeffs[2][i]);
    }
}

test "ac3UpmixDelay: DUALMONO/STEREO 复制 ch0→ch1" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_STEREO;
    fillDelay(&s);
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[1], &s.delay[0]));
    try std.testing.expectEqual(@as(f32, 1.0), s.delay[0][0]);
    try std.testing.expectEqual(@as(f32, 64.75), s.delay[0][255]); // 255*0.25+1
    // 其它声道不受影响
    try std.testing.expectEqual(@as(f32, 201.0), s.delay[2][0]);
    try std.testing.expectEqual(@as(f32, 301.0), s.delay[3][0]);
}

test "ac3UpmixDelay: 3F 重建 C 声道" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_3F;
    fillDelay(&s);
    const old_d1 = s.delay[1];
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[2], &old_d1)); // C = 旧 R
    try std.testing.expect(std.mem.eql(f32, &s.delay[1], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expectEqual(@as(f32, 1.0), s.delay[0][0]); // L 不变
    try std.testing.expectEqual(@as(f32, 301.0), s.delay[3][0]); // 3F 不碰 ch3
}

test "ac3UpmixDelay: 3F2R 链式 fallthrough" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_3F2R;
    fillDelay(&s);
    const old_d1 = s.delay[1];
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[1], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expect(std.mem.eql(f32, &s.delay[2], &old_d1));
    try std.testing.expect(std.mem.eql(f32, &s.delay[3], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expect(std.mem.eql(f32, &s.delay[4], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expectEqual(@as(f32, 1.0), s.delay[0][0]); // L 不变
}

test "ac3UpmixDelay: 2F2R/2F1R/3F1R 清环绕声道" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_2F2R;
    fillDelay(&s);
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[2], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expect(std.mem.eql(f32, &s.delay[3], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expectEqual(@as(f32, 1.0), s.delay[0][0]);
    try std.testing.expectEqual(@as(f32, 101.0), s.delay[1][0]);

    s = .{};
    s.channel_mode = t.AC3_CHMODE_2F1R;
    fillDelay(&s);
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[2], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expectEqual(@as(f32, 301.0), s.delay[3][0]); // 2F1R 不碰 ch3

    s = .{};
    s.channel_mode = t.AC3_CHMODE_3F1R;
    fillDelay(&s);
    const old_d1 = s.delay[1];
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[2], &old_d1));
    try std.testing.expect(std.mem.eql(f32, &s.delay[1], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expect(std.mem.eql(f32, &s.delay[3], &[_]f32{0} ** t.AC3_BLOCK_SIZE));
    try std.testing.expectEqual(@as(f32, 401.0), s.delay[4][0]); // 3F1R 不碰 ch4
}

test "ac3UpmixDelay: DUALMONO 同 STEREO" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_DUALMONO;
    fillDelay(&s);
    ac3UpmixDelay(&s);
    try std.testing.expect(std.mem.eql(f32, &s.delay[1], &s.delay[0]));
}

test "ac3UpmixDelay: 未覆盖模式不动作（MONO）" {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_MONO;
    fillDelay(&s);
    ac3UpmixDelay(&s);
    try std.testing.expectEqual(@as(f32, 1.0), s.delay[0][0]);
    try std.testing.expectEqual(@as(f32, 101.0), s.delay[1][0]);
    try std.testing.expectEqual(@as(f32, 201.0), s.delay[2][0]);
}

fn fillDelay(s: *Ctx) void {
    for (0..t.EAC3_MAX_CHANNELS) |ch| {
        for (0..t.AC3_BLOCK_SIZE) |j| {
            s.delay[ch][j] = @as(f32, @floatFromInt(ch)) * 100.0 +
                @as(f32, @floatFromInt(j)) * 0.25 + 1.0;
        }
    }
}

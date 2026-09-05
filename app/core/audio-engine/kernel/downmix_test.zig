//! AC-3 重矩阵 / 上混延迟 / 下混系数独立测试程序（zig build-exe <本文件> 可运行）。
//!
//! 与 /tmp/ac3downmix_ref.c 的 C 参考实现（FFmpeg ac3dec.c 三个函数逐字移植 +
//! 合成输入）交叉校验：同一输入 → 完全相同的 f32 位模式（dump 行以 u32 十六进制
//! 输出，C/Zig 逐位一致）。同时内嵌断言覆盖各分支。

const std = @import("std");
const t = @import("fmt/ac3/tables.zig");
const Ctx = @import("fmt/ac3/ctx.zig").Ctx;
const dm = @import("fmt/ac3/downmix.zig");

var failures: usize = 0;

fn check(ok: bool, name: []const u8) void {
    if (ok) {
        std.debug.print("PASS {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("FAIL {s}\n", .{name});
    }
}

fn bits(v: f32) u32 {
    return @bitCast(v);
}

/// 交叉校验 dump 写 stdout（PASS/FAIL 经 std.debug.print 写 stderr）。
/// 用 writeStreamingAll（无持久 Writer/buffer 状态），避免与 debug_io 缓冲冲突。
fn dump(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const io = std.Options.debug_io;
    std.Io.File.writeStreamingAll(.stdout(), io, bytes) catch return;
}

fn dumpBits(comptime tag: []const u8, v: f32) void {
    dump("{s} {x:0>8}\n", .{ tag, bits(v) });
}

// ---- setDownmixCoeffs 各声道模式合成用例 ----
const SdmCase = struct {
    name: []const u8,
    chm: i32,
    out: i32,
    fbw: i32,
    cmix: i32,
    smix: i32,
};
// 用例：(name, channel_mode, output_mode, fbw, center_mix_level, surround_mix_level)
const sdm_cases = [_]SdmCase{
    .{ .name = "sdm_stereo", .chm = t.AC3_CHMODE_STEREO, .out = t.AC3_CHMODE_STEREO, .fbw = 2, .cmix = 0, .smix = 0 },
    .{ .name = "sdm_3f", .chm = t.AC3_CHMODE_3F, .out = t.AC3_CHMODE_3F, .fbw = 3, .cmix = 4, .smix = 0 },
    .{ .name = "sdm_3f_mono", .chm = t.AC3_CHMODE_3F, .out = t.AC3_CHMODE_MONO, .fbw = 3, .cmix = 4, .smix = 0 },
    .{ .name = "sdm_3f2r", .chm = t.AC3_CHMODE_3F2R, .out = t.AC3_CHMODE_3F2R, .fbw = 5, .cmix = 4, .smix = 6 },
    .{ .name = "sdm_3f2r_mono", .chm = t.AC3_CHMODE_3F2R, .out = t.AC3_CHMODE_MONO, .fbw = 5, .cmix = 4, .smix = 6 },
    .{ .name = "sdm_2f1r", .chm = t.AC3_CHMODE_2F1R, .out = t.AC3_CHMODE_2F1R, .fbw = 3, .cmix = 4, .smix = 4 },
    .{ .name = "sdm_3f1r", .chm = t.AC3_CHMODE_3F1R, .out = t.AC3_CHMODE_3F1R, .fbw = 4, .cmix = 4, .smix = 4 },
    .{ .name = "sdm_2f2r", .chm = t.AC3_CHMODE_2F2R, .out = t.AC3_CHMODE_2F2R, .fbw = 4, .cmix = 4, .smix = 4 },
    .{ .name = "sdm_dualmono", .chm = t.AC3_CHMODE_DUALMONO, .out = t.AC3_CHMODE_DUALMONO, .fbw = 2, .cmix = 0, .smix = 0 },
    .{ .name = "sdm_mono", .chm = t.AC3_CHMODE_MONO, .out = t.AC3_CHMODE_MONO, .fbw = 1, .cmix = 0, .smix = 0 },
};

fn runSetDownmixCoeffs() void {
    for (sdm_cases) |c| {
        var s: Ctx = .{};
        s.channel_mode = c.chm;
        s.output_mode = c.out;
        s.fbw_channels = c.fbw;
        s.center_mix_level = c.cmix;
        s.surround_mix_level = c.smix;
        dm.setDownmixCoeffs(&s);

        // 交叉校验 dump（C 参考同样输出 <case>_0_<i> / <case>_1_<i>）
        var i: usize = 0;
        while (i < @as(usize, @intCast(c.fbw))) : (i += 1) {
            dump("{s}_0_{d} {x:0>8}\n", .{ c.name, i, bits(s.downmix_coeffs[0][i]) });
            dump("{s}_1_{d} {x:0>8}\n", .{ c.name, i, bits(s.downmix_coeffs[1][i]) });
        }
        // 未写部分应保持 0（C 只写 [0,fbw)）
        var name_buf: [64]u8 = undefined;
        const nm = std.fmt.bufPrint(&name_buf, "{s}_tail_zero", .{c.name}) catch "tail_zero";
        check(s.downmix_coeffs[0][t.AC3_MAX_CHANNELS - 1] == 0.0 and
            s.downmix_coeffs[1][t.AC3_MAX_CHANNELS - 1] == 0.0, nm);
    }
}

fn runRematrixingDump() void {
    var s: Ctx = .{};
    s.channel_mode = t.AC3_CHMODE_STEREO;
    s.end_freq[1] = 70;
    s.end_freq[2] = 70;
    s.num_rematrixing_bands = 4;
    s.rematrixing_flags = [_]i32{ 1, 0, 1, 1 };
    for (0..256) |k| {
        const fk: f32 = @floatFromInt(k);
        s.transform_coeffs[1][k] = fk + 0.5;
        s.transform_coeffs[2][k] = 0.25 - 1.5 * fk;
    }
    dm.doRematrixing(&s);
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        dump("rmx_1_{d} {x:0>8}\n", .{ i, bits(s.transform_coeffs[1][i]) });
        dump("rmx_2_{d} {x:0>8}\n", .{ i, bits(s.transform_coeffs[2][i]) });
    }
    // 70..253 未被触及（end=70）
    check(s.transform_coeffs[1][70] == 70.5 and s.transform_coeffs[2][70] == 0.25 - 1.5 * 70.0,
        "rmx_tail_untouched");

    // 非立体声：不动作
    var s2: Ctx = .{};
    s2.channel_mode = t.AC3_CHMODE_3F;
    s2.end_freq[1] = 70;
    s2.end_freq[2] = 70;
    s2.num_rematrixing_bands = 4;
    s2.rematrixing_flags = [_]i32{ 1, 1, 1, 1 };
    for (0..256) |k| {
        const fk: f32 = @floatFromInt(k);
        s2.transform_coeffs[1][k] = fk;
        s2.transform_coeffs[2][k] = -fk;
    }
    dm.doRematrixing(&s2);
    var ok = true;
    for (0..256) |k| {
        if (s2.transform_coeffs[1][k] != @as(f32, @floatFromInt(k))) ok = false;
        if (s2.transform_coeffs[2][k] != -@as(f32, @floatFromInt(k))) ok = false;
    }
    check(ok, "rmx_nonstereo_noop");
}

fn fillDelay(s: *Ctx) void {
    for (0..t.EAC3_MAX_CHANNELS) |ch| {
        for (0..t.AC3_BLOCK_SIZE) |j| {
            s.delay[ch][j] = @as(f32, @floatFromInt(ch)) * 100.0 +
                @as(f32, @floatFromInt(j)) * 0.25 + 1.0;
        }
    }
}

fn runUpmixDump() void {
    var chm: i32 = 0;
    while (chm < 8) : (chm += 1) {
        var s: Ctx = .{};
        s.channel_mode = chm;
        fillDelay(&s);
        dm.ac3UpmixDelay(&s);
        const tag = chm;
        var ch: usize = 0;
        while (ch < 6) : (ch += 1) {
            dump("upx_{d}_{d}_{d} {x:0>8}\n", .{ tag, ch, 0, bits(s.delay[ch][0]) });
            dump("upx_{d}_{d}_{d} {x:0>8}\n", .{ tag, ch, 255, bits(s.delay[ch][255]) });
        }
    }
}

fn runUnitAssertions() void {
    // STEREO 默认系数 vs gain_levels 手工值
    {
        var s: Ctx = .{};
        s.channel_mode = t.AC3_CHMODE_STEREO;
        s.output_mode = t.AC3_CHMODE_STEREO;
        s.fbw_channels = 2;
        dm.setDownmixCoeffs(&s);
        check(s.downmix_coeffs[0][0] == t.gain_levels[2] and
            s.downmix_coeffs[0][1] == t.gain_levels[7] and
            s.downmix_coeffs[1][0] == t.gain_levels[7] and
            s.downmix_coeffs[1][1] == t.gain_levels[2], "unit_sdm_stereo_default");
    }
    // 5.1(3F2R)→stereo 手工矩阵
    {
        var s: Ctx = .{};
        s.channel_mode = t.AC3_CHMODE_3F2R;
        s.output_mode = t.AC3_CHMODE_3F2R;
        s.fbw_channels = 5;
        s.center_mix_level = 4;
        s.surround_mix_level = 6;
        dm.setDownmixCoeffs(&s);
        const inv: f32 = 1.0 / (1.0 + 0.7071067811865476 + 0.0 + 0.5 + 0.0);
        var ok = true;
        ok = ok and std.math.approxEqAbs(f32, t.gain_levels[2] * inv, s.downmix_coeffs[0][0], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.7071067811865476 * inv, s.downmix_coeffs[0][1], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.0, s.downmix_coeffs[0][2], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.5 * inv, s.downmix_coeffs[0][3], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.0, s.downmix_coeffs[0][4], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.0, s.downmix_coeffs[1][0], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.7071067811865476 * inv, s.downmix_coeffs[1][1], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, t.gain_levels[2] * inv, s.downmix_coeffs[1][2], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.0, s.downmix_coeffs[1][3], 1e-6);
        ok = ok and std.math.approxEqAbs(f32, 0.5 * inv, s.downmix_coeffs[1][4], 1e-6);
        check(ok, "unit_sdm_5p1_stereo");
    }
    // 重矩阵 (n0+n1)/(n0-n1)
    {
        var s: Ctx = .{};
        s.channel_mode = t.AC3_CHMODE_STEREO;
        s.end_freq[1] = 70;
        s.end_freq[2] = 70;
        s.num_rematrixing_bands = 4;
        s.rematrixing_flags = [_]i32{ 1, 0, 1, 1 };
        for (0..256) |i| {
            const fi: f32 = @floatFromInt(i);
            s.transform_coeffs[1][i] = fi + 0.5;
            s.transform_coeffs[2][i] = 0.25 - 1.5 * fi;
        }
        dm.doRematrixing(&s);
        var ok = true;
        const rngs = [_][2]usize{ .{ 13, 25 }, .{ 37, 61 }, .{ 61, 70 } };
        for (rngs) |r| {
            var i = r[0];
            while (i < r[1]) : (i += 1) {
                const n0: f32 = @floatFromInt(i);
                const n1: f32 = 0.25 - 1.5 * @as(f32, @floatFromInt(i));
                ok = ok and std.math.approxEqAbs(f32, n0 + 0.5 + n1, s.transform_coeffs[1][i], 1e-6);
                ok = ok and std.math.approxEqAbs(f32, n0 + 0.5 - n1, s.transform_coeffs[2][i], 1e-6);
            }
        }
        var i: usize = 25;
        while (i < 37) : (i += 1) { // flag=0 的带不变
            ok = ok and s.transform_coeffs[1][i] == @as(f32, @floatFromInt(i)) + 0.5;
        }
        check(ok, "unit_rematrixing");
    }
    // 上混延迟 3F
    {
        var s: Ctx = .{};
        s.channel_mode = t.AC3_CHMODE_3F;
        fillDelay(&s);
        const old_d1 = s.delay[1];
        dm.ac3UpmixDelay(&s);
        var ok = std.mem.eql(f32, &s.delay[2], &old_d1);
        ok = ok and std.mem.eql(f32, &s.delay[1], &[_]f32{0} ** t.AC3_BLOCK_SIZE);
        ok = ok and s.delay[0][0] == 1.0 and s.delay[3][0] == 301.0;
        check(ok, "unit_upmix_3f");
    }
}

pub fn main() void {
    runUnitAssertions();
    runSetDownmixCoeffs();
    runRematrixingDump();
    runUpmixDump();

    if (failures != 0) {
        std.debug.print("{d} FAILURES\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("ALL PASS\n", .{});
}

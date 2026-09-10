// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! kissfft.zig（libopus 移植）与 CUSTOM_MODES 浮点 libopus 的 MDCT golden 对比测试。
//! golden 格式（gold.c 生成）：u32 N2, u32 overlap, f32[N2] in, f32[overlap] window,
//! f32[N] out, f32[N2] trig（shift 级偏移后）, u16[N4] bitrev, f32[N4] complex twiddles。

const std = @import("std");
const kissfft = @import("kissfft.zig");

const Path = "/tmp/opencode/opusgold/g2";

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch return error.OpenFailed;
    const len = std.Io.File.length(file, io) catch return error.IoError;
    const buf = try alloc.alloc(u8, len);
    const n = std.Io.File.readPositionalAll(file, io, buf, 0) catch return error.IoError;
    if (n != len) return error.ShortRead;
    return buf;
}

fn runCase(path: []const u8, n: usize, maxshift: usize, overlap: usize, shift: usize, stride: usize) !void {
    const data = try readFileAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(data);
    var pos: usize = 0;
    const rd = struct {
        fn u32r(d: []const u8, p: *usize) u32 {
            const v = std.mem.readInt(u32, d[p.*..][0..4], .little);
            p.* += 4;
            return v;
        }
        fn f32r(d: []const u8, p: *usize) f32 {
            const v = std.mem.readInt(u32, d[p.*..][0..4], .little);
            p.* += 4;
            return @bitCast(v);
        }
    };
    const n2_gold = rd.u32r(data, &pos);
    const overlap_gold = rd.u32r(data, &pos);
    const trig_n = rd.u32r(data, &pos);
    try std.testing.expectEqual(@as(u32, @intCast(n >> 1)), n2_gold);
    try std.testing.expectEqual(@as(u32, @intCast(overlap)), overlap_gold);
    try std.testing.expectEqual(@as(u32, @intCast(n >> @as(u6, @intCast(shift + 1)))), trig_n);
    const n4 = n >> 2;
    const fft_n = n4 >> @as(u6, @intCast(shift));

    var in_: [2000]f32 = undefined;
    var window: [256]f32 = undefined;
    var out: [2048]f32 = undefined;
    var out_gold: [2048]f32 = undefined;

    for (0..n2_gold) |i| in_[i] = rd.f32r(data, &pos);
    for (0..overlap_gold) |i| window[i] = rd.f32r(data, &pos);
    for (0..n) |i| out_gold[i] = rd.f32r(data, &pos);

    var gold_trig: [1024]f32 = undefined;
    for (0..trig_n) |i| gold_trig[i] = rd.f32r(data, &pos);
    var gold_bitrev: [480]u16 = undefined;
    for (0..fft_n) |i| {
        const v = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        gold_bitrev[i] = v;
    }
    var gold_tw: [2 * 480]f32 = undefined;
    for (0..fft_n) |i| {
        gold_tw[2 * i] = rd.f32r(data, &pos);
        gold_tw[2 * i + 1] = rd.f32r(data, &pos);
    }

    // 用 MDCT lookup 构建
    const l = kissfft.mdctInit(n, maxshift);
    @memset(&out, 0);
    kissfft.cltMdctBackward(&l, in_[0..n2_gold], out[0..n], window[0..overlap], overlap, shift, stride);

    // 比较 out（逐位）
    for (0..n) |i| {
        const a: u32 = @bitCast(out[i]);
        const b: u32 = @bitCast(out_gold[i]);
        try std.testing.expectEqual(b, a);
    }

    // 比较 trig（shift 级偏移后 trig_n 个）
    var trig_off: usize = 0;
    var tn: usize = n;
    for (0..shift) |_| {
        tn >>= 1;
        trig_off += tn;
    }
    for (0..trig_n) |i| {
        const a: u32 = @bitCast(l.trig[trig_off + i]);
        const b: u32 = @bitCast(gold_trig[i]);
        try std.testing.expectEqual(b, a);
    }

    // 比较 bitrev 与 twiddles
    const st = &l.kfft[shift];
    for (0..fft_n) |i| try std.testing.expectEqual(gold_bitrev[i], st.bitrev[i]);
    for (0..fft_n) |i| {
        try std.testing.expectEqual(gold_tw[2 * i], @as(f32, st.twiddles[i].r));
        try std.testing.expectEqual(gold_tw[2 * i + 1], @as(f32, st.twiddles[i].i));
    }
}

test "kissfft mdct golden: N=1920 shift=0" {
    try runCase(Path ++ "/g1920_s0.bin", 1920, 3, 120, 0, 1);
}
test "kissfft mdct golden: N=1920 shift=1" {
    try runCase(Path ++ "/g1920_s1.bin", 1920, 3, 120, 1, 1);
}
test "kissfft mdct golden: N=1920 shift=2" {
    try runCase(Path ++ "/g1920_s2.bin", 1920, 3, 120, 2, 1);
}
test "kissfft mdct golden: N=1920 shift=3" {
    try runCase(Path ++ "/g1920_s3.bin", 1920, 3, 120, 3, 1);
}
test "kissfft mdct golden: N=1920 shift=3 stride=8 (transient)" {
    try runCase(Path ++ "/g1920_s3_s8.bin", 1920, 3, 120, 3, 8);
}
test "kissfft mdct golden: N=960 shift=0" {
    try runCase(Path ++ "/g960_s0.bin", 960, 3, 120, 0, 1);
}
test "kissfft mdct golden: N=960 shift=1" {
    try runCase(Path ++ "/g960_s1.bin", 960, 3, 120, 1, 1);
}
test "kissfft mdct golden: N=960 shift=2" {
    try runCase(Path ++ "/g960_s2.bin", 960, 3, 120, 2, 1);
}
test "kissfft mdct golden: N=960 shift=3" {
    try runCase(Path ++ "/g960_s3.bin", 960, 3, 120, 3, 1);
}
test "kissfft mdct golden: N=480 shift=0" {
    try runCase(Path ++ "/g480_s0.bin", 480, 2, 120, 0, 1);
}
test "kissfft mdct golden: N=480 shift=1" {
    try runCase(Path ++ "/g480_s1.bin", 480, 2, 120, 1, 1);
}
test "kissfft mdct golden: N=480 shift=2" {
    try runCase(Path ++ "/g480_s2.bin", 480, 2, 120, 2, 1);
}
test "kissfft mdct golden: N=240 shift=0" {
    try runCase(Path ++ "/g240_s0.bin", 240, 2, 120, 0, 1);
}
test "kissfft mdct golden: N=240 shift=1" {
    try runCase(Path ++ "/g240_s1.bin", 240, 2, 120, 1, 1);
}
test "kissfft mdct golden: N=240 shift=2" {
    try runCase(Path ++ "/g240_s2.bin", 240, 2, 120, 2, 1);
}

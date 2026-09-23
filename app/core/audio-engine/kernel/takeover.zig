// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 接管门控（方向③ F5，docs/audio-kernel-expansion-plan.md §4.2）。
//!
//! 生产引擎（C 壳）在尝试自研内核解码前，需要一个**静态、可编译期求值**的
//! 「哪些格式已被接管」视图，以免对必然失败的格式做无效 native open：
//!   - [`bitmap`]：按 `probe.Format` 枚举序折叠 `probe.enabled` 的 u64 位图
//!     （bit i = 第 i 个 Format 是否接管），供 C 壳一次性取回；
//!   - [`ofFormat`]：单格式判定（与位图同源，逐位一致性由 C 测试对拍）；
//!   - [`ofExt`]：扩展名 → Format 判定（编译期表），`unknown` 让 C 壳保留
//!     try-then-fallback（probe 仍可能按内容识别）。
//!
//! 本模块只读 `probe` 的编译期开关，零运行期状态、零分配。

const std = @import("std");
const probe = @import("probe.zig");

/// 扩展名判定结果（与 C ABI 的 1/0/-1 对齐）。
pub const Verdict = enum(c_int) {
    /// 扩展名明确**未**接管：C 壳可跳过无效 native open，直接 FFmpeg。
    no = 0,
    /// 扩展名明确已接管：优先 native（失败仍按既有语义回退）。
    yes = 1,
    /// 未知扩展名/无扩展名：保留 try-then-fallback（交给 probe 按内容判定）。
    unknown = -1,
};

/// 接管格式位图：bit i（i = `@intFromEnum(probe.Format)`）= 该格式是否被接管。
/// 编译期常量，遍历 `probe.Format` 全量折叠 `probe.enabled`。
pub const bitmap: u64 = blk: {
    @setEvalBranchQuota(20000);
    var b: u64 = 0;
    for (std.meta.fields(probe.Format)) |f| {
        const fmt: probe.Format = @enumFromInt(f.value);
        if (probe.enabled(fmt)) b |= (@as(u64, 1) << @intCast(f.value));
    }
    break :blk b;
};

/// 单格式是否被接管（与 [`bitmap`] 同源；`unknown` 恒为 false）。
pub fn ofFormat(fmt: probe.Format) bool {
    return probe.enabled(fmt);
}

/// 扩展名 → Format 的编译期映射表（键不含前导点、小写；查询时归一化）。
/// 一个扩展名只映射到一个 Format；容器内多 codec 的歧义名（如 `.ogg`）不入表。
const ext_format = [_]struct { ext: []const u8, fmt: probe.Format }{
    .{ .ext = "mp3", .fmt = .mp3 },
    .{ .ext = "mp2", .fmt = .mp3 },
    .{ .ext = "mp1", .fmt = .mp3 },
    .{ .ext = "flac", .fmt = .flac },
    .{ .ext = "opus", .fmt = .ogg_opus },
    .{ .ext = "spx", .fmt = .ogg_speex },
    // 未压缩 PCM 家族（fmt/wav 内部按容器分派）
    .{ .ext = "wav", .fmt = .wav },
    .{ .ext = "wave", .fmt = .wav },
    .{ .ext = "rf64", .fmt = .wav },
    .{ .ext = "w64", .fmt = .wav },
    .{ .ext = "aiff", .fmt = .wav },
    .{ .ext = "aif", .fmt = .wav },
    .{ .ext = "aifc", .fmt = .wav },
    .{ .ext = "caf", .fmt = .wav },
    .{ .ext = "au", .fmt = .wav },
    .{ .ext = "snd", .fmt = .wav },
    .{ .ext = "m4a", .fmt = .m4a },
    .{ .ext = "m4b", .fmt = .m4a },
    .{ .ext = "mp4", .fmt = .m4a },
    .{ .ext = "aac", .fmt = .aac },
    .{ .ext = "latm", .fmt = .latm },
    .{ .ext = "loas", .fmt = .latm },
    .{ .ext = "ape", .fmt = .ape },
    .{ .ext = "wv", .fmt = .wv },
    .{ .ext = "shn", .fmt = .shn },
    .{ .ext = "tak", .fmt = .tak },
    .{ .ext = "dsf", .fmt = .dsd },
    .{ .ext = "dff", .fmt = .dsd },
    .{ .ext = "amr", .fmt = .amr },
    .{ .ext = "awb", .fmt = .amrwb },
    .{ .ext = "ac3", .fmt = .ac3 },
    .{ .ext = "ec3", .fmt = .ac3 },
    .{ .ext = "eac3", .fmt = .ac3 },
    .{ .ext = "mlp", .fmt = .mlp },
    .{ .ext = "thd", .fmt = .truehd },
    .{ .ext = "truehd", .fmt = .truehd },
    .{ .ext = "wma", .fmt = .wma },
    .{ .ext = "asf", .fmt = .wma },
    // DTS：core / DTS-HD 容器 / .dca 别名
    .{ .ext = "dts", .fmt = .dts },
    .{ .ext = "dtshd", .fmt = .dts },
    .{ .ext = "dca", .fmt = .dts },
    .{ .ext = "mka", .fmt = .mka },
    .{ .ext = "webm", .fmt = .mka },
    .{ .ext = "mpc", .fmt = .mpc },
    .{ .ext = "mpp", .fmt = .mpc },
    .{ .ext = "mp+", .fmt = .mpc },
    .{ .ext = "tta", .fmt = .tta },
};

/// 归一化扩展名：去前导点、转小写（ASCII）。
fn normalize(ext: []const u8, buf: []u8) []const u8 {
    var e = ext;
    if (e.len > 0 and e[0] == '.') e = e[1..];
    const n = @min(e.len, buf.len);
    for (e[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

/// 扩展名判定（大小写不敏感、可带/不带前导点）。
/// 命中表且对应格式已启用 → `.yes`；命中但格式未启用 → `.no`；未命中 → `.unknown`。
pub fn ofExt(ext: []const u8) Verdict {
    var buf: [16]u8 = undefined;
    const e = normalize(ext, &buf);
    if (e.len == 0) return .unknown;
    for (ext_format) |row| {
        if (row.ext.len == e.len and std.ascii.eqlIgnoreCase(row.ext, e)) {
            return if (probe.enabled(row.fmt)) .yes else .no;
        }
    }
    return .unknown;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "takeover: bitmap 与 ofFormat 逐位一致" {
    inline for (std.meta.fields(probe.Format)) |f| {
        const fmt: probe.Format = @enumFromInt(f.value);
        const bit = (bitmap >> @intCast(f.value)) & 1;
        try testing.expectEqual(@as(u64, if (ofFormat(fmt)) 1 else 0), bit);
    }
}

test "takeover: ofExt 命中/未命中/大小写" {
    try testing.expectEqual(Verdict.yes, ofExt(".flac"));
    try testing.expectEqual(Verdict.yes, ofExt("flac"));
    try testing.expectEqual(Verdict.yes, ofExt(".FLAC"));
    try testing.expectEqual(Verdict.yes, ofExt(".Wv"));
    try testing.expectEqual(Verdict.unknown, ofExt(".zzz"));
    try testing.expectEqual(Verdict.unknown, ofExt(""));
    try testing.expectEqual(Verdict.unknown, ofExt("."));
    try testing.expectEqual(Verdict.unknown, ofExt(".ogg"));
    // 与格式开关一致（.dts/.ac3 当前均启用 → yes）
    try testing.expectEqual(
        if (probe.enabled(.dts)) Verdict.yes else Verdict.no,
        ofExt(".dts"),
    );
    try testing.expectEqual(
        if (probe.enabled(.ac3)) Verdict.yes else Verdict.no,
        ofExt(".ac3"),
    );
}

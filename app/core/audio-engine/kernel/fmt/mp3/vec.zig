// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

pub const V4 = @Vector(4, f32);
pub const V8 = @Vector(8, f32);

pub inline fn load4(p: [*]const f32) V4 {
    return @bitCast(p[0..4].*);
}
pub inline fn store4(p: [*]f32, v: V4) void {
    p[0..4].* = @bitCast(v);
}

pub inline fn load8(p: [*]const f32) V8 {
    return @bitCast(p[0..8].*);
}
pub inline fn store8(p: [*]f32, v: V8) void {
    p[0..8].* = @bitCast(v);
}

/// 8 lane 反序：结果 lane k = 输入 lane (7-k)。
pub inline fn rev8(v: V8) V8 {
    return @shuffle(f32, v, v, [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 });
}

/// 4 lane 反序：结果 lane k = 输入 lane (3-k)。
pub inline fn rev4(v: V4) V4 {
    return @shuffle(f32, v, v, [4]i32{ 3, 2, 1, 0 });
}

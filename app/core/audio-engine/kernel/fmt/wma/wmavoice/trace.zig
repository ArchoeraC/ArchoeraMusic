// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 对拍插桩工具（env 门控）：WMAVOICE_TRACE=<路径> 时按
//! [u32 tag][u32 count][u32 is_double][payload] 记录与 reference C 侧
//! 插桩（wmavoice_traced.c）完全同格式的中间信号序列，供 python 对拍。

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, sz: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) i32;

var fp: ?*anyopaque = null;

pub fn init() void {
    if (fp != null) return;
    const p = getenv("WMAVOICE_TRACE") orelse return;
    fp = fopen(p, "wb");
}

pub fn enabled() bool {
    return fp != null;
}

fn rec(tag: u32, count: usize, is_double: bool, payload: []const u8) void {
    const f = fp orelse return;
    var hdr: [3]u32 = .{ tag, @intCast(count), @intFromBool(is_double) };
    _ = fwrite(std.mem.sliceAsBytes(hdr[0..]).ptr, 1, 12, f);
    _ = fwrite(payload.ptr, 1, payload.len, f);
}

pub fn f32s(tag: u32, xs: []const f32) void {
    rec(tag, xs.len, false, std.mem.sliceAsBytes(xs));
}

pub fn f64s(tag: u32, xs: []const f64) void {
    rec(tag, xs.len, true, std.mem.sliceAsBytes(xs));
}

pub fn i32s(tag: u32, xs: []const i32) void {
    rec(tag, xs.len, false, std.mem.sliceAsBytes(xs));
}

pub const lsp_tag: u32 = 101;
pub const lpcs_tag: u32 = 102;
pub const exc_tag: u32 = 103;
pub const synth_tag: u32 = 104;
pub const zero_tag: u32 = 105;
pub const kalman_tag: u32 = 106;
pub const kflag_tag: u32 = 107;
pub const resyn_tag: u32 = 108;
pub const wiener_tag: u32 = 109;
pub const agc_tag: u32 = 110;

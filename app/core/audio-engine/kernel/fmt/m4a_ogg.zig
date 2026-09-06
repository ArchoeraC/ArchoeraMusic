// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! M4A/MP4 Opus → Ogg 页合成辅助（fmt/m4a 专用，不改动 fmt/ogg）
//!
//! m4a 中 Opus 轨每 sample = 一个完整 Opus 包，容器不携带 granule；解码复用
//! fmt/opus（其 open 按 Ogg 流解析），因此需把逐包序列合成为合法 Ogg 流：
//!   页1  BOS = OpusHead（由 dOps 盒转换，LE）
//!   页2      = 空 OpusTags（RFC 7845 必需第二头包）
//!   其余    = 每包一页，granule 由 TOC 帧尺寸累计（fmt/mka 成功模式）
//! 单包页（无跨页，255 lacing 续段 + 页 CRC 回填），逻辑与 fmt/mka 的
//! writeOggPage 一致，仅粒度不同（每包一页 vs 批量）。

const std = @import("std");
const Error = @import("../error.zig").Error;
const ogg = @import("ogg.zig");

const Allocator = std.mem.Allocator;

/// 合成流的序列号（任意；解码端只按首音频流取包）
pub const serial: u32 = 0x2009_1101;

/// 追加单包 Ogg 页（每包一页，包长上限 255×255）
pub fn writeSinglePage(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    header_type: u8,
    page_seq: u32,
    granule: u64,
    payload: []const u8,
) Error!void {
    if (payload.len > 255 * 255) return error.Corrupt;
    var lacing = std.ArrayList(u8).empty;
    defer lacing.deinit(allocator);
    var rem = payload.len;
    while (rem >= 255) : (rem -= 255) try lacing.append(allocator, 255);
    if (rem > 0 or payload.len == 0 or payload.len % 255 == 0)
        try lacing.append(allocator, @intCast(rem));

    const start = out.items.len;
    try out.appendSlice(allocator, "OggS");
    try out.append(allocator, 0);
    try out.append(allocator, header_type);
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, granule, .little);
    try out.appendSlice(allocator, &b);
    std.mem.writeInt(u32, b[0..4], serial, .little);
    try out.appendSlice(allocator, b[0..4]);
    std.mem.writeInt(u32, b[0..4], page_seq, .little);
    try out.appendSlice(allocator, b[0..4]);
    try out.appendNTimes(allocator, 0, 4);
    try out.append(allocator, @intCast(lacing.items.len));
    try out.appendSlice(allocator, lacing.items);
    try out.appendSlice(allocator, payload);

    const page = out.items[start..];
    var crc: u32 = 0;
    crc = ogg.crcUpdateBytes(crc, page[0..22]);
    crc = ogg.crcUpdateBytes(crc, &[_]u8{ 0, 0, 0, 0 });
    crc = ogg.crcUpdateBytes(crc, page[26..]);
    std.mem.writeInt(u32, page[22..26], crc, .little);
}

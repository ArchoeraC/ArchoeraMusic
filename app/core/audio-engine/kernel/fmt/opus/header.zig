//! Opus 头部解析（OpusHead / OpusTags）
//!
//! RFC 7845 §5：`OpusHead` 19 字节 + 可选 channel mapping（mapping family ≠ 0）。
//! 参考重构对照 FFmpeg `libavformat/oggparseopus.c`（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。

const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const HEAD_MAGIC = "OpusHead";
pub const TAGS_MAGIC = "OpusTags";

/// OpusHead 解析结果
pub const Head = struct {
    /// 版本（当前为 1）
    version: u8,
    /// 声道数
    channels: u8,
    /// 起始 pre-skip（样本，48kHz 域）
    pre_skip: u16,
    /// 编码输入采样率（仅为元数据）
    input_sample_rate: u32,
    /// 输出增益（Q7.8 dB，带符号）
    output_gain: i16,
    /// channel mapping family（0 = mono/stereo 默认映射）
    mapping_family: u8,
    /// stream count（mapping family ≠ 0）
    stream_count: u8 = 0,
    /// coupled count
    coupled_count: u8 = 0,
    /// 声道 → 流/耦合映射
    mapping: [256]u8 = undefined,
};

/// 解析 OpusHead（须以 "OpusHead" 开头）。
pub fn parseHead(data: []const u8) Error!Head {
    if (data.len < 19) return error.Corrupt;
    if (!std.mem.eql(u8, data[0..8], HEAD_MAGIC)) return error.Corrupt;
    var h = Head{
        .version = data[8],
        .channels = data[9],
        .pre_skip = std.mem.readInt(u16, data[10..12], .little),
        .input_sample_rate = std.mem.readInt(u32, data[12..16], .little),
        .output_gain = std.mem.readInt(i16, data[16..18], .little),
        .mapping_family = data[18],
    };
    if (h.version != 1) return error.UnsupportedFormat;
    if (h.channels == 0) return error.Corrupt;
    if (h.mapping_family != 0) {
        if (data.len < 21) return error.Corrupt;
        h.stream_count = data[19];
        h.coupled_count = data[20];
        if (h.stream_count == 0) return error.Corrupt;
        if (data.len < 21 + h.channels) return error.Corrupt;
        @memcpy(h.mapping[0..h.channels], data[21 .. 21 + h.channels]);
    }
    return h;
}

/// 整轨时长（样本）：末页 granule - pre_skip（钳位 ≥ 0）
pub fn totalSamples(final_granule: i64, pre_skip: u16) u64 {
    const t = final_granule - @as(i64, pre_skip);
    if (t <= 0) return 0;
    return @intCast(t);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "opus head: OpusHead 解析（mono/stereo 默认映射）" {
    var data = [_]u8{0} ** 19;
    @memcpy(data[0..8], HEAD_MAGIC);
    data[8] = 1; // version
    data[9] = 2; // channels
    std.mem.writeInt(u16, data[10..12], 312, .little); // pre-skip
    std.mem.writeInt(u32, data[12..16], 48000, .little); // input sr
    std.mem.writeInt(i16, data[16..18], 0, .little); // gain
    data[18] = 0; // mapping family 0
    const h = try parseHead(&data);
    try testing.expectEqual(@as(u8, 2), h.channels);
    try testing.expectEqual(@as(u16, 312), h.pre_skip);
    try testing.expectEqual(@as(u8, 0), h.mapping_family);
    try testing.expectEqual(@as(u64, 0), totalSamples(312, 312));
    try testing.expectEqual(@as(u64, 1688), totalSamples(2000, 312));
}

test "opus head: 非法头" {
    // 版本字段非 1 → UnsupportedFormat
    var bad = [_]u8{0} ** 19;
    @memcpy(bad[0..8], HEAD_MAGIC);
    bad[8] = 2;
    try testing.expectError(error.UnsupportedFormat, parseHead(&bad));
    // 魔数不符 / 过短 → Corrupt
    try testing.expectError(error.Corrupt, parseHead("NoSuchHeadXXXX"));
    try testing.expectError(error.Corrupt, parseHead("OpusHead"));
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ALAC（Apple Lossless）帧解码器 —— 自研 Zig
//!
//! 定位（docs/audio-kernel-zig.md §9.8）：M4A 容器内的无损编解码；
//! 本模块为**纯帧函数**（每 m4a sample 一帧），容器解复用由 fmt/m4a.zig 承担。
//! 参考重构对照 FFmpeg libavcodec/alac.c（LGPL-2.1+）与
//! Apple 参考 alac.c（Apache-2.0，作对照不引入运行时）。
//!
//! 帧布局：
//!   element 循环（每 element 3 位类型：0 SCE / 1 CPE / 3 LFE / 7 END）→
//!   element 头（4 实例标签 + 12 保留 + has_size(1) + extra_bits(2)<<3 +
//!   is_compressed(1) + output_samples(32, has_size 时)）→
//!   压缩：decorr_shift(8) + decorr_left_weight(8) + 每声道
//!   [prediction_type(4) + lpc_quant(4) + rice_history_mult(3) + lpc_order(5)
//!   + lpc_coefs(16×order 有符号，逆序) + extra_bits 逐样本 + Rice 残差 +
//!   LPC 预测] → 立体声去相关 → extra_bits 附加。
//!
//! 算法组件（§9.8 分解）：
//!   - Rice 熵解码（自适应 history / 零块压缩 / sign_modifier 修正）；
//!   - 自适应线性预测 LPC（预热样本 + 系数逐轮自适应更新）；
//!   - 立体声去相关（左右声道按权重与移位互调）+ extra bits 附加；
//!   - 多声道 element 组合（SCE/CPE/LFE）按声道布局表映射。
//!
//! 输出契约：
//!   - sample_size ≤ 16 → 输出 16-bit（无移位，native 满幅）；
//!   - sample_size 20/24/32 → 输出 32-bit（左移 32-sample_size 位，
//!     补齐至 32 位整数域）；
//!   - 本模块输出**逐声道 int32**（解码位深原生值），交错打包与左移由
//!     fmt/m4a.zig 承担（与 flac 的 decode→emit 分工一致）。
//!
//! 健壮性（§13.3）：Config 各字段边界校验；帧内所有读取先验剩余位（越界 →
//! Corrupt）；output_samples 上界 = max_samples_per_frame；bps 越界（>32/<1）
//! 拒绝；element 声道数与布局越界拒绝；Rice 未完成 → Corrupt。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const BitReader = @import("bitreader.zig").BitReader;

/// ALAC magic cookie（extradata）总大小：整个 'alac' box（36 字节）
pub const ExtradataSize = 36;

/// ALACSpecificConfig（36 字节 magic cookie 的配置区，位于 size:'alac':version
/// 12 字节头之后）。字段名沿 QuickTime 命名，取值边界与参考解码器一致。
pub const Config = struct {
    max_samples_per_frame: u32,
    compatible_version: u8,
    sample_size: u8, // 16 / 20 / 24 / 32
    rice_history_mult: u8, // pb，默认 40
    rice_initial_history: u8, // mb，默认 10
    rice_limit: u8, // kb，默认 14
    channels: u8,
    max_run: u16,
    max_frame_bytes: u32,
    avg_bit_rate: u32,
    sample_rate: u32,
    /// 输出位深（16 / 32，见文件头输出契约）
    out_bps: u8,
    /// 输出左移位数（16 → 0；20/24/32 → 32-sample_size）
    out_shift: u5,

    /// 解析 36 字节 magic cookie（m4a stsd 'alac' box 全量）。
    /// 布局：size(4) 'alac'(4) version(4) 后接 24 字节配置区
    /// （frameLength u32 / compatibleVersion u8 / bitDepth u8 / historyMult u8 /
    /// initialHistory u8 / riceLimit u8 / numChannels u8 / maxRun u16 /
    /// maxFrameBytes u32 / avgBitRate u32 / sampleRate u32）。
    pub fn parse(extradata: []const u8) Error!Config {
        if (extradata.len < ExtradataSize) return error.Corrupt;
        var c: Config = undefined;
        c.max_samples_per_frame = readInt(u32, extradata[12..16], .big);
        // 上限 65536 为防御性收紧（参考解码器上限 2^24）；真实编码器用 4096
        if (c.max_samples_per_frame == 0 or c.max_samples_per_frame > 65536) return error.Corrupt;
        c.compatible_version = extradata[16];
        c.sample_size = extradata[17];
        c.rice_history_mult = extradata[18];
        c.rice_initial_history = extradata[19];
        c.rice_limit = extradata[20];
        c.channels = extradata[21];
        if (c.channels < 1 or c.channels > 8) return error.Corrupt;
        c.max_run = readInt(u16, extradata[22..24], .big);
        c.max_frame_bytes = readInt(u32, extradata[24..28], .big);
        c.avg_bit_rate = readInt(u32, extradata[28..32], .big);
        c.sample_rate = readInt(u32, extradata[32..36], .big);
        if (c.sample_rate == 0) return error.Corrupt;
        switch (c.sample_size) {
            16, 20, 24, 32 => {},
            else => return error.Corrupt,
        }
        c.out_bps = if (c.sample_size <= 16) 16 else 32;
        c.out_shift = @intCast(if (c.sample_size <= 16) 0 else 32 - c.sample_size);
        return c;
    }
};

/// 每帧解码的临时缓冲（调用方预分配，尺寸 = max_samples_per_frame）
pub const Scratch = struct {
    /// Rice 残差缓冲（element 内声道 0/1）
    predict_error: [2][]i32,
    /// extra bits 缓冲（sample_size 超出主位深的高位）
    extra_bits: [2][]i32,
};

/// 声道布局偏移表（格式定义）：[声道数-1][element 序号] → 全局声道号；
/// 0 为填充位（多声道元素序列中的占位，不映射真实声道）
const channel_layout_offsets = [8][8]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 3, 0, 0, 0, 0 },
    .{ 2, 0, 1, 3, 4, 0, 0, 0 },
    .{ 2, 0, 1, 4, 5, 3, 0, 0 },
    .{ 2, 0, 1, 4, 5, 6, 3, 0 },
    .{ 2, 6, 7, 0, 1, 4, 5, 3 },
};

/// element 类型枚举（格式定义）：7 = 帧结束标记
const TYPE_END: u32 = 7;

/// 解码一帧（一个 m4a sample）。`out[ch]` 为各全局声道缓冲（容量 ≥
/// max_samples_per_frame），`scratch` 为临时缓冲。返回本帧样本数。
pub fn decodeFrame(
    cfg: *const Config,
    frame: []const u8,
    out: [][]i32,
    scratch: *const Scratch,
) Error!u32 {
    var br = BitReader.init(frame);
    var ch: usize = 0;
    var nb: u32 = 0;
    var got_end = false;
    while (br.remainingBits() >= 3) {
        const element = try br.readBits(3);
        if (element == TYPE_END) {
            got_end = true;
            break;
        }
        // 仅支持 SCE(0) / CPE(1) / LFE(3)；CCE(2)/DSE(4)/PCE(5)/FIL(6) 未使用
        if (element > 1 and element != 3) return error.Corrupt;
        const channels: usize = if (element == 1) 2 else 1;
        // 先验 ch 上界（防元素个数超过声明声道数时越界索引布局表），再查布局偏移
        if (ch + channels > cfg.channels) return error.Corrupt;
        const off: usize = channel_layout_offsets[cfg.channels - 1][ch];
        if (off + channels > cfg.channels) return error.Corrupt;
        const n = try decodeElement(cfg, &br, out, off, channels, scratch);
        if (nb != 0 and n != nb) return error.Corrupt; // 同帧多 element 样本数一致
        nb = n;
        ch += channels;
    }
    if (!got_end) return error.Corrupt;
    if (nb == 0) return error.Corrupt;
    // 元素必须恰好覆盖全部声明声道；不足时部分声道未写入，残留上次帧数据
    if (ch != cfg.channels) return error.Corrupt;
    return nb;
}

/// 解码一个 element（SCE/CPE/LFE）。`elem_ch` 为全局声道起点（布局偏移）。
/// 返回该 element 的样本数。
fn decodeElement(
    cfg: *const Config,
    br: *BitReader,
    out: [][]i32,
    elem_ch: usize,
    channels: usize,
    scratch: *const Scratch,
) Error!u32 {
    _ = try br.skipBits(4); // 元素实例标签
    _ = try br.skipBits(12); // 保留头位

    const has_size = try br.readBits(1);
    const extra_bits: u8 = @intCast((try br.readBits(2)) << 3); // 0/8/16/24
    const bps: i32 = @as(i32, cfg.sample_size) - @as(i32, extra_bits) + @as(i32, @intCast(channels)) - 1;
    if (bps > 32 or bps < 1) return error.Corrupt;
    const is_compressed = (try br.readBits(1)) == 0;

    const output_samples: u32 = if (has_size == 1)
        try br.readBits(32)
    else
        cfg.max_samples_per_frame;
    if (output_samples == 0 or output_samples > cfg.max_samples_per_frame) return error.Corrupt;
    const nb = output_samples;

    var decorr_shift: u8 = 0;
    var decorr_left_weight: u8 = 0;

    if (is_compressed) {
        var lpc_coefs: [2][32]i16 = undefined;
        var lpc_order: [2]u8 = undefined;
        var prediction_type: [2]u8 = undefined;
        var lpc_quant: [2]u8 = undefined;
        var rice_hm: [2]u8 = undefined;

        // rice_limit=0 时无可用熵参数，压缩帧无法解码
        if (cfg.rice_limit == 0) return error.Corrupt;
        decorr_shift = @intCast(try br.readBits(8));
        decorr_left_weight = @intCast(try br.readBits(8));
        if (channels == 2 and decorr_left_weight != 0 and decorr_shift > 31) return error.Corrupt;

        // 每声道预测参数 + LPC 系数（逆序：lpc_order-1 .. 0）
        for (0..channels) |c| {
            prediction_type[c] = @intCast(try br.readBits(4));
            lpc_quant[c] = @intCast(try br.readBits(4));
            rice_hm[c] = @intCast(try br.readBits(3));
            lpc_order[c] = @intCast(try br.readBits(5));
            if (lpc_order[c] >= cfg.max_samples_per_frame or lpc_quant[c] == 0) return error.Corrupt;
            var i: usize = lpc_order[c];
            while (i > 0) {
                i -= 1;
                lpc_coefs[c][i] = @intCast(try br.readSigned(16));
            }
        }

        // extra bits（主位深之外的附加位，逐样本逐声道）
        if (extra_bits != 0) {
            if (br.remainingBits() < @as(u64, nb) * channels * extra_bits) return error.Corrupt;
            for (0..nb) |si| {
                for (0..channels) |c| {
                    scratch.extra_bits[c][si] = @bitCast(try br.readBits(@intCast(extra_bits)));
                }
            }
        }

        for (0..channels) |c| {
            const mult: u8 = @intCast(@as(u32, rice_hm[c]) * cfg.rice_history_mult / 4);
            const err = scratch.predict_error[c];
            try riceDecompress(br, cfg, err, nb, bps, mult);

            if (prediction_type[c] == 15) {
                // 特殊类型 15：先跑一次 order=31 的简单一阶预测（写回残差缓冲）
                lpcPrediction(err, err, nb, bps, lpc_coefs[c][0..0], 31, 0);
            }
            lpcPrediction(err, out[elem_ch + c], nb, bps, lpc_coefs[c][0..lpc_order[c]], lpc_order[c], lpc_quant[c]);
        }
    } else {
        // 未压缩：样本按声明的位深直接有符号读取
        if (br.remainingBits() < @as(u64, nb) * channels * cfg.sample_size) return error.Corrupt;
        for (0..nb) |si| {
            for (0..channels) |c| {
                out[elem_ch + c][si] = try br.readSigned(@intCast(cfg.sample_size));
            }
        }
        // 未压缩帧不携带 extra bits / 去相关参数，跳过后续整形步骤
    }

    // 立体声去相关：b 按权重右移后从 a 中减去，再回加（仅压缩帧可能带权重）
    if (channels == 2 and decorr_left_weight != 0) {
        const a_buf = out[elem_ch];
        const b_buf = out[elem_ch + 1];
        for (0..nb) |si| {
            const a: u32 = @bitCast(a_buf[si]);
            const b: u32 = @bitCast(b_buf[si]);
            // a -= (int)(b * weight) >> shift（b*weight 为 u32 模乘后按 int 算术右移）
            const shifted: i32 = @as(i32, @bitCast(b *% @as(u32, decorr_left_weight))) >> @intCast(decorr_shift);
            const new_a: u32 = a -% @as(u32, @bitCast(shifted));
            const new_b: u32 = new_a +% b;
            a_buf[si] = @bitCast(new_b);
            b_buf[si] = @bitCast(new_a);
        }
    }

    // 高位附加：去相关完成后将 extra bits 并入各样本低端
    if (extra_bits != 0) {
        for (0..channels) |c| {
            const o = out[elem_ch + c];
            const eb = scratch.extra_bits[c];
            for (0..nb) |si| {
                o[si] = @bitCast((@as(u32, @bitCast(o[si])) << @intCast(extra_bits)) | @as(u32, @bitCast(eb[si])));
            }
        }
    }

    return nb;
}

/// Rice 残差解码：自适应 history / 零块压缩 / sign_modifier 修正。
/// `out` 为残差缓冲（int32 有符号值）。
fn riceDecompress(
    br: *BitReader,
    cfg: *const Config,
    out: []i32,
    nb: u32,
    bps: i32,
    mult: u8,
) Error!void {
    var history: u32 = cfg.rice_initial_history;
    var sign_modifier: u32 = 0;
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        if (br.remainingBits() <= 0) return error.Corrupt;

        // rice 参数自适应（k = log2((history>>9)+3)，上限 rice_limit）
        var k: u6 = @intCast(@min(log2floor((history >> 9) + 3), cfg.rice_limit));
        var x = try decodeScalar(br, k, bps);
        x += sign_modifier;
        sign_modifier = 0;
        // zigzag → 有符号：(x>>1) ^ -(x&1)（u32 模减，避免安全模式溢出）
        out[i] = @bitCast((x >> 1) ^ (@as(u32, 0) -% (x & 1)));

        // history 更新（饱和 0xffff）
        if (x > 0xffff) {
            history = 0xffff;
        } else {
            const m: u32 = mult;
            history = history +% (x *% m) -% ((history *% m) >> 9);
        }

        // 零块压缩：history < 128 时后续块可能整块为 0
        if (history < 128 and i + 1 < nb) {
            k = @intCast(@min(
                7 -% log2floor(history) + ((history + 16) >> 6),
                cfg.rice_limit,
            ));
            var block_size = try decodeScalar(br, k, 16);
            if (block_size > 0) {
                const remaining: u32 = @intCast(nb - i);
                if (block_size >= remaining) block_size = remaining - 1;
                @memset(out[i + 1 .. i + 1 + block_size], 0);
                i += block_size;
            }
            if (block_size <= 0xffff) sign_modifier = 1;
            history = 0;
        }
    }
}

/// Rice 标量解码：unary 前缀 + 可选的 k 位修正 / 阈值外直读
fn decodeScalar(br: *BitReader, k: u6, bps: i32) Error!u32 {
    // unary 前缀：0 终止、上限 9；9 位全 1 视为超出阈值 → 走替代路径
    var x = try br.readUnary0(9);
    if (x > 8) {
        // 阈值外路径：直接读 bps 位原值
        x = try br.readBits(@intCast(bps));
    } else if (k != 1) {
        // 常规路径：x 映射为 x·(2^k−1)，再按 k 位窗值叠加修正；
        // 窗值 ≤1 时少读 1 位（格式历史行为）
        const extrabits = try br.showBits(k);
        x = (x << @intCast(k)) - x;
        if (extrabits > 1) {
            x += extrabits - 1;
            try br.skipBits(k);
        } else {
            try br.skipBits(k - 1);
        }
    }
    return x;
}

/// 自适应线性预测：残差流 → 重建样本流（预测项 + 残差，按位深截断回环）
/// `in` 与 `out` 允许为同一缓冲（type 15 首遍写回残差）。
fn lpcPrediction(
    in: []const i32,
    out: []i32,
    nb: u32,
    bps: i32,
    coefs: []i16,
    order: usize,
    quant: u8,
) void {
    out[0] = in[0]; // 无历史样本可用，首样本即为重建值
    if (nb <= 1) return;

    if (order == 0) {
        @memcpy(out[1..nb], in[1..nb]);
        return;
    }
    if (order == 31) {
        // order=31 退化为无系数一阶递推（type 15 首遍专用）
        for (1..nb) |i| out[i] = signExtend(out[i - 1] + in[i], bps);
        return;
    }

    // 预热：前 order 个样本逐级用上一重建值递推，建立初始上下文
    var i: usize = 1;
    while (i <= order and i < nb) : (i += 1) {
        out[i] = signExtend(out[i - 1] + in[i], bps);
    }

    // 主循环：以最近 order+1 个重建样本为窗（窗首为 d），系数线性组合
    // 后量化舍入，再叠加残差；窗口端点始终落在已重建样本内
    while (i < nb) : (i += 1) {
        const d: u32 = @bitCast(out[i - order - 1]);
        var val: u32 = 0;
        for (0..order) |j| {
            // (pred[j] - d) 为 u32 模减，乘 i16 系数（u32 模乘），累加回 val
            val +%= (@as(u32, @bitCast(out[i - order + j])) -% d) *% @as(u32, @bitCast(@as(i32, coefs[j])));
        }
        // (val + (1 << (quant-1))) >> quant（算术右移，val 视为 int32）
        const rounded: i32 = @intCast((@as(i64, @as(i32, @bitCast(val))) + (@as(i64, 1) << @intCast(quant - 1))) >> @intCast(quant));
        var val_signed: i32 = @bitCast(@as(u32, @bitCast(rounded)) +% d); // + d（u32 模加）
        // + error_val（u32 模加）
        const error_val: u32 = @bitCast(in[i]);
        val_signed = @bitCast(@as(u32, @bitCast(val_signed)) +% error_val);
        out[i] = signExtend(val_signed, bps);

        // 系数自适应：按残差符号与预测偏差逐级修正（更新量与编码端
        // 定点语义严格一致，保证无损可逆）
        var ev: i32 = @bitCast(error_val);
        var ev_u: u32 = error_val;
        const error_sign: i32 = if (ev > 0) 1 else if (ev < 0) -1 else 0;
        if (error_sign != 0) {
            var j: usize = 0;
            while (j < order) : (j += 1) {
                // 终止判据按无符号模乘后符号解释（与编码端定点语义一致）
                const prod: i32 = @bitCast(@as(u32, @bitCast(ev_u)) *% @as(u32, @bitCast(error_sign)));
                if (!(prod > 0)) break;
                var v: i32 = @as(i32, @bitCast(d)) -% @as(i32, @bitCast(out[i - order + j]));
                const sign: i32 = (if (v > 0) @as(i32, 1) else if (v < 0) @as(i32, -1) else @as(i32, 0)) * error_sign;
                coefs[j] -%= @as(i16, @intCast(sign));
                v *%= sign; // sign ∈ {±1}，模乘即原值带符号
                // error_val -= (v >> quant) * (j+1)（u32 模运算）
                ev_u = ev_u -% @as(u32, @bitCast(v >> @intCast(quant))) *% @as(u32, @intCast(j + 1));
                ev = @bitCast(ev_u);
            }
        }
    }
}

/// 符号扩展：先左移丢弃高 (32-bps) 位再算术右移回，等价于按 bps 位宽解释有符号
fn signExtend(v: i32, bps: i32) i32 {
    const shift: u5 = @intCast(32 - bps);
    return @as(i32, @bitCast(@as(u32, @bitCast(v)) << shift)) >> shift;
}

/// floor(log2(x))；约定 x=0 → 0（与编码端约定一致）
fn log2floor(x: u32) u8 {
    if (x == 0) return 0;
    return @intCast(31 - @clz(x));
}

fn readInt(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 构造 36 字节 magic cookie
fn makeCookie(
    max_frame: u32,
    sample_size: u8,
    channels: u8,
    rate: u32,
    pb: u8,
    mb: u8,
    kb: u8,
) [36]u8 {
    var b = [_]u8{0} ** 36;
    std.mem.writeInt(u32, b[0..4], 36, .big);
    @memcpy(b[4..8], "alac");
    std.mem.writeInt(u32, b[8..12], 0, .big); // version
    std.mem.writeInt(u32, b[12..16], max_frame, .big);
    b[16] = 0; // compatibleVersion
    b[17] = sample_size;
    b[18] = pb;
    b[19] = mb;
    b[20] = kb;
    b[21] = channels;
    std.mem.writeInt(u16, b[22..24], 255, .big); // maxRun
    std.mem.writeInt(u32, b[24..28], 0, .big); // maxFrameBytes
    std.mem.writeInt(u32, b[28..32], 0, .big); // avgBitRate
    std.mem.writeInt(u32, b[32..36], rate, .big);
    return b;
}

/// 位追加器（测试编码用）
const TestBits = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_pos: usize = 0,

    fn init() TestBits {
        return .{};
    }

    fn deinit(self: *TestBits) void {
        self.bytes.deinit(testing.allocator);
    }

    fn appendBits(self: *TestBits, value: u64, n: usize) !void {
        var need = n;
        while (need > 0) {
            if (self.bit_pos % 8 == 0) try self.bytes.append(testing.allocator, 0);
            const bit_in_byte: usize = self.bit_pos % 8;
            const take = @min(need, 8 - bit_in_byte);
            // 取 value 位偏移 [need-take, need) 的 take 位（高位优先逐位提取，
            // 支持 n > 64 的 unary 编码；value 仅 u64，超出位为 0）
            var chunk: u8 = 0;
            for (0..take) |j| {
                // MSB-first：先写 value 最高位（bit_idx = need-1），后写最低位
                const bit_idx = need - 1 - j;
                const bit: u8 = if (bit_idx >= 64)
                    0
                else
                    @intCast((value >> @intCast(bit_idx)) & 1);
                chunk = (chunk << 1) | bit;
            }
            const byte_idx = self.bit_pos / 8;
            const shift = 8 - bit_in_byte - take;
            self.bytes.items[byte_idx] |= chunk << @intCast(shift);
            self.bit_pos += take;
            need -= take;
        }
    }

    fn toOwnedSlice(self: *TestBits) ![]u8 {
        // 对齐到字节边界（高位补 0 已就位）
        if (self.bit_pos % 8 != 0) self.bit_pos += 8 - (self.bit_pos % 8);
        return self.bytes.toOwnedSlice(testing.allocator);
    }
};

test "alac config: 标准 cookie 解析" {
    const cookie = makeCookie(4096, 16, 2, 44100, 40, 10, 14);
    const cfg = try Config.parse(&cookie);
    try testing.expectEqual(@as(u32, 4096), cfg.max_samples_per_frame);
    try testing.expectEqual(@as(u8, 16), cfg.sample_size);
    try testing.expectEqual(@as(u8, 40), cfg.rice_history_mult);
    try testing.expectEqual(@as(u8, 10), cfg.rice_initial_history);
    try testing.expectEqual(@as(u8, 14), cfg.rice_limit);
    try testing.expectEqual(@as(u8, 2), cfg.channels);
    try testing.expectEqual(@as(u32, 44100), cfg.sample_rate);
    try testing.expectEqual(@as(u8, 16), cfg.out_bps);
    try testing.expectEqual(@as(u5, 0), cfg.out_shift);
}

test "alac config: 24-bit → 32bit 输出左移 8" {
    const cookie = makeCookie(4096, 24, 2, 96000, 40, 10, 14);
    const cfg = try Config.parse(&cookie);
    try testing.expectEqual(@as(u8, 32), cfg.out_bps);
    try testing.expectEqual(@as(u5, 8), cfg.out_shift);
}

test "alac config: 非法字段 → Corrupt" {
    // 过短
    var short = [_]u8{0} ** 10;
    try testing.expectError(error.Corrupt, Config.parse(&short));
    // max_samples_per_frame = 0
    var c0 = makeCookie(0, 16, 1, 44100, 40, 10, 14);
    try testing.expectError(error.Corrupt, Config.parse(&c0));
    // 位深非法
    var c1 = makeCookie(4096, 18, 1, 44100, 40, 10, 14);
    try testing.expectError(error.Corrupt, Config.parse(&c1));
    // 声道数非法
    var c2 = makeCookie(4096, 16, 0, 44100, 40, 10, 14);
    try testing.expectError(error.Corrupt, Config.parse(&c2));
    var c3 = makeCookie(4096, 16, 9, 44100, 40, 10, 14);
    try testing.expectError(error.Corrupt, Config.parse(&c3));
}

/// 解码辅助：分配缓冲并 decodeFrame
fn decodeTestFrame(
    cfg: *const Config,
    frame: []const u8,
    expected_nb: usize,
) ![]i32 {
    const max = cfg.max_samples_per_frame;
    var decoded_buf = try testing.allocator.alloc(i32, max * cfg.channels);
    errdefer testing.allocator.free(decoded_buf);
    var out: [8][]i32 = undefined;
    for (0..cfg.channels) |c| out[c] = decoded_buf[c * max ..][0..max];
    var scratch_buf = try testing.allocator.alloc(i32, 4 * max);
    defer testing.allocator.free(scratch_buf);
    const scratch = Scratch{
        .predict_error = .{ scratch_buf[0..max], scratch_buf[max .. 2 * max] },
        .extra_bits = .{ scratch_buf[2 * max ..][0..max], scratch_buf[3 * max ..][0..max] },
    };
    const n = try decodeFrame(cfg, frame, out[0..cfg.channels], &scratch);
    try testing.expectEqual(@as(u32, @intCast(expected_nb)), n);
    return decoded_buf;
}

test "alac 帧: 未压缩单声道 16-bit 端到端" {
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);

    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 3); // element = SCE
    try w.appendBits(0, 4); // instance tag
    try w.appendBits(0, 12); // reserved
    try w.appendBits(1, 1); // has_size
    try w.appendBits(0, 2); // extra_bits = 0
    try w.appendBits(1, 1); // is_compressed = 0（未压缩）
    try w.appendBits(4, 32); // output_samples = 4
    try w.appendBits(100, 16); // 100 → 16bit
    try w.appendBits(@as(u64, @as(u16, @bitCast(@as(i16, -200)))), 16);
    try w.appendBits(0x0000, 16); // 0
    try w.appendBits(0x1234, 16); // 4660
    try w.appendBits(7, 3); // END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const buf = try decodeTestFrame(&cfg, frame, 4);
    defer testing.allocator.free(buf);
    const expect = [_]i32{ 100, -200, 0, 4660 };
    try testing.expectEqualSlices(i32, &expect, buf[0..4]);
}

test "alac 帧: 未压缩立体声 16-bit（交错 → 逐声道分离）" {
    const cookie = makeCookie(4096, 16, 2, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);

    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(1, 3); // element = CPE
    try w.appendBits(0, 4);
    try w.appendBits(0, 12);
    try w.appendBits(1, 1); // has_size
    try w.appendBits(0, 2);
    try w.appendBits(1, 1); // 未压缩
    try w.appendBits(3, 32); // 3 samples
    // 交错 L R L R L R
    try w.appendBits(1, 16);
    try w.appendBits(2, 16);
    try w.appendBits(3, 16);
    try w.appendBits(4, 16);
    try w.appendBits(5, 16);
    try w.appendBits(6, 16);
    try w.appendBits(7, 3); // END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const max = cfg.max_samples_per_frame;
    const buf = try decodeTestFrame(&cfg, frame, 3);
    defer testing.allocator.free(buf);
    try testing.expectEqualSlices(i32, &.{ 1, 3, 5 }, buf[0..3]); // L
    try testing.expectEqualSlices(i32, &.{ 2, 4, 6 }, buf[max .. max + 3]); // R
}

test "alac 帧: 压缩单声道 16-bit（Rice + LPC order 0 + 零块 + sign_modifier）" {
    // 编码约定（对照 decode_scalar 的 escape 路径，确定性构造）：
    //   mult = 0（rice_hm=0）→ history 恒小，每样本后走零块分支；
    //   残差恒为 C=5000 → zigzag x = 10000；因 unary 上限 9，x≥9 一律编码为
    //   "9 个 1 + 16 位原值"（escape）；零块 block_size=0 同样用 escape 编码，
    //   规避 decode_scalar 中 k-1/k 的 quirks 分支。
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);

    const nb: usize = 4;
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 3); // SCE
    try w.appendBits(0, 4);
    try w.appendBits(0, 12);
    try w.appendBits(1, 1); // has_size
    try w.appendBits(0, 2); // extra_bits = 0
    try w.appendBits(0, 1); // is_compressed = 1（压缩）
    try w.appendBits(nb, 32); // output_samples
    try w.appendBits(0, 8); // decorr_shift
    try w.appendBits(0, 8); // decorr_left_weight
    try w.appendBits(0, 4); // prediction_type = 0
    try w.appendBits(1, 4); // lpc_quant = 1（非零校验）
    try w.appendBits(0, 3); // rice_history_mult = 0 → mult 0
    try w.appendBits(0, 5); // lpc_order = 0
    // 每样本：残差 scalar（escape: 9 个 1 + 16 位）；其后零块 scalar（同 escape，值 0）
    for (0..nb) |si| {
        const x: u32 = if (si == 0) 10000 else 9999; // 首样本 5000→10000；其后 +sign_modifier
        try w.appendBits((@as(u64, 1) << 9) - 1, 9); // 9 个 1 → escape 路径
        try w.appendBits(x, 16);
        if (si + 1 < nb) {
            try w.appendBits((@as(u64, 1) << 9) - 1, 9); // block_size = 0（escape）
            try w.appendBits(0, 16);
        }
    }
    try w.appendBits(7, 3); // END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const buf = try decodeTestFrame(&cfg, frame, nb);
    defer testing.allocator.free(buf);
    const expect = [_]i32{ 5000, 5000, 5000, 5000 };
    try testing.expectEqualSlices(i32, &expect, buf[0..nb]);
}

test "alac 帧: 缺 END → Corrupt" {
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 3); // SCE
    try w.appendBits(0, 4);
    try w.appendBits(0, 12);
    try w.appendBits(1, 1);
    try w.appendBits(0, 2);
    try w.appendBits(1, 1);
    try w.appendBits(1, 32); // 1 sample
    try w.appendBits(0, 16); // sample
    // 无 END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const max = cfg.max_samples_per_frame;
    const decoded_buf = try testing.allocator.alloc(i32, max);
    defer testing.allocator.free(decoded_buf);
    var scratch_buf = try testing.allocator.alloc(i32, 4 * max);
    defer testing.allocator.free(scratch_buf);
    const scratch = Scratch{
        .predict_error = .{ scratch_buf[0..max], scratch_buf[max .. 2 * max] },
        .extra_bits = .{ scratch_buf[2 * max ..][0..max], scratch_buf[3 * max ..][0..max] },
    };
    var out: [1][]i32 = .{decoded_buf};
    try testing.expectError(error.Corrupt, decodeFrame(&cfg, frame, &out, &scratch));
}

test "alac 帧: 元素未覆盖全部声道 → Corrupt" {
    // cfg 声明 2 声道，但帧内只有 1 个 SCE（单声道）→ 解码后声道不足 → Corrupt
    const cookie = makeCookie(4096, 16, 2, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 3); // SCE
    try w.appendBits(0, 4);
    try w.appendBits(0, 12);
    try w.appendBits(1, 1); // has_size
    try w.appendBits(0, 2);
    try w.appendBits(1, 1); // 未压缩
    try w.appendBits(2, 32); // 2 samples
    try w.appendBits(1, 16);
    try w.appendBits(2, 16);
    try w.appendBits(7, 3); // END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const max = cfg.max_samples_per_frame;
    const decoded_buf = try testing.allocator.alloc(i32, max * 2);
    defer testing.allocator.free(decoded_buf);
    var out: [2][]i32 = .{ decoded_buf[0..max], decoded_buf[max..][0..max] };
    var scratch_buf = try testing.allocator.alloc(i32, 4 * max);
    defer testing.allocator.free(scratch_buf);
    const scratch = Scratch{
        .predict_error = .{ scratch_buf[0..max], scratch_buf[max .. 2 * max] },
        .extra_bits = .{ scratch_buf[2 * max ..][0..max], scratch_buf[3 * max ..][0..max] },
    };
    try testing.expectError(error.Corrupt, decodeFrame(&cfg, frame, &out, &scratch));
}

test "alac 帧: 元素数超过声明声道 → Corrupt（越界防护）" {
    // 2 声道配置但帧内含 3 个 SCE：第 3 个 SCE 使 ch 越界 → 先验上界拦截
    const cookie = makeCookie(4096, 16, 2, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);
    var w = TestBits.init();
    defer w.deinit();
    for (0..3) |_| {
        try w.appendBits(0, 3); // SCE
        try w.appendBits(0, 4);
        try w.appendBits(0, 12);
        try w.appendBits(1, 1); // has_size
        try w.appendBits(0, 2);
        try w.appendBits(1, 1); // 未压缩
        try w.appendBits(1, 32); // 1 sample
        try w.appendBits(0, 16);
    }
    try w.appendBits(7, 3); // END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const max = cfg.max_samples_per_frame;
    const decoded_buf = try testing.allocator.alloc(i32, max * 2);
    defer testing.allocator.free(decoded_buf);
    var out: [2][]i32 = .{ decoded_buf[0..max], decoded_buf[max..][0..max] };
    var scratch_buf = try testing.allocator.alloc(i32, 4 * max);
    defer testing.allocator.free(scratch_buf);
    const scratch = Scratch{
        .predict_error = .{ scratch_buf[0..max], scratch_buf[max .. 2 * max] },
        .extra_bits = .{ scratch_buf[2 * max ..][0..max], scratch_buf[3 * max ..][0..max] },
    };
    try testing.expectError(error.Corrupt, decodeFrame(&cfg, frame, &out, &scratch));
}

test "alac 帧: output_samples 超限 → Corrupt" {
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    var cfg = try Config.parse(&cookie);
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 3); // SCE
    try w.appendBits(0, 4);
    try w.appendBits(0, 12);
    try w.appendBits(1, 1);
    try w.appendBits(0, 2);
    try w.appendBits(1, 1);
    try w.appendBits(5000, 32); // > max_samples_per_frame
    try w.appendBits(0, 16);
    try w.appendBits(7, 3); // END
    const frame = try w.toOwnedSlice();
    defer testing.allocator.free(frame);

    const max = cfg.max_samples_per_frame;
    const decoded_buf = try testing.allocator.alloc(i32, max);
    defer testing.allocator.free(decoded_buf);
    var scratch_buf = try testing.allocator.alloc(i32, 4 * max);
    defer testing.allocator.free(scratch_buf);
    const scratch = Scratch{
        .predict_error = .{ scratch_buf[0..max], scratch_buf[max .. 2 * max] },
        .extra_bits = .{ scratch_buf[2 * max ..][0..max], scratch_buf[3 * max ..][0..max] },
    };
    var out: [1][]i32 = .{decoded_buf};
    try testing.expectError(error.Corrupt, decodeFrame(&cfg, frame, &out, &scratch));
}

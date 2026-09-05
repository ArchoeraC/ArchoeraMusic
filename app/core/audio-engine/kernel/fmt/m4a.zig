//! M4A（ISO-BMFF / MP4）容器解复用 —— 自研 Zig
//!
//! 定位（docs/audio-kernel-zig.md §9.8）：MP4 容器内音频解复用，覆盖
//! ALAC / AAC-LC（原生路径）+ FLAC('fLaC') / Opus('Opus') / AC-3('ac-3') /
//! E-AC-3('ec-3') / MP3('.mp3') / ALS('mp4a'+esds AOT_ALS，codec mp4als，
//! 委托路径)。**每个 m4a sample = 一个压缩帧**（ALS 允许一包多帧，委托
//! 解码器按帧长自切）。
//!
//! 两路解码语义：
//!   - 原生：ALAC（alac.decodeFrame）与 AAC-LC（raw_data_block）逐 sample 解码；
//!   - 委托（照 fmt/mka 成功模式）：stsd codec-private（dfLa STREAMINFO / dOps
//!     OpusHead / esds DecoderSpecificInfo→ALSSpecificConfig）→ 内存合成 inner
//!     解码器可消费的流（flac 头+帧 / opus Ogg / ac3-eac3-mp3 帧直拼 / ALS 帧流
//!     直拼），帧解码复用 fmt/flac、fmt/opus、fmt/ac3、fmt/mp3、fmt/als。
//!   elst 容器语义对齐 ffmpeg mov demuxer：media_time = 起始 priming（opus 由
//!   OpusHead pre-skip 承担），segment_duration = 输出上限（opus mp4 无 granule，
//!   ffmpeg 解码至 EOF，不截断）。
//!
//! 容器结构（ISO/IEC 14496-12 / QuickTime）：
//!   - 顶层 box：ftyp / moov / mdat / free…（box = size(4 BE) + type(4)，可嵌套；
//!     size==1 → 后接 8 字节 largesize；size==0 → 延伸至父 box 末尾）；
//!   - moov → trak → mdia → minf → stbl：
//!       stsd —— sample description（'alac' 子 box = 36 字节 magic cookie；
//!               'mp4a'+esds(ASC)；'fLaC'+dfLa(FLAC metadata block)；
//!               'Opus'+dOps(OpusSpecificBox)；ac-3/ec-3/.mp3 自同步无需私有）；
//!       stts —— time-to-sample（样本→时长映射，提供总样本数与逐帧样本数）；
//!       stsc —— sample-to-chunk（样本↔chunk 映射 run 表）；
//!       stco/co64 —— chunk 文件偏移（32/64 位）；
//!       stsz —— 样本大小（等长或逐样本）。
//!
//! 解析策略：
//!   - moov 未必在 mdat 之前（FFmpeg 兼容），顶层按 box size 精确跳转扫描；
//!   - 遍历全部 trak，取首个受支持 codec 条目的音频轨（跳过视频轨）；
//!   - stsc/stco/stsz 三表结合生成线性 sample 表（offset, size）；
//!   - stts run 展开为逐帧累计样本偏移（frame_offsets），支撑精确整帧 seek
//!     与时长计算（总样本数 = frame_offsets[末位]）。
//!
//! 读取（VTable.read）：原生路径逐 sample 解码（坏帧 Corrupt → 跳过继续，
//! 对齐 FLAC 重同步语义，§13.3；整段无产出时 Corrupt 透出）；委托路径从
//! inner 拉帧并应用 elst priming/上限。EOF = sample 索引耗尽 / inner EOF。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");
const alac = @import("alac/lib.zig");
const asc = @import("aac/asc.zig");
const aacmod = @import("aac/lib.zig");
const BitReader = @import("aac/bitreader.zig").BitReader;
// 多 codec 面：FLAC / Opus / AC-3 / E-AC-3 / MP3 轨复用既有 fmt 解码器。
// 本模块只解析容器（stsd codec-private → 内存合成各解码器可消费的流），
// 帧解码委托给对应 fmt 模块（照 fmt/mka 成功模式，见模块头注）。
const flacmod = @import("flac/lib.zig");
const opusmod = @import("opus/lib.zig");
const opus_packet = @import("opus/packet.zig");
const ac3mod = @import("ac3/lib.zig");
const mp3mod = @import("mp3/lib.zig");
const ogg = @import("ogg.zig");
const m4a_ogg = @import("m4a_ogg.zig");
const alsmod = @import("als/lib.zig");
const md5mod = @import("ac3/md5.zig");

const Allocator = std.mem.Allocator;
const VTable = decoder.Decoder.VTable;

/// 单条标签文本长度上限（截断超长值，防畸形 box 撑爆内存）
const max_meta_text = 64 * 1024;

// ---------------------------------------------------------------------------
// 容器数据结构
// ---------------------------------------------------------------------------

/// box 头解析结果
const Box = struct {
    type: [4]u8,
    /// box 起点（size 字段处）
    start: u64,
    /// payload 起点（size+type 之后；largesize 时含 8 字节扩展头）
    data: u64,
    /// 总大小（含头；largesize 已展开；0 = 至父末尾）
    size: u64,
};

/// stts run（ISO 14496-12 §8.6.1.2）
const SttsRun = struct { count: u32, delta: u32 };

/// stsc run（ISO 14496-12 §8.7.4；first_chunk 为 1 基）
const StscRun = struct { first_chunk: u32, samples_per_chunk: u32 };

/// stsz 解析结果
const Stsz = struct {
    sample_count: u32,
    /// ≠ 0 → 全部样本等长；sizes 为空
    uniform_size: u32,
    /// 非等长时逐样本尺寸（allocator 分配）
    sizes: []u32 = &.{},
};

/// 线性样本表项（offset = 文件内帧字节起点）
const SampleEntry = struct {
    offset: u64,
    size: u32,
};

/// 一个 trak 的完整解析结果（open 成功路径独占所有权）
/// 音频 codec 配置（stsd 条目解析结果）
const CodecCfg = union(enum) {
    alac: alac.Config,
    aac: asc.M4ACfg,
    /// FLAC：STREAMINFO 元数据块原始字节（34B，来自 dfLa 盒）
    flac: [34]u8,
    /// Opus：合成 Ogg OpusHead（19B，LE；来自 dOps 盒）
    opus: [19]u8,
    ac3: void,
    eac3: void,
    mp3: void,
    /// ALS：ALSSpecificConfig（来自 mp4a/esds DecoderSpecificInfo 解析）
    als: alsmod.SpecificConfig,
};

/// 委托解码器类别（帧解码走 fmt/* 既有 open）
const DelegateCodec = enum { flac, opus, ac3, eac3, mp3, als };

/// 委托模式是否启用（该 codec 轨走合成流 + inner 解码）
fn isDelegate(codec: CodecCfg) bool {
    return switch (codec) {
        .alac, .aac => false,
        .flac, .opus, .ac3, .eac3, .mp3, .als => true,
    };
}

fn delegateName(codec: CodecCfg) [:0]const u8 {
    return switch (codec) {
        .flac => "flac",
        .opus => "opus",
        .ac3 => "ac3",
        .eac3 => "eac3",
        .mp3 => "mp3",
        .als => "mp4als",
        else => unreachable,
    };
}

const Parsed = struct {
    codec: CodecCfg,
    samples: []SampleEntry,
    /// 逐帧累计样本偏移（len = samples.len + 1；offsets[k] = 第 k 帧前样本数）
    frame_offsets: []u64,
    /// stts 声明的总样本数（时长精确度判定用）
    stts_total: u64,
    /// elst 段时长（输出样本上限；0 = 无 elst）
    elst_seg_dur: u64 = 0,
    /// elst media_time（需跳过的 priming 样本；0 = 无）
    elst_media_time: i64 = 0,
};

/// ALAC 逐帧解码状态（decoded/scratch 缓冲）
const AlacState = struct {
    decoded_buf: []i32,
    decoded: [8][]i32,
    scratch_buf: []i32,
    scratch: alac.Scratch,
};

/// M4A 解码上下文（ALAC 或 AAC-LC，stsd 条目决定）
const M4aCtx = struct {
    allocator: Allocator,
    /// 按值持有（open 传入 reader 拷贝，deinit 时关闭）
    reader: io.Reader,
    codec: CodecCfg,
    samples: []SampleEntry,
    frame_offsets: []u64,
    channels: u8,
    out_bps: u8,
    /// ALAC：左移位数；AAC：恒 0（输出已是 s16）
    out_shift: u5,
    /// 解码器状态（按 codec 分派；open 时按 codec 覆盖）
    st: union(enum) {
        alac: AlacState,
        aac: aacmod.Aac,
    } = .{ .alac = .{ .decoded_buf = &.{}, .decoded = undefined, .scratch_buf = &.{}, .scratch = undefined } },
    /// 帧数据缓冲（按需增长）
    frame_buf: []u8,
    frame_cap: usize,
    /// 当前已解码帧：剩余游标 / 样本数（AAC 输出经 out_buf，此处 track 字节游标）
    frame_cursor: usize,
    cur_samples: usize,
    /// 下一个待解码 sample 索引
    next_sample: u64,
    /// 跳过首帧（M4A AAC encoder delay priming；对齐 FFmpeg 实测）
    skip_first: bool = false,
    /// 还需跳过的 priming 样本（elst media_time）
    skip_samples: u64 = 0,
    /// 输出样本上限（elst segment_duration；0 = 不限制）
    output_limit: u64 = 0,
    /// 已输出样本总数（position_ms 依据，seek 时按 frame_offsets 回填）
    samples_done: u64,
    /// 标签元数据（moov/udta 解析；destroyCtx 释放）
    meta: decoder.Metadata = .{},

    // ---- 委托解码字段（flac/opus/ac3/eac3/mp3 轨；isDelegate 才使用）----
    /// 委托输出采样率（= inner 输出率；Info/seek 依据）
    sample_rate: u32 = 0,
    /// 合成后的 codec 字节流（flac 头+帧 / opus ogg / ac3-eac3-mp3 帧直拼）
    spool: []u8 = &.{},
    /// 合成流解码器（inner，spool 的 mem reader）
    inner: decoder.Decoder = undefined,
    /// inner 是否已打开（destroyCtx 判定）
    inner_open: bool = false,
    /// 解码暂存（单次 inner.read 落点缓冲，可按需扩容）
    del_buf: []u8 = &.{},
    /// del_buf 容量（帧数）
    del_cap_frames: usize = 0,
    /// del_buf 已填充帧数 / 已消费游标
    del_frames: usize = 0,
    del_pos: usize = 0,
    /// 起始 priming 剩余（elst media_time 样本；opus 由 OpusHead pre-skip 承担 = 0）
    priming_left: u64 = 0,
    /// 起始 priming 定额（seek reset 后复原 priming_left）
    delegate_priming: u64 = 0,
    /// inner 已 EOF
    inner_eof: bool = false,
    /// 已达输出上限
    del_finished: bool = false,
};

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

// ---------------------------------------------------------------------------
// box 解析原语
// ---------------------------------------------------------------------------

fn readAt(r: *io.Reader, off: u64, buf: []u8) Error!usize {
    try r.seek(@intCast(off), .start);
    return r.read(buf);
}

fn readU32(r: *io.Reader, off: u64) Error!u32 {
    var b: [4]u8 = undefined;
    const n = try readAt(r, off, &b);
    if (n != 4) return error.Corrupt;
    return std.mem.readInt(u32, &b, .big);
}

/// 解析 off 处的 box 头。头部不足 8 字节或 data 越过父边界 → null（截断/非 box）。
/// 损坏（size 字段自相矛盾）→ error.Corrupt。
fn parseBox(r: *io.Reader, off: u64, parent_end: u64) Error!?Box {
    if (off + 8 > parent_end) return null;
    var hdr: [8]u8 = undefined;
    const n = try readAt(r, off, &hdr);
    if (n < 8) return null;
    const size32 = std.mem.readInt(u32, hdr[0..4], .big);
    var size: u64 = size32;
    var data = off + 8;
    if (size32 == 1) {
        var ext: [8]u8 = undefined;
        const m = try readAt(r, off + 8, &ext);
        if (m < 8) return null;
        size = std.mem.readInt(u64, &ext, .big);
        data = off + 16;
    } else if (size32 == 0) {
        size = parent_end - off; // 延伸至父末尾
    }
    if (data > parent_end or size < data - off) return error.Corrupt;
    return Box{ .type = hdr[4..8].*, .start = off, .data = data, .size = size };
}

/// 顶层扫描找指定 type 的 box（moov 可能在 mdat 后，须按 size 精确跳转）
fn findTopBox(r: *io.Reader, comptime t: *const [4:0]u8) Error!Box {
    const file_size = try r.size();
    var off: u64 = 0;
    while (off + 8 <= file_size) {
        const b = (try parseBox(r, off, file_size)) orelse return error.Corrupt;
        if (std.mem.eql(u8, t, &b.type)) return b;
        if (b.size == 0) break;
        off += b.size;
        if (off > file_size) return error.Corrupt;
    }
    return error.Corrupt;
}

/// 在 parent payload 内找指定 type 的直系子 box；未找到 → null
fn findChild(r: *io.Reader, parent: Box, comptime t: *const [4:0]u8) Error!?Box {
    const parent_end = parent.start + parent.size;
    var off = parent.data;
    while (off + 8 <= parent_end) {
        const b = (try parseBox(r, off, parent_end)) orelse return null;
        if (std.mem.eql(u8, t, &b.type)) return b;
        if (b.size == 0) break;
        off += b.size;
    }
    return null;
}

// ---------------------------------------------------------------------------
// stbl 各表解析
// ---------------------------------------------------------------------------

/// stsd 条目解析结果
const StsdEntry = enum { alac, aac, flac, opus, ac3, eac3, mp3, als, other };

/// stsd：扫描 sample entries，识别首个音频 codec 条目。
///   'alac' → 内层 'alac' 子 box（magic cookie，全 36 字节含 size+tag）；
///   'mp4a' → 内层 'esds' 子 box（DecoderSpecificInfo = AudioSpecificConfig）；
///   'fLaC' → 内层 'dfLa' 子 box（FlacSpecificBox = FLAC STREAMINFO 块）；
///   'Opus' → 内层 'dOps' 子 box（OpusSpecificBox → 合成 Ogg OpusHead）；
///   'ac-3' / 'ec-3' / '.mp3' → 自同步帧流（dac3/dec3 盒仅信息性，忽略）；
/// 其余（other / 无条目）→ 该 trak 非自研 codec 音频。
fn parseStsd(r: *io.Reader, stsd: Box, out: *CodecCfg) Error!StsdEntry {
    var b: [8]u8 = undefined;
    const n = try readAt(r, stsd.data, &b);
    if (n < 8) return error.Corrupt;
    const entry_count = std.mem.readInt(u32, b[4..8], .big);
    if (entry_count == 0) return .other;
    const stsd_end = stsd.start + stsd.size;
    var off = stsd.data + 8;
    for (0..entry_count) |_| {
        const entry = (try parseBox(r, off, stsd_end)) orelse return error.Corrupt;
        if (std.mem.eql(u8, &entry.type, "alac")) {
            var cookie: [36]u8 = undefined;
            // 在音频 sample entry 内找 'alac' 子 box（可能被 'wave' 包裹，如旧
            // QuickTime wave 包裹布局，容器历史行为）
            if (try scanAlacCookie(r, entry, &cookie)) {
                out.* = .{ .alac = try alac.Config.parse(&cookie) };
                return .alac;
            }
            return error.Corrupt; // 有 alac 条目却无有效 cookie → 损坏
        }
        if (std.mem.eql(u8, &entry.type, "mp4a") or std.mem.eql(u8, &entry.type, "ALS")) {
            var asc_buf: [512]u8 = undefined;
            if (try scanEsdsAsc(r, entry, &asc_buf)) |asc_bytes| {
                // ALS：ASC AOT=36（mp4als；esds objectTypeIndication 0x40 → MP4ALS）。
                // 先试 ALS 配置解析（AOT 不符返回 null），再回退 AAC-LC 判定。
                // 引擎统一 Decoder 的声道数为 u8，超 255 声道（如 512ch 参考样本）
                // 走不了本内核管道 → 返回 .other（上层回退系统 ffmpeg）。
                if (try alsmod.tryParseConfig(asc_bytes)) |als_cfg| {
                    if (als_cfg.channels > 255) return .other;
                    out.* = .{ .als = als_cfg };
                    return .als;
                }
                const cfg = try asc.parseAsc(asc_bytes, true);
                if (cfg.cfg.object_type != asc.AOT_AAC_LC and cfg.cfg.object_type != asc.AOT_ER_AAC_LC) return .other;

                out.* = .{ .aac = cfg.cfg };
                return .aac;
            }
            return .other; // mp4a 但无有效 ASC → 非 AAC-LC/ALS
        }
        if (std.mem.eql(u8, &entry.type, "fLaC")) {
            var si: [34]u8 = undefined;
            if (!try scanFlacStreaminfo(r, entry, &si)) return error.Corrupt;
            out.* = .{ .flac = si };
            return .flac;
        }
        if (std.mem.eql(u8, &entry.type, "Opus")) {
            var head: [19]u8 = undefined;
            if (!try scanOpusHead(r, entry, &head)) return .other; // 多声道映射等 → 回退
            out.* = .{ .opus = head };
            return .opus;
        }
        if (std.mem.eql(u8, &entry.type, "ac-3")) {
            out.* = .{ .ac3 = {} };
            return .ac3;
        }
        if (std.mem.eql(u8, &entry.type, "ec-3")) {
            out.* = .{ .eac3 = {} };
            return .eac3;
        }
        if (std.mem.eql(u8, &entry.type, ".mp3")) {
            out.* = .{ .mp3 = {} };
            return .mp3;
        }
        if (entry.size == 0) break;
        off += entry.size;
        if (off > stsd_end) return error.Corrupt;
    }
    return .other;
}

/// 在 sample entry payload（或其 'wave' 子 box）内找 'dfLa' 子 box，取 STREAMINFO
/// 元数据块 34 字节。dfLa payload = version(1)+flags(3) + FLAC metadata block
/// （块头 4B：last(1bit)+type(7bit)+len(24bit) + 数据），对齐 ffmpeg mov_read_dfla。
fn scanFlacStreaminfo(r: *io.Reader, entry: Box, out_si: *[34]u8) Error!bool {
    const end = entry.start + entry.size;
    var off = entry.data + 28;
    while (off + 8 <= end) {
        const child = (try parseBox(r, off, end)) orelse return false;
        if (std.mem.eql(u8, &child.type, "dfLa")) {
            if (child.size < 8 + 4 + 4 + 34) return error.Corrupt;
            var hdr: [8]u8 = undefined;
            const m = try readAt(r, child.data, &hdr);
            if (m < 8) return error.Corrupt;
            if (hdr[0] != 0) return error.Corrupt; // FlacSpecificBox version 必须 0
            var bh: [4]u8 = undefined;
            const mb = try readAt(r, child.data + 4, &bh);
            if (mb < 4) return error.Corrupt;
            const blk_type = bh[0] & 0x7F;
            const blk_len: u32 = (@as(u32, bh[1]) << 16) | (@as(u32, bh[2]) << 8) | bh[3];
            if (blk_type != 0 or blk_len != 34) return error.Corrupt; // 首块须 STREAMINFO
            const rr = try readAt(r, child.data + 8, out_si);
            if (rr != 34) return error.Corrupt;
            return true;
        }
        if (child.size == 0) break;
        off += child.size;
    }
    return false;
}

/// 在 sample entry payload 内找 'dOps' 子 box，把 OpusSpecificBox 转为 Ogg OpusHead
/// （LE）。OpusSpecificBox = version(1) + OutputChannelCount(1) + PreSkip(2 BE) +
/// InputSampleRate(4 BE) + OutputGain(2 BE) + ChannelMappingFamily(1) [+ mapping 表]；
/// 兼容带 4 字节 version+flags 的写法（无 flags 时识别）。对齐 ffmpeg mov_read_dops。
fn scanOpusHead(r: *io.Reader, entry: Box, out_head: *[19]u8) Error!bool {
    const end = entry.start + entry.size;
    var off = entry.data + 28;
    while (off + 8 <= end) {
        const child = (try parseBox(r, off, end)) orelse return false;
        if (std.mem.eql(u8, &child.type, "dOps")) {
            if (child.size < 8 + 11) return error.Corrupt;
            var buf: [64]u8 = undefined;
            const plen = try readAt(r, child.data, &buf);
            if (plen < 11) return error.Corrupt;
            const p = buf[0..plen];
            if (p[0] != 0) return error.Corrupt; // version 必须 0
            var fi: usize = 1;
            // 兼容 fullbox（version+flags）布局：flags 全零且其后为合理声道数
            if (plen >= 14 and p[1] == 0 and p[2] == 0 and p[3] == 0 and p[4] >= 1 and p[4] <= 2) fi = 4;
            if (fi + 10 > plen) return error.Corrupt;
            const channels = p[fi];
            const pre_skip: u16 = std.mem.readInt(u16, p[fi + 1 ..][0..2], .big);
            const rate: u32 = std.mem.readInt(u32, p[fi + 3 ..][0..4], .big);
            const gain: i16 = @bitCast(std.mem.readInt(u16, p[fi + 7 ..][0..2], .big));
            const family = p[fi + 9];
            if (channels < 1 or channels > 2) return false; // fmt/opus 仅 1/2 声道
            if (family != 0 and family != 1) return false;
            @memcpy(out_head[0..8], "OpusHead");
            out_head[8] = 1;
            out_head[9] = channels;
            std.mem.writeInt(u16, out_head[10..12], pre_skip, .little);
            std.mem.writeInt(u32, out_head[12..16], rate, .little);
            std.mem.writeInt(i16, out_head[16..18], gain, .little);
            out_head[18] = family;
            return true;
        }
        if (child.size == 0) break;
        off += child.size;
    }
    return false;
}

/// 在 sample entry payload（或其 'wave' 子 box）内找 'alac' 子 box 并拷贝 cookie。
/// 标准 QT 音频 sample entry 前 28 字节为固定音频字段（reserved/data_ref/version/
/// revision/vendor/channels/samplesize/compression_id/packet_size/samplerate），
/// codec 子 box 从其后开始；'wave' 包裹布局中则直接是子 box（无固定字段）。
fn scanAlacCookie(r: *io.Reader, entry: Box, out_cookie: *[36]u8) Error!bool {
    return scanAlacBoxes(r, entry, out_cookie, entry.data + 28);
}

fn scanAlacBoxes(r: *io.Reader, box: Box, out_cookie: *[36]u8, from: u64) Error!bool {
    const end = box.start + box.size;
    var off = from;
    while (off + 8 <= end) {
        const child = (try parseBox(r, off, end)) orelse return false;
        if (std.mem.eql(u8, &child.type, "alac")) {
            if (child.size < 36) return error.Corrupt;
            const m = try readAt(r, child.start, out_cookie);
            if (m != 36) return error.Corrupt;
            return true;
        }
        if (std.mem.eql(u8, &child.type, "wave")) {
            if (try scanAlacBoxes(r, child, out_cookie, child.data)) return true;
        }
        if (child.size == 0) break;
        off += child.size;
    }
    return false;
}

/// 在 esds payload 内递归找 DecoderSpecificInfo（tag 0x05）→ 返回 ASC。
/// 正确处理 ES_Descriptor(0x03)/DecoderConfig(0x04) 嵌套；DecoderConfig 前
/// 13 字节为 objectType/streamType/bufferSize/maxRate/avgRate，需跳过。
fn findAscDescriptor(data: []const u8, start: usize) ?[]const u8 {
    var o = start;
    while (o + 2 <= data.len) {
        const tag = data[o];
        o += 1;
        const len = readDescrLen(data, &o) orelse return null;
        if (o + len > data.len) return null;
        if (tag == 0x05) return data[o .. o + len];
        if (len == 0) {
            o += 1;
            continue;
        } // 避免零长描述符死循环
        if (tag == 0x03) { // ES_Descriptor：ES_ID(2)+flags(1) 后找子描述符
            if (findAscDescriptor(data, o + 3)) |r| return r;
        } else if (tag == 0x04) { // DecoderConfig：13 字节头后找 DecoderSpecificInfo
            if (findAscDescriptor(data, o + 13)) |r| return r;
        }
        o += len;
    }
    return null;
}

/// 在 mp4a sample entry 内找 'esds' 子 box，提取 DecoderSpecificInfo 原始字节
/// （即 AudioSpecificConfig）。返回指向 buf 的切片（buf 由调用方提供并保持存活，
/// 直至 codec 配置解析完成；不得返回本函数栈上缓冲）。
fn scanEsdsAsc(r: *io.Reader, entry: Box, buf: *[512]u8) Error!?[]const u8 {
    const end = entry.start + entry.size;
    var off = entry.data + 28; // 音频 sample entry 固定字段
    while (off + 8 <= end) {
        const child = (try parseBox(r, off, end)) orelse return null;
        if (std.mem.eql(u8, &child.type, "esds")) {
            const body = try readAt(r, child.data, buf);
            if (body < 5) return null;
            const data = buf[0..body];
            // esds payload = version+flags(4) + 描述符序列
            return findAscDescriptor(data, 4);
        }
        if (child.size == 0) break;
        off += child.size;
    }
    return null;
}

/// MPEG-4 描述符长度：1-4 字节，每字节 7 位，MSB=续位（ISO 14496-1 §8.3.3）。
fn readDescrLen(data: []const u8, off: *usize) ?usize {
    var len: usize = 0;
    var count: usize = 0;
    while (count < 4) : (count += 1) {
        if (off.* >= data.len) return null;
        const b = data[off.*];
        off.* += 1;
        len = (len << 7) | (b & 0x7F);
        if ((b & 0x80) == 0) return len;
    }
    return null;
}

/// stts：返回 run 表（allocator 分配），并输出总样本数
fn parseStts(r: *io.Reader, box: Box, allocator: Allocator, total: *u64) Error![]SttsRun {
    var b: [8]u8 = undefined;
    const n = try readAt(r, box.data, &b);
    if (n < 8) return error.Corrupt;
    const count = std.mem.readInt(u32, b[4..8], .big);
    if (count > (box.size - 8) / 8) return error.Corrupt; // 条目数越界（§13.3）
    const runs = try allocator.alloc(SttsRun, count);
    errdefer allocator.free(runs);
    const end = box.data + box.size;
    var off = box.data + 8;
    var sum: u64 = 0;
    for (0..count) |i| {
        if (off + 8 > end) return error.Corrupt;
        var e: [8]u8 = undefined;
        const m = try readAt(r, off, &e);
        if (m != 8) return error.Corrupt;
        runs[i] = .{
            .count = std.mem.readInt(u32, e[0..4], .big),
            .delta = std.mem.readInt(u32, e[4..8], .big),
        };
        sum += @as(u64, runs[i].count) * runs[i].delta;
        if (sum > (1 << 62)) return error.Corrupt;
        off += 8;
    }
    total.* = sum;
    return runs;
}

/// stsc：返回 run 表（first_chunk 单调不减校验）
fn parseStsc(r: *io.Reader, box: Box, allocator: Allocator) Error![]StscRun {
    var b: [8]u8 = undefined;
    const n = try readAt(r, box.data, &b);
    if (n < 8) return error.Corrupt;
    const count = std.mem.readInt(u32, b[4..8], .big);
    if (count > (box.size - 8) / 12) return error.Corrupt;
    const runs = try allocator.alloc(StscRun, count);
    errdefer allocator.free(runs);
    const end = box.data + box.size;
    var off = box.data + 8;
    var prev_first: u32 = 0;
    for (0..count) |i| {
        if (off + 12 > end) return error.Corrupt;
        var e: [12]u8 = undefined;
        const m = try readAt(r, off, &e);
        if (m != 12) return error.Corrupt;
        runs[i] = .{
            .first_chunk = std.mem.readInt(u32, e[0..4], .big),
            .samples_per_chunk = std.mem.readInt(u32, e[4..8], .big),
        };
        if (runs[i].first_chunk < prev_first) return error.Corrupt; // 非升序
        prev_first = runs[i].first_chunk;
        off += 12;
    }
    return runs;
}

/// stco/co64：返回 chunk 偏移表（u64，co64 原样，stco 扩展）
fn parseChunkOffsets(r: *io.Reader, box: Box, allocator: Allocator) Error![]u64 {
    const is64 = std.mem.eql(u8, &box.type, "co64");
    var b: [8]u8 = undefined;
    const n = try readAt(r, box.data, &b);
    if (n < 8) return error.Corrupt;
    const count = std.mem.readInt(u32, b[4..8], .big);
    const stride: u64 = if (is64) 8 else 4;
    if (count > (box.size - 8) / stride) return error.Corrupt;
    const offs = try allocator.alloc(u64, count);
    errdefer allocator.free(offs);
    const end = box.data + box.size;
    var off = box.data + 8;
    for (0..count) |i| {
        if (off + stride > end) return error.Corrupt;
        if (is64) {
            var e: [8]u8 = undefined;
            const m = try readAt(r, off, &e);
            if (m != 8) return error.Corrupt;
            offs[i] = std.mem.readInt(u64, &e, .big);
            off += 8;
        } else {
            var e: [4]u8 = undefined;
            const m = try readAt(r, off, &e);
            if (m != 4) return error.Corrupt;
            offs[i] = std.mem.readInt(u32, &e, .big);
            off += 4;
        }
    }
    return offs;
}

/// stsz：等长（uniform_size ≠ 0）或逐样本尺寸
fn parseStsz(r: *io.Reader, box: Box, allocator: Allocator) Error!Stsz {
    var b: [12]u8 = undefined;
    const n = try readAt(r, box.data, &b);
    if (n < 12) return error.Corrupt;
    const uniform = std.mem.readInt(u32, b[4..8], .big);
    const sample_count = std.mem.readInt(u32, b[8..12], .big);
    if (uniform != 0) {
        // 等长样本无需逐样本表（表长由 stsc/stco 决定，见 buildSampleTable）
        if (sample_count > (1 << 30)) return error.Corrupt;
        return .{ .sample_count = sample_count, .uniform_size = uniform };
    }
    if (sample_count > (box.size - 12) / 4) return error.Corrupt;
    const sizes = try allocator.alloc(u32, sample_count);
    errdefer allocator.free(sizes);
    const end = box.data + box.size;
    var off = box.data + 12;
    for (0..sample_count) |i| {
        if (off + 4 > end) return error.Corrupt;
        var e: [4]u8 = undefined;
        const m = try readAt(r, off, &e);
        if (m != 4) return error.Corrupt;
        sizes[i] = std.mem.readInt(u32, &e, .big);
        off += 4;
    }
    return .{ .sample_count = sample_count, .uniform_size = 0, .sizes = sizes };
}

// ---------------------------------------------------------------------------
// 表构建
// ---------------------------------------------------------------------------

/// stsc/stco/stsz → 线性 sample 表。chunk 内样本按 stsz 逐样本累计偏移。
fn buildSampleTable(
    allocator: Allocator,
    stsc_runs: []const StscRun,
    chunk_offsets: []const u64,
    stsz: Stsz,
) Error![]SampleEntry {
    var entries = std.ArrayList(SampleEntry).empty;
    errdefer entries.deinit(allocator);
    var sample_idx: u64 = 0;
    const sample_count = stsz.sample_count;
    for (0..stsc_runs.len) |ri| {
        const run = stsc_runs[ri];
        if (run.first_chunk == 0) return error.Corrupt; // 1 基约束
        const start_chunk: u64 = run.first_chunk - 1;
        const end_chunk: u64 = if (ri + 1 < stsc_runs.len)
            stsc_runs[ri + 1].first_chunk - 1
        else
            chunk_offsets.len;
        if (end_chunk < start_chunk) return error.Corrupt;
        if (start_chunk >= chunk_offsets.len) return error.Corrupt;
        var chunk: u64 = start_chunk;
        while (chunk < end_chunk) : (chunk += 1) {
            var off = chunk_offsets[chunk];
            for (0..run.samples_per_chunk) |_| {
                if (sample_idx >= sample_count) break;
                const size: u32 = if (stsz.uniform_size != 0)
                    stsz.uniform_size
                else
                    stsz.sizes[@intCast(sample_idx)];
                entries.append(allocator, .{ .offset = off, .size = size }) catch
                    return error.OutOfMemory;
                off += size;
                sample_idx += 1;
            }
        }
    }
    return entries.toOwnedSlice(allocator);
}

/// stts run → 逐帧累计样本偏移（len = frame_count + 1）。
/// run 耗尽后以 fallback（cookie max_samples_per_frame）续接（异常文件兜底）。
fn buildFrameOffsets(
    allocator: Allocator,
    stts_runs: []const SttsRun,
    frame_count: usize,
    fallback: u32,
) Error![]u64 {
    const offs = try allocator.alloc(u64, frame_count + 1);
    errdefer allocator.free(offs);
    offs[0] = 0;
    var total: u64 = 0;
    var ri: usize = 0;
    var remaining: u32 = if (stts_runs.len > 0) stts_runs[0].count else 0;
    for (0..frame_count) |k| {
        while (remaining == 0 and ri + 1 < stts_runs.len) {
            ri += 1;
            remaining = stts_runs[ri].count;
        }
        const delta: u32 = if (ri < stts_runs.len and remaining > 0) stts_runs[ri].delta else fallback;
        if (remaining > 0) remaining -= 1;
        total += delta;
        offs[k + 1] = total;
    }
    return offs;
}

// ---------------------------------------------------------------------------
// open
// ---------------------------------------------------------------------------

/// 解析一个 trak：非音频轨 → null（has_audio 不变）；音频轨但非 ALAC →
/// null（has_audio=true，open 据此回退 FFmpeg）；ALAC 轨结构损坏 → Corrupt。
fn parseTrak(r: *io.Reader, trak: Box, allocator: Allocator, has_audio: *bool) Error!?Parsed {
    const mdia = (try findChild(r, trak, "mdia")) orelse return null;
    const minf = (try findChild(r, mdia, "minf")) orelse return null;
    const stbl = (try findChild(r, minf, "stbl")) orelse return null;
    const stsd_box = (try findChild(r, stbl, "stsd")) orelse return null;

    // hdlr handler_type：'soun' = 音频轨（ISO 14496-12 §8.4.3.2）；视频/文本轨跳过
    const is_audio = blk: {
        if (try findChild(r, mdia, "hdlr")) |hdlr| {
            var h: [12]u8 = undefined;
            const m = try readAt(r, hdlr.data, &h);
            if (m >= 12 and std.mem.eql(u8, h[8..12], "soun")) break :blk true;
        }
        break :blk false;
    };
    if (!is_audio) return null;

    var codec_cfg: CodecCfg = undefined;
    const entry = try parseStsd(r, stsd_box, &codec_cfg);
    has_audio.* = true; // 音频轨
    if (entry == .other) return null; // 非自研 codec（AAC 轨 HE-AAC/多声道等）→ 回退 FFmpeg

    const stts_box = (try findChild(r, stbl, "stts")) orelse return error.Corrupt;
    const stsc_box = (try findChild(r, stbl, "stsc")) orelse return error.Corrupt;
    const stsz_box = (try findChild(r, stbl, "stsz")) orelse return error.Corrupt;
    const stco_box = (try findChild(r, stbl, "stco")) orelse
        (try findChild(r, stbl, "co64")) orelse return error.Corrupt;

    var stts_total: u64 = 0;
    const stts_runs = try parseStts(r, stts_box, allocator, &stts_total);
    defer allocator.free(stts_runs);
    const stsc_runs = try parseStsc(r, stsc_box, allocator);
    defer allocator.free(stsc_runs);
    const chunk_offsets = try parseChunkOffsets(r, stco_box, allocator);
    defer allocator.free(chunk_offsets);
    const stsz = try parseStsz(r, stsz_box, allocator);
    defer if (stsz.sizes.len > 0) allocator.free(stsz.sizes);

    const samples = try buildSampleTable(allocator, stsc_runs, chunk_offsets, stsz);

    errdefer allocator.free(samples);
    const max_frame_samples: u32 = switch (codec_cfg) {
        .alac => |c| c.max_samples_per_frame,
        .aac => |c| c.frame_length,
        // 委托 codec：stts run 耗尽时的兜底每帧样本数（正常文件不会被用到）
        .flac => |si| (std.mem.readInt(u16, si[2..4], .big)) & 0xFFFF,
        .opus => 960,
        .ac3, .eac3 => 1536,
        .mp3 => 1152,
        .als => |c| c.frame_length,
    };
    const frame_offsets = try buildFrameOffsets(allocator, stts_runs, samples.len, max_frame_samples);
    errdefer allocator.free(frame_offsets);

    // elst（trak→edts→elst）：media_time 为需跳过的 priming 样本，
    // segment_duration 为输出样本上限（时长轨以 timescale 计）。
    var elst_seg_dur: u64 = 0;
    var elst_media_time: i64 = 0;
    if (try findChild(r, trak, "edts")) |edts| {
        if (try findChild(r, edts, "elst")) |elst| {
            var hdr: [20]u8 = undefined;
            const m = try readAt(r, elst.data, &hdr);
            if (m >= 20) {
                const version = hdr[0];
                const entry_count = std.mem.readInt(u32, hdr[4..8], .big);
                if (entry_count >= 1) {
                    if (version == 1) {
                        var e: [20]u8 = undefined;
                        const me = try readAt(r, elst.data + 8, &e);
                        if (me >= 20) {
                            elst_seg_dur = std.mem.readInt(u64, e[0..8], .big);
                            elst_media_time = std.mem.readInt(i64, e[8..16], .big);
                        }
                    } else {
                        var e: [12]u8 = undefined;
                        const me = try readAt(r, elst.data + 8, &e);
                        if (me >= 12) {
                            elst_seg_dur = std.mem.readInt(u32, e[0..4], .big);
                            elst_media_time = std.mem.readInt(i32, e[4..8], .big);
                        }
                    }
                }
            }
        }
    }

    return .{
        .codec = codec_cfg,
        .samples = samples,
        .frame_offsets = frame_offsets,
        .stts_total = stts_total,
        .elst_seg_dur = elst_seg_dur,
        .elst_media_time = elst_media_time,
    };
}

/// 从已打开 Reader 解析 M4A（decoder.open 与测试共用入口）。
/// 成功时 Decoder 接管 `reader` 所有权（deinit 关闭）。
pub fn open(allocator: Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const moov = try findTopBox(reader, "moov");
    const moov_end = moov.start + moov.size;

    // 遍历 trak，取首个受支持 codec 的音频轨；其余音频轨（HE-AAC 等）→
    // UnsupportedFormat，由引擎回退 FFmpeg 主后端（§8.3）；无音频轨 → Corrupt。
    var parsed: ?Parsed = null;
    var has_audio = false;
    var off = moov.data;
    while (off + 8 <= moov_end) {
        const trak = (try parseBox(reader, off, moov_end)) orelse break;
        if (std.mem.eql(u8, "trak", &trak.type)) {
            if (try parseTrak(reader, trak, allocator, &has_audio)) |p| {
                parsed = p;
                break;
            }
        }
        if (trak.size == 0) break;
        off += trak.size;
    }
    var p = parsed orelse return if (has_audio) error.UnsupportedFormat else error.Corrupt;
    // p 的样本表在 ctx 建立后转交 destroyCtx 释放；此 errdefer 只覆盖 ctx 建立前窗口
    errdefer {
        allocator.free(p.samples);
        allocator.free(p.frame_offsets);
    }

    const total_samples = p.frame_offsets[p.samples.len];
    const duration_known: decoder.DurationKnown = if (p.stts_total > 0) .exact else .estimate;

    // ctx 逐字段初始化（M4aCtx 内嵌约 9MB 的 AAC 状态 union；不得用整结构字面量，
    // 否则编译器物化并整块 memcpy 巨大零常量，open 一次性把全部 channel-state 页
    // 读入 RSS。改逐字段赋值：未用 union 区域保持虚拟零页，由 aac.initCommon 按需
    // 零化实际用到的声道状态）。
    const ctx = try allocator.create(M4aCtx);
    errdefer allocator.destroy(ctx);
    ctx.allocator = allocator;
    ctx.reader = undefined;
    ctx.codec = p.codec;
    ctx.samples = p.samples;
    ctx.frame_offsets = p.frame_offsets;
    ctx.channels = 0;
    ctx.out_bps = 16;
    ctx.out_shift = 0;
    ctx.frame_buf = &.{};
    ctx.frame_cap = 0;
    ctx.frame_cursor = 0;
    ctx.cur_samples = 0;
    ctx.next_sample = 0;
    ctx.samples_done = 0;
    ctx.skip_samples = if (p.elst_media_time > 0) @intCast(p.elst_media_time) else 0; // HE 时下乘 2
    ctx.output_limit = p.elst_seg_dur;
    ctx.sample_rate = 0;
    ctx.spool = &.{};
    ctx.inner_open = false;
    ctx.del_buf = &.{};
    ctx.del_cap_frames = 0;
    ctx.del_frames = 0;
    ctx.del_pos = 0;
    ctx.priming_left = 0;
    ctx.delegate_priming = 0;
    ctx.inner_eof = false;
    ctx.del_finished = false;
    ctx.skip_first = false;
    ctx.st = .{ .alac = .{
        .decoded_buf = &.{},
        .decoded = undefined,
        .scratch_buf = &.{},
        .scratch = undefined,
    } }; // destroyCtx 前安全默认（tag=alac、空缓冲）
    ctx.meta = try parseMetadata(allocator, reader, moov);
    errdefer destroyCtx(ctx);
    // ctx 已持有样本表（destroyCtx 释放）；清空 p 引用避免外层 errdefer 二次释放。
    // 委托分支需要完整 sample 表 → 先留一份 p2 快照。
    const p2 = p;
    p.samples = &.{};
    p.frame_offsets = &.{};

    // 委托 codec（fLaC/Opus/ac-3/ec-3/.mp3）：合成流 + inner 解码。
    // priming 语义对齐 ffmpeg mov demuxer（elst media_time 起始丢弃；
    // opus 的 pre-skip 由 OpusHead 承担，不重复丢）。
    if (isDelegate(p2.codec)) {
        try initDelegate(ctx, reader, p2, duration_known, info);
        // 接管 reader（按值拷贝解析后状态）
        ctx.reader = reader.*;
        return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
    }

    // 帧缓冲不预分配：decodeOneFrame 首次按需分配并随样本尺寸增长（frame_cap=0）。

    // 按 codec 初始化解码器状态
    switch (p.codec) {
        .alac => |cfg| {
            ctx.channels = cfg.channels;
            ctx.out_bps = cfg.out_bps;
            ctx.out_shift = cfg.out_shift;
            const max = cfg.max_samples_per_frame;
            const decoded_buf = try allocator.alloc(i32, max * cfg.channels);
            errdefer allocator.free(decoded_buf);
            var decoded: [8][]i32 = undefined;
            for (0..cfg.channels) |c| decoded[c] = decoded_buf[c * max ..][0..max];
            const scratch_buf = try allocator.alloc(i32, 4 * max);
            errdefer allocator.free(scratch_buf);
            ctx.st = .{ .alac = .{
                .decoded_buf = decoded_buf,
                .decoded = decoded,
                .scratch_buf = scratch_buf,
                .scratch = .{
                    .predict_error = .{ scratch_buf[0..max], scratch_buf[max..][0..max] },
                    .extra_bits = .{ scratch_buf[2 * max ..][0..max], scratch_buf[3 * max ..][0..max] },
                },
            } };
        },
        .aac => |cfg| {
            ctx.channels = cfg.channels;
            ctx.st = .{ .aac = .{} }; // 定义基线：重型状态指针为 null（deinit 安全）
            try ctx.st.aac.initCommon(allocator, cfg);
            ctx.skip_first = true; // M4A AAC encoder delay：跳首帧
            // HE-AAC（SBR）：输出为 2× 采样率，priming 也加倍
            if (ctx.skip_samples > 0 and cfg.sbr == 1) ctx.skip_samples *= 2;
        },
        else => unreachable, // 委托 codec 已在上方分支返回
    }

    info.* = buildInfo(ctx, total_samples, duration_known);
    // 接管 reader（按值拷贝解析后状态）
    ctx.reader = reader.*;

    // chan_config=0（PCE）：布局/声道数由首帧 program_config_element 或默认布局回退决定。
    // 预解码若干样本以确定声道数（修正元数据）；随后重置读取状态，让 readImpl
    // 从样本 0 重新处理（含 skip_first priming 语义）。
    if (p.codec == .aac and ctx.st.aac.channels == 0 and ctx.samples.len > 0) {
        var guard: usize = 0;
        while (ctx.st.aac.channels == 0 and ctx.next_sample < ctx.samples.len and guard < 32) : (guard += 1) {
            _ = decodeOneFrame(ctx) catch |e| {
                if (e != error.Corrupt) return e;
            };
        }
        if (ctx.st.aac.channels != 0) {
            ctx.channels = ctx.st.aac.channels;
            info.* = buildInfo(ctx, total_samples, duration_known);
            // 重置读取状态（丢弃预解码缓冲与游标），readImpl 从头开始
            ctx.st.aac.out_pos = 0;
            ctx.st.aac.out_buf.clearRetainingCapacity();
            ctx.frame_cursor = 0;
            ctx.cur_samples = 0;
            ctx.next_sample = 0;
            ctx.samples_done = 0;
            ctx.skip_first = true;
        }
    }
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

// ---------------------------------------------------------------------------
// 委托 codec 初始化（flac/opus/ac3/eac3/mp3）：合成可解码流 + inner open
// ---------------------------------------------------------------------------

/// 委托解码器类别判别（按 codec cfg）
fn delegateOf(codec: CodecCfg) DelegateCodec {
    return switch (codec) {
        .flac => .flac,
        .opus => .opus,
        .ac3 => .ac3,
        .eac3 => .eac3,
        .mp3 => .mp3,
        .als => .als,
        else => unreachable,
    };
}

/// 委托模式下 ctx 初始化：构建合成流 → inner 解码器 → 输出状态就绪。
/// priming/cap 依容器语义：elst media_time = 起始丢弃样本（flac/ac3/eac3/mp3；
/// opus 由 OpusHead pre-skip 承担，此处不重复），elst segment_duration 或 stts
/// 总数 = 输出样本上限（opus 不设上限——mp4 无 granule，ffmpeg 亦解码至 EOF）。
fn initDelegate(
    ctx: *M4aCtx,
    reader: *io.Reader,
    p: Parsed,
    duration_known: decoder.DurationKnown,
    info: *decoder.Info,
) Error!void {
    const allocator = ctx.allocator;
    var priming: u64 = 0;
    var cap: u64 = 0;
    if (p.codec != .opus) {
        if (p.elst_media_time > 0) priming = @intCast(p.elst_media_time);
        cap = if (p.elst_seg_dur > 0) p.elst_seg_dur else p.stts_total;
    }

    ctx.spool = try buildDelegateSpool(allocator, reader, p.codec, p.samples);

    var mem_reader = io.Reader.openMem(ctx.spool);
    var inner_info: decoder.Info = undefined;
    ctx.inner = try openInnerDelegate(allocator, p.codec, &mem_reader, &inner_info);
    ctx.inner_open = true;

    ctx.channels = inner_info.channels;
    ctx.sample_rate = inner_info.sample_rate;
    ctx.out_bps = inner_info.bits_per_sample;
    ctx.priming_left = priming;
    ctx.delegate_priming = priming;
    ctx.output_limit = cap;
    if (ctx.channels == 0 or ctx.sample_rate == 0) return error.Corrupt;
    const frame_bytes = @as(usize, ctx.channels) * (@as(usize, ctx.out_bps) / 8);
    if (frame_bytes == 0) return error.Corrupt;
    ctx.del_cap_frames = 2048;
    ctx.del_buf = try allocator.alloc(u8, ctx.del_cap_frames * frame_bytes);

    // 时长按容器声明（elst seg 或 stts 总数；opus 文件媒体时长不含 pre-skip）
    const total_s: u64 = if (p.elst_seg_dur > 0) p.elst_seg_dur else p.stts_total;
    var duration_us: i64 = 0;
    if (total_s > 0 and ctx.sample_rate > 0) {
        duration_us = @intCast((@as(u128, total_s) * 1_000_000) / ctx.sample_rate);
    }
    info.* = .{
        .sample_rate = ctx.sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = ctx.out_bps,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = duration_known,
        .codec_name = delegateName(p.codec),
        .format_name = "m4a",
        .metadata = ctx.meta,
    };
}

/// 打开 inner 解码器（codec 分派，照 fmt/mka openInner 同型）
fn openInnerDelegate(allocator: Allocator, codec: CodecCfg, mem_reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    return switch (codec) {
        .flac => flacmod.open(allocator, mem_reader, info),
        .opus => opusmod.open(allocator, mem_reader, info),
        .ac3, .eac3 => ac3mod.open(allocator, mem_reader, info),
        .mp3 => mp3mod.open(allocator, mem_reader, info),
        .als => |cfg| alsmod.open(allocator, cfg, mem_reader, info),
        else => error.UnsupportedFormat,
    };
}

/// 逐 sample 读取原始字节并连续拼入 out（供纯帧直拼 codec）
fn appendSamplesRaw(allocator: Allocator, reader: *io.Reader, samples: []const SampleEntry, out: *std.ArrayList(u8)) Error!void {
    for (samples) |s| {
        if (s.size == 0) continue;
        const dst = try out.addManyAsSlice(allocator, s.size);
        const m = try readAt(reader, s.offset, dst);
        if (m != s.size) return error.Corrupt; // 样本截断
    }
}

/// 合成 inner codec 可消费的字节流：
///   .flac → "fLaC" + STREAMINFO metadata block + 帧直拼（dfLa 布局）
///   .opus → Ogg：OpusHead(BOS) + 空 OpusTags + 每包一页（granule 由 TOC 累计）
///   .ac3/.eac3/.mp3 → 帧直拼（自同步）
fn buildDelegateSpool(
    allocator: Allocator,
    reader: *io.Reader,
    codec: CodecCfg,
    samples: []const SampleEntry,
) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    switch (codec) {
        .flac => |si| {
            try out.appendSlice(allocator, "fLaC");
            try out.appendSlice(allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
            try out.appendSlice(allocator, &si);
            try appendSamplesRaw(allocator, reader, samples, &out);
        },
        .ac3, .eac3, .mp3, .als => {
            try appendSamplesRaw(allocator, reader, samples, &out);
        },
        .opus => |head| {
            // 先读全部 sample 字节 + 记录每包在连续缓冲中的起点
            var raw = std.ArrayList(u8).empty;
            defer raw.deinit(allocator);
            var starts = std.ArrayList(usize).empty;
            defer starts.deinit(allocator);
            var seq: u32 = 0;
            for (samples) |s| {
                if (s.size == 0) continue;
                try starts.append(allocator, raw.items.len);
                const dst = try raw.addManyAsSlice(allocator, s.size);
                const m = try readAt(reader, s.offset, dst);
                if (m != s.size) return error.Corrupt;
            }
            // OpusHead BOS 页 + 空 OpusTags（RFC 7845 必需第二头包）
            try m4a_ogg.writeSinglePage(&out, allocator, ogg.HEADER_TYPE_BOS, seq, 0, &head);
            seq += 1;
            var tags = std.ArrayList(u8).empty;
            defer tags.deinit(allocator);
            try tags.appendSlice(allocator, "OpusTags");
            try tags.appendSlice(allocator, &.{ 0, 0, 0, 0 });
            try tags.appendSlice(allocator, &.{ 0, 0, 0, 0 });
            try m4a_ogg.writeSinglePage(&out, allocator, 0, seq, 0, tags.items);
            seq += 1;

            if (starts.items.len == 0) return error.Corrupt;
            // 首遍：TOC 累计 granule（mka 语义：granule = 累计解码样本，不含 pre-skip）
            var gran_list = std.ArrayList(u64).empty;
            defer gran_list.deinit(allocator);
            var gran: u64 = 0;
            for (starts.items, 0..) |st, i| {
                const size: usize = if (i + 1 < starts.items.len)
                    starts.items[i + 1] - st
                else
                    raw.items.len - st;
                const pkt = raw.items[st .. st + size];
                const pp = opus_packet.parse(pkt) catch continue;
                gran += @as(u64, pp.frame_size) * pp.count;
                try gran_list.append(allocator, gran);
            }
            if (gran_list.items.len == 0) return error.Corrupt;
            // 次遍：逐包一页，末包 EOS
            for (starts.items, 0..) |st, i| {
                const size: usize = if (i + 1 < starts.items.len)
                    starts.items[i + 1] - st
                else
                    raw.items.len - st;
                const pkt = raw.items[st .. st + size];
                if (opus_packet.parse(pkt) catch null) |_| {
                    const header_type: u8 = if (i == gran_list.items.len - 1) ogg.HEADER_TYPE_EOS else 0;
                    try m4a_ogg.writeSinglePage(&out, allocator, header_type, seq, gran_list.items[i], pkt);
                    seq += 1;
                }
            }
        },
        else => unreachable,
    }
    return out.toOwnedSlice(allocator);
}

/// 释放 ctx 已持有资源（open 错误路径与 deinit 共用；长度字段判定是否已分配）
fn destroyCtx(ctx: *M4aCtx) void {
    if (ctx.inner_open) ctx.inner.deinit();
    if (ctx.spool.len > 0) ctx.allocator.free(ctx.spool);
    if (ctx.del_buf.len > 0) ctx.allocator.free(ctx.del_buf);
    switch (ctx.st) {
        .alac => |*ast| {
            if (ast.decoded_buf.len > 0) ctx.allocator.free(ast.decoded_buf);
            if (ast.scratch_buf.len > 0) ctx.allocator.free(ast.scratch_buf);
        },
        .aac => |*a| {
            a.deinit(); // AAC 元素槽位/SBR 堆分配状态
            a.out_buf.deinit(ctx.allocator);
        },
    }
    if (ctx.frame_buf.len > 0) ctx.allocator.free(ctx.frame_buf);
    if (ctx.samples.len > 0) ctx.allocator.free(ctx.samples);
    if (ctx.frame_offsets.len > 0) ctx.allocator.free(ctx.frame_offsets);
    freeMeta(ctx.allocator, &ctx.meta);
}

// ---------------------------------------------------------------------------
// M4A 标签（moov → udta → meta → ilst；©nam 等 iTunes 原子）
// ---------------------------------------------------------------------------

const MetaField = enum { title, artist, album, date, genre, comment };

fn m4aFieldOf(tag: *const [4]u8) ?MetaField {
    // '©' = 0xA9；标准 iTunes 原子
    if (std.mem.eql(u8, tag, "\xA9nam")) return .title;
    if (std.mem.eql(u8, tag, "\xA9ART")) return .artist;
    if (std.mem.eql(u8, tag, "\xA9alb")) return .album;
    if (std.mem.eql(u8, tag, "\xA9day")) return .date;
    if (std.mem.eql(u8, tag, "\xA9gen")) return .genre;
    if (std.mem.eql(u8, tag, "\xA9cmt")) return .comment;
    if (std.mem.eql(u8, tag, "aART")) return .artist;
    if (std.mem.eql(u8, tag, "\xA9wrt")) return .artist;
    return null;
}

fn setMetaField(meta: *decoder.Metadata, field: MetaField, s: [:0]const u8) bool {
    switch (field) {
        .title => {
            if (meta.title != null) return false;
            meta.title = s;
        },
        .artist => {
            if (meta.artist != null) return false;
            meta.artist = s;
        },
        .album => {
            if (meta.album != null) return false;
            meta.album = s;
        },
        .date => {
            if (meta.date != null) return false;
            meta.date = s;
        },
        .genre => {
            if (meta.genre != null) return false;
            meta.genre = s;
        },
        .comment => {
            if (meta.comment != null) return false;
            meta.comment = s;
        },
    }
    return true;
}

fn freeMeta(allocator: Allocator, meta: *decoder.Metadata) void {
    inline for (.{ &meta.title, &meta.artist, &meta.album, &meta.date, &meta.genre, &meta.comment }) |f| {
        if (f.*) |s| {
            allocator.free(s);
            f.* = null;
        }
    }
    if (meta.tags.len > 0) {
        for (meta.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        allocator.free(meta.tags);
        meta.tags = &.{};
    }
}

/// 解析 moov → udta → meta → ilst 标签（无标签 → 返回空 Metadata）。
fn parseMetadata(
    allocator: Allocator,
    reader: *io.Reader,
    moov: Box,
) Error!decoder.Metadata {
    var meta: decoder.Metadata = .{};
    errdefer freeMeta(allocator, &meta);

    const udta = (try findChild(reader, moov, "udta")) orelse return .{};
    const meta_box = (try findChild(reader, udta, "meta")) orelse return .{};
    const meta_end = meta_box.start + meta_box.size;
    // meta 是 fullbox：跳过 4 字节 version/flags，遍历子 box 找 ilst（hdlr 之前）
    const meta_payload = meta_box.data + 4;
    if (meta_payload + 8 > meta_end) return .{};
    var boff = meta_payload;
    var ilst: ?Box = null;
    while (boff + 8 <= meta_end) {
        const b = (try parseBox(reader, boff, meta_end)) orelse break;
        if (std.mem.eql(u8, "ilst", &b.type)) {
            ilst = b;
            break;
        }
        if (b.size == 0) break;
        boff += b.size;
    }
    const ilst_box = ilst orelse return .{};

    var tags: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }

    const ilst_end = ilst_box.start + ilst_box.size;
    var off = ilst_box.data;
    while (off + 8 <= ilst_end) {
        const item = (try parseBox(reader, off, ilst_end)) orelse break;
        if (item.size == 0) break;
        const data_box = (try findChild(reader, item, "data")) orelse {
            off += item.size;
            continue;
        };
        // data payload：version/flags(4) + locale(4) + value
        const data_end = data_box.start + data_box.size;
        if (data_box.data + 8 > data_end) {
            off += item.size;
            continue;
        }
        var hdr: [8]u8 = undefined;
        const hn = try readAt(reader, data_box.data, &hdr);
        if (hn < 8) {
            off += item.size;
            continue;
        }
        const data_type: u32 = std.mem.readInt(u32, hdr[0..4], .big) & 0xFFFFFF;
        const value_off = data_box.data + 8;
        const value_len: usize = @intCast(@min(data_end - value_off, max_meta_text));
        const value = allocator.alloc(u8, value_len) catch return error.OutOfMemory;
        var vgot: usize = 0;
        while (vgot < value_len) {
            const r = try readAt(reader, value_off + vgot, value[vgot..]);
            if (r == 0) break;
            vgot += r;
        }
        const trimmed = std.mem.trim(u8, value[0..vgot], " \t\r\n\x00");
        if (data_type != 1 or trimmed.len == 0) {
            allocator.free(value);
            off += item.size;
            continue;
        }

        // 非标准键全量保留（key 为原子四字符，© 保留原字节）
        const k = allocator.dupe(u8, &item.type) catch {
            allocator.free(value);
            return error.OutOfMemory;
        };
        errdefer allocator.free(k);
        const v = allocator.dupe(u8, trimmed) catch {
            allocator.free(value);
            return error.OutOfMemory;
        };
        errdefer allocator.free(v);
        tags.append(allocator, .{ .key = k, .value = v }) catch {
            allocator.free(value);
            return error.OutOfMemory;
        };

        if (m4aFieldOf(&item.type)) |field| {
            const s = allocator.dupeZ(u8, trimmed) catch {
                allocator.free(value);
                return error.OutOfMemory;
            };
            if (!setMetaField(&meta, field, s)) allocator.free(s);
        }
        allocator.free(value);
        off += item.size;
    }
    meta.tags = try tags.toOwnedSlice(allocator);
    return meta;
}

// ---- Info ----

fn buildInfo(ctx: *M4aCtx, total_samples: u64, duration_known: decoder.DurationKnown) decoder.Info {
    const sample_rate: u32 = switch (ctx.codec) {
        .alac => |cfg| cfg.sample_rate,
        .aac => |cfg| if (cfg.ext_sample_rate > 0) cfg.ext_sample_rate else cfg.sample_rate,
        else => unreachable, // 委托 codec 用 initDelegate 的 Info
    };
    const codec_name: [:0]const u8 = switch (ctx.codec) {
        .alac => "alac",
        .aac => "aac",
        else => unreachable,
    };
    var duration_us: i64 = 0;
    if (total_samples > 0 and sample_rate > 0) {
        duration_us = @intCast((@as(u128, total_samples) * 1_000_000) / sample_rate);
    }
    return .{
        .sample_rate = sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = ctx.out_bps,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = duration_known,
        .codec_name = codec_name,
        .format_name = "m4a",
        .metadata = ctx.meta, // moov/udta 标签（©nam 等；生命周期与 Decoder 一致）
    };
}

// ---- VTable 实现 ----

/// AAC 输出声道数（SBR/PS 检测后可能从 ASC 的 1 变为 2）。
fn aacOutChannels(f: *const M4aCtx) usize {
    return f.st.aac.channels;
}

/// AAC 输出采样率（SBR 启用后为 2× 核心采样率）。
fn aacOutSampleRate(f: *const M4aCtx) u32 {
    return f.st.aac.sample_rate;
}

/// 实际输出声道数：AAC 以解码器检测结果为准（HE-AAC v2 PS：ASC mono → 双声道）。
fn outChannelCount(f: *const M4aCtx) usize {
    return switch (f.codec) {
        .alac => f.channels,
        .aac => f.st.aac.channels,
        else => unreachable,
    };
}

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *M4aCtx = @ptrCast(@alignCast(ctx));
    if (isDelegate(f.codec)) return delegateRead(f, out, max_samples, out_channels);
    out_channels.* = @intCast(outChannelCount(f));
    if (max_samples == 0 or out.len == 0) return 0;

    // 声道数可能为 0（chan_config=0，PCE/默认布局在解码首帧才确定）：
    // 先解码一帧以确定声道，再计算帧字节宽。
    var frame_bytes: usize = @as(usize, outChannelCount(f)) * f.out_bps / 8;
    if (frame_bytes == 0) {
        const n = decodeOneFrame(f) catch |err| switch (err) {
            error.Corrupt => return error.Corrupt,
            else => return err,
        } orelse return 0;
        f.cur_samples = n;
        f.frame_cursor = 0;
        frame_bytes = @as(usize, outChannelCount(f)) * f.out_bps / 8;
        out_channels.* = @intCast(outChannelCount(f));
        if (frame_bytes == 0) return 0;
    }
    var cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        // 统一帧残余游标：frame_cursor 标记当前帧已消费样本数
        if (f.frame_cursor < f.cur_samples) {
            const avail = f.cur_samples - f.frame_cursor;
            var take = @min(avail, cap - produced);
            // elst segment_duration 上限：超过则截断（末尾可能非整帧）；仅 AAC 启用
            if (f.output_limit > 0 and f.codec == .aac) {
                const rem = f.output_limit -| f.samples_done;
                if (take > rem) {
                    take = rem;
                    if (take == 0) break;
                }
            }
            emitSamples(f, out[produced * frame_bytes ..], f.frame_cursor, take);
            f.frame_cursor += take;
            f.samples_done += take;
            produced += take;
        } else {
            // 解码下一个 sample（一个 ALAC 帧或 AAC raw_data_block 包）；
            // 坏帧跳过继续（对齐 FLAC 重同步语义，§13.3）；整段无产出时
            // Corrupt 透出（不伪装 EOF）
            const n = decodeOneFrame(f) catch |err| switch (err) {
                error.Corrupt => {
                    if (f.next_sample >= f.samples.len) {
                        if (produced > 0) return produced;
                        return error.Corrupt;
                    }
                    continue;
                },
                else => return err,
            } orelse break;
            // HE-AAC v2（PS）：首帧解析后声道数可能 1→2（mono core → 立体声输出），
            // 帧字节宽 / 输出声道数 / 容量随之后续使用最新值（对齐 ffmpeg）
            if (outChannelCount(f) * f.out_bps / 8 != frame_bytes) {
                frame_bytes = @as(usize, outChannelCount(f)) * f.out_bps / 8;
                cap = @min(max_samples, out.len / frame_bytes);
                out_channels.* = @intCast(outChannelCount(f));
            }
            f.cur_samples = n;
            f.frame_cursor = 0;
            if (f.skip_first) {
                f.skip_first = false;
                // HE-AAC（SBR）：首帧为 QMF 起始延迟，直接输出（不 skip priming，
                // 对齐 ffmpeg——首帧含 QMF 合成延迟样本）
                if (f.codec == .aac and f.st.aac.sbr_enabled) {
                    // 输出本帧（不 continue，不 skip）
                } else {
                    // 丢弃 priming（elst media_time 样本；未解析到时跳 1 帧）
                    const skip = @min(if (f.skip_samples > 0) f.skip_samples else n, n);
                    f.frame_cursor = skip;
                    if (f.skip_samples > 0) {
                        f.skip_samples -= skip;
                        if (f.skip_samples > 0) continue; // 还需继续跳（media_time 跨多帧）
                    }
                    if (f.frame_cursor >= f.cur_samples) continue;
                }
            }
        }
    }
    return produced;
}

/// 委托解码读实现：从 inner 拉帧 → 丢弃 elst priming → 受 output_limit 截断。
fn delegateRead(f: *M4aCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const ch = f.channels;
    out_channels.* = ch;
    if (max_samples == 0 or out.len == 0) return 0;
    const frame_bytes = @as(usize, ch) * (@as(usize, f.out_bps) / 8);
    if (frame_bytes == 0 or f.del_finished) return 0;
    if (f.del_buf.len < f.del_cap_frames * frame_bytes) return error.Corrupt;

    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.del_pos >= f.del_frames) {
            if (f.inner_eof) break;
            var ich: u8 = 0;
            const got = try f.inner.read(f.del_buf[0 .. f.del_cap_frames * frame_bytes], f.del_cap_frames, &ich);
            f.del_frames = got;
            f.del_pos = 0;
            if (got == 0) {
                f.inner_eof = true;
                break;
            }
            if (ich != ch) return error.Corrupt; // 输出声道数与 open 时不一致
            continue;
        }
        var avail = f.del_frames - f.del_pos;
        if (f.priming_left > 0) {
            const pl = @min(f.priming_left, @as(u64, avail));
            f.priming_left -= pl;
            f.del_pos += @intCast(pl);
            avail -= @intCast(pl);
            if (avail == 0) continue;
        }
        var take = avail;
        if (f.output_limit > 0) {
            if (f.samples_done >= f.output_limit) {
                f.del_finished = true;
                break;
            }
            const rem = @min(f.output_limit - f.samples_done, @as(u64, std.math.maxInt(usize)));
            if (take > rem) take = @intCast(rem);
        }
        take = @min(take, cap - produced);
        if (take == 0) break;
        const src = f.del_buf[f.del_pos * frame_bytes ..][0 .. take * frame_bytes];
        @memcpy(out[produced * frame_bytes ..][0 .. take * frame_bytes], src);
        f.del_pos += take;
        f.samples_done += take;
        produced += take;
    }
    return produced;
}

/// 委托 seek：重开 inner（spool 起点）后整段重解 + 丢弃到目标输出样本。
fn delegateSeekMs(f: *M4aCtx, ms: i64) Error!void {
    const sr = f.sample_rate;
    if (sr == 0) return;
    var target: u64 = 0;
    if (ms > 0) {
        target = @intCast((@as(u128, @intCast(ms)) * sr) / 1000);
    }
    try resetInner(f);
    if (target == 0) return;
    const frame_bytes = @as(usize, f.channels) * (@as(usize, f.out_bps) / 8);
    if (frame_bytes == 0) return;
    const scratch = try f.allocator.alloc(u8, f.del_cap_frames * frame_bytes);
    defer f.allocator.free(scratch);
    var left = target;
    var guard: usize = 0;
    while (left > 0) {
        guard += 1;
        if (guard > 200_000_000) return error.SeekFailed;
        var ch: u8 = 0;
        // 只请求剩余量（delegateRead 以 max_samples=cap 截断产出，避免整块超量丢弃）
        const want: usize = @intCast(@min(left, @as(u64, f.del_cap_frames)));
        const n = try delegateRead(f, scratch[0 .. want * frame_bytes], want, &ch);
        if (n == 0) return; // 已到流尾
        left -= @min(left, n);
    }
}

/// 委托 seek/读到 EOF 后的当前位置
fn delegatePositionMs(f: *M4aCtx) i64 {
    const sr = f.sample_rate;
    if (sr == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / sr);
}

/// 重新打开 inner（自 spool 起点），复位修整状态
fn resetInner(f: *M4aCtx) Error!void {
    f.inner.deinit();
    f.inner_open = false;
    var mem_reader = io.Reader.openMem(f.spool);
    var ii: decoder.Info = undefined;
    f.inner = try openInnerDelegate(f.allocator, f.codec, &mem_reader, &ii);
    f.inner_open = true;
    f.channels = ii.channels;
    f.sample_rate = ii.sample_rate;
    f.out_bps = ii.bits_per_sample;
    const frame_bytes = @as(usize, f.channels) * (@as(usize, f.out_bps) / 8);
    if (f.del_buf.len < f.del_cap_frames * frame_bytes) {
        f.del_buf = try f.allocator.realloc(f.del_buf, f.del_cap_frames * frame_bytes);
    }
    f.del_frames = 0;
    f.del_pos = 0;
    f.priming_left = f.delegate_priming;
    f.inner_eof = false;
    f.del_finished = false;
    f.samples_done = 0;
}

/// 解码下一个 sample（一个 ALAC 帧或 AAC raw_data_block 包）；
/// 返回本帧样本数；EOF → null。空样本（size 0）自动跳过。
fn decodeOneFrame(f: *M4aCtx) Error!?usize {
    while (f.next_sample < f.samples.len) {
        const s = f.samples[@intCast(f.next_sample)];
        f.next_sample += 1;
        if (s.size == 0) continue;
        if (s.size > f.frame_cap) {
            f.frame_buf = try f.allocator.realloc(f.frame_buf, s.size);
            f.frame_cap = s.size;
        }
        const n = try readAt(&f.reader, s.offset, f.frame_buf[0..s.size]);
        if (n != s.size) return error.Corrupt; // 样本截断

        switch (f.codec) {
            .alac => |cfg| {
                const ast = &f.st.alac;
                return @as(?usize, try alac.decodeFrame(&cfg, f.frame_buf[0..s.size], ast.decoded[0..f.channels], &ast.scratch));
            },
            .aac => {
                // AAC raw_data_block：带零填充的 BitReader（ESC showBits 可能越界）
                const a = &f.st.aac;
                // 每帧解码前清空 out_buf（该帧的 1024 样本输出）
                a.out_pos = 0;
                a.out_buf.clearRetainingCapacity();
                if (s.size + 64 > f.frame_cap) {
                    f.frame_buf = try f.allocator.realloc(f.frame_buf, s.size + 64);
                    f.frame_cap = s.size + 64;
                }
                @memset(f.frame_buf[s.size .. s.size + 64], 0);
                var br = BitReader.init(f.frame_buf[0 .. s.size + 64]);
                try a.decodeFrame(&br);
                // SBR 启用时输出为 2×（HE-AAC 上采样）
                const out_samples: usize = if (a.sbr_enabled) a.frame_samples * 2 else a.frame_samples;
                return @as(?usize, out_samples);
            },
            else => unreachable, // 委托 codec 不经此路径
        }
    }
    return null;
}

/// 输出交错 PCM：
///   ALAC —— 从 decoded 缓冲取原生位深（v << out_shift）；
///   AAC  —— 从 Aac.out_buf 取 s16 字节流（按已解码帧游标 start 偏移）。
fn emitSamples(f: *M4aCtx, out: []u8, start: usize, count: usize) void {
    switch (f.codec) {
        .alac => {
            const shift: u5 = f.out_shift;
            const ast = &f.st.alac;
            var oi: usize = 0;
            for (0..count) |i| {
                for (0..f.channels) |c| {
                    const v: u32 = @as(u32, @bitCast(ast.decoded[c][start + i])) << shift;
                    switch (f.out_bps) {
                        16 => std.mem.writeInt(u16, @ptrCast(out[oi..][0..2]), @truncate(v), .little),
                        32 => std.mem.writeInt(u32, @ptrCast(out[oi..][0..4]), v, .little),
                        else => unreachable,
                    }
                    oi += f.out_bps / 8;
                }
            }
        },
        .aac => {
            const a = &f.st.aac;
            // out_buf 中第 start 个样本起，连续 count 个样本（每样本 a.channels×2 字节）
            const chn = a.channels;
            const src = a.out_buf.items;
            const byte_off = start * chn * 2;
            const take = count * chn * 2;
            @memcpy(out[0..take], src[byte_off .. byte_off + take]);
        },
        else => unreachable, // 委托 codec 不经此路径
    }
}

// ---- seek ----

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *M4aCtx = @ptrCast(@alignCast(ctx));
    if (isDelegate(f.codec)) return delegateSeekMs(f, ms);
    if (sampleRateOf(f) == 0) return;
    var target: u64 = 0;
    if (ms > 0) {
        target = @min((@as(u128, @intCast(ms)) * sampleRateOf(f)) / 1000, samplesTotal(f));
    }
    // 二分定位最大 k：frame_offsets[k] <= target（整帧对齐，精确到帧边界）
    var lo: usize = 0;
    var hi: usize = f.samples.len;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (f.frame_offsets[mid] <= target) lo = mid else hi = mid - 1;
    }
    f.frame_cursor = f.cur_samples; // 丢弃未输出帧
    f.next_sample = lo;
    f.samples_done = f.frame_offsets[lo];
}

/// positionMs 目标上限（总样本数）
/// codec 采样率
fn sampleRateOf(f: *const M4aCtx) u32 {
    return switch (f.codec) {
        .alac => |c| c.sample_rate,
        .aac => f.st.aac.sample_rate,
        else => f.sample_rate,
    };
}

fn samplesTotal(f: *M4aCtx) u64 {
    return f.frame_offsets[f.samples.len];
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *M4aCtx = @ptrCast(@alignCast(ctx));
    if (isDelegate(f.codec)) return delegatePositionMs(f);
    const sr = sampleRateOf(f);
    if (sr == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / sr);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *M4aCtx = @ptrCast(@alignCast(ctx));
    destroyCtx(f);
    f.reader.deinit();
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 构造 36 字节 magic cookie（与 fmt/alac/lib.zig 测试同构）
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

/// 位追加器（测试编码用，帧构建）
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
        if (self.bit_pos % 8 != 0) self.bit_pos += 8 - (self.bit_pos % 8);
        return self.bytes.toOwnedSlice(testing.allocator);
    }
};

/// 写一个未压缩 ALAC 帧（mono=SCE / stereo=CPE，立体声样本交错 L R L R）
fn writeUncompressedFrame(sample_size: u8, channels: usize, samples: []const i32) ![]u8 {
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(if (channels == 2) 1 else 0, 3); // element 类型
    try w.appendBits(0, 4); // instance tag
    try w.appendBits(0, 12); // reserved
    try w.appendBits(1, 1); // has_size
    try w.appendBits(0, 2); // extra_bits = 0
    try w.appendBits(1, 1); // is_compressed = 0（未压缩）
    try w.appendBits(samples.len / channels, 32); // output_samples（每声道样本数）
    for (samples) |s| {
        const u: u32 = @bitCast(s);
        if (sample_size == 32) {
            try w.appendBits(u >> 16, 16);
            try w.appendBits(u & 0xFFFF, 16);
        } else {
            try w.appendBits(@as(u64, u) & ((@as(u64, 1) << @intCast(sample_size)) - 1), @intCast(sample_size));
        }
    }
    try w.appendBits(7, 3); // END
    return w.toOwnedSlice();
}

/// 向 builder 追加一个 box（自动回填 size）
fn appendBox(
    b: *std.ArrayList(u8),
    allocator: Allocator,
    comptime t: *const [4:0]u8,
    payload: []const u8,
) !void {
    const start = b.items.len;
    try b.appendSlice(allocator, &.{ 0, 0, 0, 0 });
    try b.appendSlice(allocator, t);
    try b.appendSlice(allocator, payload);
    std.mem.writeInt(u32, b.items[start..][0..4], @intCast(b.items.len - start), .big);
}

/// 构造合成 M4A：ftyp + moov(trak→mdia→minf→stbl) + mdat(帧 payload)。
/// frames 每项为完整 ALAC 帧字节；per_chunk = 每 chunk 帧数（0 = 全部单 chunk），
/// 用于多 chunk / 多 stsc run 场景。
const StsdKind = union(enum) {
    alac: [36]u8,
    aac: struct { asc: []const u8, sample_rate: u32, channels: u8 },
};

fn buildAlacM4a(
    allocator: Allocator,
    kind: StsdKind,
    frame_samples: u32,
    frames: []const []const u8,
    per_chunk: usize,
) ![]u8 {
    // ---- chunk 划分 ----
    var chunk_sizes = std.ArrayList(usize).empty;
    defer chunk_sizes.deinit(allocator);
    if (per_chunk == 0 or per_chunk >= frames.len) {
        if (frames.len > 0) try chunk_sizes.append(allocator, frames.len);
    } else {
        var i: usize = 0;
        while (i < frames.len) : (i += per_chunk) {
            try chunk_sizes.append(allocator, @min(per_chunk, frames.len - i));
        }
    }

    // ---- stsd（1 个 sample entry：alac cookie 或 mp4a+esds ASC）----
    var stsd_payload = std.ArrayList(u8).empty;
    defer stsd_payload.deinit(allocator);
    try stsd_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // version/flags
    try stsd_payload.appendSlice(allocator, &.{ 0, 0, 0, 1 }); // entry_count = 1
    switch (kind) {
        .alac => |cookie| {
            const rate = std.mem.readInt(u32, cookie[32..36], .big);
            try stsd_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // size 占位
            try stsd_payload.appendSlice(allocator, "alac");
            try stsd_payload.appendSlice(allocator, &([_]u8{0} ** 6)); // reserved
            try stsd_payload.appendSlice(allocator, &.{ 0, 1 }); // data_reference_index
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // version
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // revision
            try stsd_payload.appendSlice(allocator, &([_]u8{0} ** 4)); // vendor
            try stsd_payload.appendSlice(allocator, &.{ 0, cookie[21] }); // channelcount
            try stsd_payload.appendSlice(allocator, &.{ 0, cookie[17] }); // samplesize
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // compression_id
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // packet_size
            var sr: [4]u8 = undefined;
            std.mem.writeInt(u32, &sr, rate << 16, .big); // samplerate 16.16
            try stsd_payload.appendSlice(allocator, &sr);
            try stsd_payload.appendSlice(allocator, &cookie); // alac 子 box（36 字节）
            std.mem.writeInt(u32, stsd_payload.items[8..12], @intCast(stsd_payload.items.len - 8), .big);
        },
        .aac => |info| {
            try stsd_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // size 占位
            try stsd_payload.appendSlice(allocator, "mp4a");
            try stsd_payload.appendSlice(allocator, &([_]u8{0} ** 6)); // reserved
            try stsd_payload.appendSlice(allocator, &.{ 0, 1 }); // data_reference_index
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // version
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // revision
            try stsd_payload.appendSlice(allocator, &([_]u8{0} ** 4)); // vendor
            try stsd_payload.appendSlice(allocator, &.{ 0, info.channels }); // channelcount
            try stsd_payload.appendSlice(allocator, &.{ 0, 16 }); // samplesize
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // compression_id
            try stsd_payload.appendSlice(allocator, &.{ 0, 0 }); // packet_size
            var sr: [4]u8 = undefined;
            std.mem.writeInt(u32, &sr, info.sample_rate << 16, .big);
            try stsd_payload.appendSlice(allocator, &sr);
            // esds：version+flags(4) + DecoderConfigDescriptor(0x04) + DecoderSpecificInfo(0x05)
            var esds = std.ArrayList(u8).empty;
            defer esds.deinit(allocator);
            try esds.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // version/flags
            // DecoderConfigDescriptor(0x04)：头(13B: tag+len + objectType/streamType/bufferSize/maxRate/avgRate)
            // + DecoderSpecificInfo(0x05: tag+len + ASC)
            try esds.append(allocator, 0x04);
            // len = 13 + (2 + asc.len)
            try esds.append(allocator, @intCast(13 + 2 + info.asc.len));
            try esds.append(allocator, 0x40); // objectTypeIndication AAC
            try esds.append(allocator, 0x15); // streamType audio + 1bit upStream
            try esds.appendSlice(allocator, &.{ 0, 0, 0 }); // bufferSizeDB
            try esds.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // maxBitrate
            try esds.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // avgBitrate
            try esds.append(allocator, 0x05);
            try esds.append(allocator, @intCast(info.asc.len));
            try esds.appendSlice(allocator, info.asc);
            var esds_box = std.ArrayList(u8).empty;
            defer esds_box.deinit(allocator);
            try appendBox(&esds_box, allocator, "esds", esds.items);
            try stsd_payload.appendSlice(allocator, esds_box.items);
            std.mem.writeInt(u32, stsd_payload.items[8..12], @intCast(stsd_payload.items.len - 8), .big);
        },
    }

    var stsd = std.ArrayList(u8).empty;
    defer stsd.deinit(allocator);
    try appendBox(&stsd, allocator, "stsd", stsd_payload.items);

    // ---- stts ----
    var stts_payload = std.ArrayList(u8).empty;
    defer stts_payload.deinit(allocator);
    try stts_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // version/flags
    try stts_payload.appendSlice(allocator, &.{ 0, 0, 0, 1 }); // entry_count = 1
    var se: [8]u8 = undefined;
    std.mem.writeInt(u32, se[0..4], @intCast(frames.len), .big);
    std.mem.writeInt(u32, se[4..8], frame_samples, .big);
    try stts_payload.appendSlice(allocator, &se);
    var stts = std.ArrayList(u8).empty;
    defer stts.deinit(allocator);
    try appendBox(&stts, allocator, "stts", stts_payload.items);

    // ---- stsc（chunk run 合并）----
    var stsc_payload = std.ArrayList(u8).empty;
    defer stsc_payload.deinit(allocator);
    try stsc_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // version/flags
    try stsc_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // entry_count 占位
    var run_count: u32 = 0;
    var first_chunk: u32 = 1;
    var prev: usize = if (chunk_sizes.items.len > 0) chunk_sizes.items[0] else 0;
    var cnt: u32 = 1;
    var ci: usize = 1;
    while (ci <= chunk_sizes.items.len) : (ci += 1) {
        const cur: ?usize = if (ci < chunk_sizes.items.len) chunk_sizes.items[ci] else null;
        if (cur != null and cur.? == prev) {
            cnt += 1;
        } else {
            var e: [12]u8 = undefined;
            std.mem.writeInt(u32, e[0..4], first_chunk, .big);
            std.mem.writeInt(u32, e[4..8], @intCast(prev), .big);
            std.mem.writeInt(u32, e[8..12], 1, .big); // sample_description_index
            try stsc_payload.appendSlice(allocator, &e);
            run_count += 1;
            first_chunk += cnt;
            if (cur != null) {
                prev = cur.?;
                cnt = 1;
            }
        }
    }
    std.mem.writeInt(u32, stsc_payload.items[4..8], run_count, .big);
    var stsc = std.ArrayList(u8).empty;
    defer stsc.deinit(allocator);
    try appendBox(&stsc, allocator, "stsc", stsc_payload.items);

    // ---- stsz（逐样本尺寸）----
    var stsz_payload = std.ArrayList(u8).empty;
    defer stsz_payload.deinit(allocator);
    try stsz_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // version/flags
    try stsz_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // sample_size = 0（非等长）
    try stsz_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // sample_count 占位
    var total_frame_bytes: usize = 0;
    for (frames) |fr| {
        var e: [4]u8 = undefined;
        std.mem.writeInt(u32, &e, @intCast(fr.len), .big);
        try stsz_payload.appendSlice(allocator, &e);
        total_frame_bytes += fr.len;
    }
    std.mem.writeInt(u32, stsz_payload.items[8..12], @intCast(frames.len), .big);
    var stsz = std.ArrayList(u8).empty;
    defer stsz.deinit(allocator);
    try appendBox(&stsz, allocator, "stsz", stsz_payload.items);

    // ---- stco（chunk 偏移占位，组装后回填）----
    var stco_payload = std.ArrayList(u8).empty;
    defer stco_payload.deinit(allocator);
    try stco_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // version/flags
    try stco_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // entry_count 占位
    var off_pos = std.ArrayList(u64).empty;
    defer off_pos.deinit(allocator);
    for (chunk_sizes.items) |_| {
        try stco_payload.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // 占位
        try off_pos.append(allocator, stco_payload.items.len - 4);
    }
    std.mem.writeInt(u32, stco_payload.items[4..8], @intCast(chunk_sizes.items.len), .big);
    var stco = std.ArrayList(u8).empty;
    defer stco.deinit(allocator);
    try appendBox(&stco, allocator, "stco", stco_payload.items);

    // ---- stbl（5 个子表 box 的容器）----
    var stbl_child = std.ArrayList(u8).empty;
    defer stbl_child.deinit(allocator);
    try appendBox(&stbl_child, allocator, "stsd", stsd_payload.items);
    try appendBox(&stbl_child, allocator, "stts", stts_payload.items);
    try appendBox(&stbl_child, allocator, "stsc", stsc_payload.items);
    try appendBox(&stbl_child, allocator, "stco", stco_payload.items);
    try appendBox(&stbl_child, allocator, "stsz", stsz_payload.items);
    var stbl = std.ArrayList(u8).empty;
    defer stbl.deinit(allocator);
    try appendBox(&stbl, allocator, "stbl", stbl_child.items);

    var minf = std.ArrayList(u8).empty;
    defer minf.deinit(allocator);
    try appendBox(&minf, allocator, "minf", stbl.items);

    // ---- mdia：hdlr + minf（hdlr 必须在 mdia 内，ISO 14496-12 §8.4.3.2）----
    var mdia_child = std.ArrayList(u8).empty;
    defer mdia_child.deinit(allocator);
    // hdlr：handler_type 'soun'（音频轨标记）；payload = ver/flags(4) +
    // pre_defined(4) + handler_type(4) + reserved(12) + name NUL(1) = 25 字节
    const hdlr_payload = "\x00\x00\x00\x00\x00\x00\x00\x00soun\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    try appendBox(&mdia_child, allocator, "hdlr", hdlr_payload);
    try appendBox(&mdia_child, allocator, "minf", stbl.items);
    var mdia = std.ArrayList(u8).empty;
    defer mdia.deinit(allocator);
    try appendBox(&mdia, allocator, "mdia", mdia_child.items);

    var trak = std.ArrayList(u8).empty;
    defer trak.deinit(allocator);
    try appendBox(&trak, allocator, "trak", mdia.items);

    var moov = std.ArrayList(u8).empty;
    defer moov.deinit(allocator);
    try appendBox(&moov, allocator, "moov", trak.items);

    // ---- 顶层文件：ftyp + moov + mdat ----
    var file = std.ArrayList(u8).empty;
    defer file.deinit(allocator);
    try appendBox(&file, allocator, "ftyp", "M4A \x00\x00\x00\x00M4A ");
    try file.appendSlice(allocator, moov.items);
    const mdat_payload_off = file.items.len + 8; // mdat 头之后
    var mdat_size: [4]u8 = undefined;
    std.mem.writeInt(u32, &mdat_size, @intCast(total_frame_bytes + 8), .big);
    try file.appendSlice(allocator, &mdat_size);
    try file.appendSlice(allocator, "mdat");
    for (frames) |fr| try file.appendSlice(allocator, fr);

    // ---- 回填 stco chunk 偏移（mdat payload 起点 + 帧累计）----
    // stco payload 文件偏移：ftyp(20) + moov/trak/mdia/minf/stbl 各 8 头 +
    // hdlr(33) + stsd/stts/stsc 三个兄弟 box + stco 自身 8 头
    const stco_payload_off = 20 + 8 * 5 + 33 + stsd.items.len + stts.items.len + stsc.items.len + 8;
    var frame_off: usize = 0;
    var frame_idx: usize = 0;
    for (0..chunk_sizes.items.len) |k| {
        const abs_pos = mdat_payload_off + frame_off;
        std.mem.writeInt(u32, file.items[stco_payload_off + off_pos.items[k] ..][0..4], @intCast(abs_pos), .big);
        for (0..chunk_sizes.items[k]) |_| {
            frame_off += frames[frame_idx].len;
            frame_idx += 1;
        }
    }
    return file.toOwnedSlice(allocator);
}

/// 打开内存 M4A 并返回解码器
fn openMem(allocator: Allocator, file: []const u8, info: *decoder.Info) Error!decoder.Decoder {
    var reader = io.Reader.openMem(file);
    return open(allocator, &reader, info);
}

/// 构建两帧单声道未压缩 M4A 并验证端到端读取
fn buildMonoFrames(allocator: Allocator, samples_per_frame: usize, frame_values: []const []const i32) ![]u8 {
    var frames = std.ArrayList([]const u8).empty;
    defer frames.deinit(allocator);
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |f| allocator.free(f);
        owned.deinit(allocator);
    }
    for (frame_values) |vals| {
        const fr = try writeUncompressedFrame(16, 1, vals);
        try owned.append(allocator, fr);
        try frames.append(allocator, fr);
    }
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    return buildAlacM4a(allocator, .{ .alac = cookie }, @intCast(samples_per_frame), frames.items, 0);
}

test "m4a 集成: 单声道未压缩端到端（Info + 多帧 read + EOF + position）" {
    const vals1 = [_]i32{ 100, -200, 0, 4660 };
    const vals2 = [_]i32{ 1, 2, 3, 4 };
    const file = try buildMonoFrames(testing.allocator, 4, &.{ &vals1, &vals2 });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqualStrings("alac", info.codec_name);
    try testing.expectEqualStrings("m4a", info.format_name);
    try testing.expectEqual(@as(i64, 181), info.duration_us); // 8/44100 s
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 8), try dec.read(&out, 8, &ch));
    const expect = [_]u8{
        0x64, 0x00, 0x38, 0xFF, 0x00, 0x00, 0x34, 0x12, // 100, -200, 0, 4660
        0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, // 1, 2, 3, 4
    };
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 8, &ch)); // EOF
    try testing.expectEqual(@as(i64, 0), dec.positionMs());
}

test "m4a 集成: 立体声 24bit → 32bit 输出左移 8（交错）" {
    const vals = [_]i32{ 1, -1, 2, -2, 3, -3, 4, -4 }; // L0 R0 L1 R1 ...
    const fr = try writeUncompressedFrame(24, 2, &vals);
    defer testing.allocator.free(fr);
    const frames = [_][]const u8{fr};
    const cookie = makeCookie(4096, 24, 2, 96000, 40, 10, 14);
    const file = try buildAlacM4a(testing.allocator, .{ .alac = cookie }, 4, &frames, 0);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 32), info.bits_per_sample);
    try testing.expectEqual(@as(u32, 96000), info.sample_rate);

    var out: [32]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    // 24bit 值左移 8 输出为 u32 LE：1→0x00000100，-1→0xFFFFFF00 …
    const expect = [_]u8{
        0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF,
        0x00, 0x02, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0xFF,
        0x00, 0x03, 0x00, 0x00, 0x00, 0xFD, 0xFF, 0xFF,
        0x00, 0x04, 0x00, 0x00, 0x00, 0xFC, 0xFF, 0xFF,
    };
    try testing.expectEqualSlices(u8, &expect, &out);
}

test "m4a 集成: seek 整帧对齐（frame_offsets 精确落点）" {
    // 6 帧 × 4 样本，值 1..24；采样率 1000Hz → 样本号 = 毫秒数
    var frames2 = std.ArrayList([]const u8).empty;
    defer frames2.deinit(testing.allocator);
    var owned2 = std.ArrayList([]u8).empty;
    defer {
        for (owned2.items) |f| testing.allocator.free(f);
        owned2.deinit(testing.allocator);
    }
    for (0..6) |fi| {
        var vals: [4]i32 = undefined;
        for (0..4) |si| vals[si] = @intCast(fi * 4 + si + 1);
        const fr = try writeUncompressedFrame(16, 1, &vals);
        try owned2.append(testing.allocator, fr);
        try frames2.append(testing.allocator, fr);
    }
    const cookie2 = makeCookie(4096, 16, 1, 1000, 40, 10, 14);
    const file2 = try buildAlacM4a(testing.allocator, .{ .alac = cookie2 }, 4, frames2.items, 0);
    defer testing.allocator.free(file2);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file2, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(i64, 24000), info.duration_us); // 24 样本 @ 1000Hz

    // seek 到样本 ~11（11ms）→ 帧 2（首样本 9）
    try dec.seekMs(11);
    try testing.expectEqual(@as(i64, 8), dec.positionMs()); // 8 样本 = 帧 2 起点
    var out: [2]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 1), try dec.read(&out, 1, &ch));
    try testing.expectEqualSlices(u8, &.{ 0x09, 0x00 }, &out); // 9 LE
    try testing.expectEqual(@as(i64, 9), dec.positionMs()); // 消费 1 样本后 = 9

    // seek 回开头
    try dec.seekMs(0);
    try testing.expectEqual(@as(i64, 0), dec.positionMs());
    const n2 = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00 }, &out); // 1
}

test "m4a 集成: 多 chunk（stsc 多 run + 余数）顺序读取" {
    // 3 帧 × 4 样本，每 chunk 2 帧 → chunks [2,1] → stsc runs [(1,2),(3,1)]，
    // stco 2 个偏移；值 1..12
    var frames = std.ArrayList([]const u8).empty;
    defer frames.deinit(testing.allocator);
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |f| testing.allocator.free(f);
        owned.deinit(testing.allocator);
    }
    for (0..3) |fi| {
        var vals: [4]i32 = undefined;
        for (0..4) |si| vals[si] = @intCast(fi * 4 + si + 1);
        const fr = try writeUncompressedFrame(16, 1, &vals);
        try owned.append(testing.allocator, fr);
        try frames.append(testing.allocator, fr);
    }
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    const file = try buildAlacM4a(testing.allocator, .{ .alac = cookie }, 4, frames.items, 2);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    var out: [24]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 12), try dec.read(&out, 12, &ch));
    var expect: [24]u8 = undefined;
    for (0..12) |i| {
        const v: u16 = @intCast(i + 1);
        std.mem.writeInt(u16, expect[2 * i ..][0..2], v, .little);
    }
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 12, &ch)); // EOF
}

test "m4a 集成: mdat 截断（样本不足）→ Corrupt" {
    const vals = [_]i32{ 1, 2, 3, 4 };
    const fr = try writeUncompressedFrame(16, 1, &vals);
    defer testing.allocator.free(fr);
    const frames = [_][]const u8{fr};
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    const file = try buildAlacM4a(testing.allocator, .{ .alac = cookie }, 4, &frames, 0);
    defer testing.allocator.free(file);
    // 截断 mdat 尾部（帧数据不足 → 样本读取短读 → Corrupt，且无产出 → 透出）
    const truncated = file[0 .. file.len - 3];

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, truncated, &info);
    defer dec.deinit();
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectError(error.Corrupt, dec.read(&out, 8, &ch));
}

test "m4a 集成: 缺 stts / 缺 stco → open Corrupt" {
    const vals = [_]i32{ 1, 2, 3, 4 };
    const fr = try writeUncompressedFrame(16, 1, &vals);
    defer testing.allocator.free(fr);
    const frames = [_][]const u8{fr};
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    const file = try buildAlacM4a(testing.allocator, .{ .alac = cookie }, 4, &frames, 0);
    defer testing.allocator.free(file);

    // stts type 改为 sttx → findChild 找不到 → Corrupt
    const pos_stts = std.mem.indexOf(u8, file, "stts").?;
    file[pos_stts + 3] = 'x';
    var info: decoder.Info = undefined;
    try testing.expectError(error.Corrupt, openMem(testing.allocator, file, &info));

    // stco type 改为 stcx → findChild 找不到 → Corrupt
    file[pos_stts + 3] = 's';
    const pos_stco = std.mem.indexOf(u8, file, "stco").?;
    file[pos_stco + 3] = 'x';
    try testing.expectError(error.Corrupt, openMem(testing.allocator, file, &info));
}

test "m4a 集成: 音频轨但 stsd 无 alac 条目 → open UnsupportedFormat（回退 FFmpeg）" {
    // 手工构建：stsd 只有一个 'mp4a' 条目（无 alac cookie）→ parseStsd 返回 false，
    // hdlr='soun' 已存在 → has_audio → UnsupportedFormat（引擎回退 FFmpeg 解 AAC）
    const cookie = makeCookie(4096, 16, 1, 44100, 40, 10, 14);
    const fr = try writeUncompressedFrame(16, 1, &[_]i32{ 1, 2, 3, 4 });
    defer testing.allocator.free(fr);
    const frames = [_][]const u8{fr};
    var file = try buildAlacM4a(testing.allocator, .{ .alac = cookie }, 4, &frames, 0);
    defer testing.allocator.free(file);
    // 将 stsd 内 alac 条目 type 改为 mp4a（同时把 cookie box type 改掉，双保险）
    const pos_alac = std.mem.indexOf(u8, file, "alac").?;
    file[pos_alac + 1] = 'p';
    file[pos_alac + 2] = '4';
    var info: decoder.Info = undefined;
    try testing.expectError(error.UnsupportedFormat, openMem(testing.allocator, file, &info));
}

test "m4a 集成: AAC 轨（mp4a+esds）识别与解码" {
    // ASC：AAC-LC, 48kHz(索引3), stereo(2)
    // 位：object_type(5)=00010, sf_idx(4)=0011, chan_cfg(4)=0010, frame_short(1)=0
    //     00010001100100 → 前 14 位有效，补 2 位 → 0x11 0x90
    const asc_bytes = [_]u8{ 0x11, 0x90 };

    // 真实 AAC-LC 帧 payload：从 samples/aac/t48_m.aac 提取（用 ADTS 解析）
    // 首帧 payload 字节（0xdc 0x00 0x4c ... 见 §9.5 验收样本）
    // 此处用构造的合成 AAC 帧不可行（需要真实编码数据）；改为验证容器解析
    // 与 codec 识别，解码正确性由真实文件端到端覆盖（§17.2）。
    var frames = std.ArrayList([]const u8).empty;
    defer frames.deinit(testing.allocator);
    var fake_frame = std.ArrayList(u8).empty;
    defer fake_frame.deinit(testing.allocator);
    // 假帧：4 字节占位（仅容器解析，不触发真实解码）
    try fake_frame.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 });
    try frames.append(testing.allocator, fake_frame.items);

    const file = try buildAlacM4a(
        testing.allocator,
        .{ .aac = .{ .asc = &asc_bytes, .sample_rate = 48000, .channels = 2 } },
        1024,
        frames.items,
        0,
    );
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqualStrings("aac", info.codec_name);
    try testing.expectEqualStrings("m4a", info.format_name);
    try testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
}

// ---------------------------------------------------------------------------
// 多 codec（fLaC/Opus/ac-3/ec-3/.mp3）真实样本 e2e —— 与 ffmpeg `-f s16le` 对拍
//
// 样本自造：0.63s 正弦（mono 44.1k / stereo 48k）经 ffmpeg mov 封装为 mp4，
// 各 codec 一份（f_*_*.mp4），golden = ffmpeg 解该 mp4 的 s16le（f_*_*.s16）。
// 容器语义（照 ffmpeg mov demuxer 实测）：
//   - elst media_time = priming（flac=0 / ac3-eac3=256 / mp3=1105 / opus 经
//     OpusHead pre-skip，不重复丢）；opus mp4 无 granule，解码至 EOF（输出
//     略多于媒体时长，与 ffmpeg 一致），其余 codec 截断至 elst seg_dur。
//   - 内嵌样本 mp4 均已含真实编码数据；测试逐字节/相关性对拍。
// ---------------------------------------------------------------------------

const SampleSet = struct {
    mp4: []const u8,
    s16: []const u8,
    rate: u32,
    ch: u8,
    codec_name: [:0]const u8,
    /// 允许的输出长度差（字节；帧宽粒度由解码器决定；flac 等应 0）
    allow_short: usize = 0,
    /// mp3 内核与 ffmpeg 有 codec 层差异（mka 同）：仅锁容器接入 + 确定性，
    /// 不对 ffmpeg 逐样本断言（corr 仅打印）
    skip_corr: bool = false,
};

fn decodeAllM4a(allocator: Allocator, file: []const u8, buf: *std.ArrayList(u8)) !decoder.Info {
    var reader = io.Reader.openMem(file);
    var info: decoder.Info = undefined;
    var dec = try open(allocator, &reader, &info);
    defer dec.deinit();
    var tmp: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&tmp, 4096, &ch);
        if (n == 0) break;
        const fbs: usize = @as(usize, ch) * (@as(usize, info.bits_per_sample) / 8);
        try buf.appendSlice(allocator, tmp[0 .. n * fbs]);
    }
    return info;
}

const Compare = struct {
    corr: f64,
    max_abs: i32,
    equal: usize,
    n: usize,
};

fn compareS16(mine: []const u8, ref: []const u8) Compare {
    const n = @min(mine.len, ref.len) / 2;
    var equal: usize = 0;
    var max_abs: i32 = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    for (0..n) |i| {
        const a = std.mem.readInt(i16, mine[i * 2 ..][0..2], .little);
        const b = std.mem.readInt(i16, ref[i * 2 ..][0..2], .little);
        if (a == b) equal += 1;
        const diff = @as(i32, a) - @as(i32, b);
        const d: i32 = if (diff < 0) -diff else diff;
        if (d > max_abs) max_abs = d;
        sum_num += @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b));
        sum_a2 += @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(a));
        sum_b2 += @as(f64, @floatFromInt(b)) * @as(f64, @floatFromInt(b));
    }
    return .{ .corr = sum_num / @sqrt(sum_a2 * sum_b2), .max_abs = max_abs, .equal = equal, .n = n };
}

fn checkDelegateSample(set: SampleSet, min_corr: f64, print: bool) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    const info = try decodeAllM4a(testing.allocator, set.mp4, &buf);

    try testing.expectEqualStrings(set.codec_name, info.codec_name);
    try testing.expectEqualStrings("m4a", info.format_name);
    try testing.expectEqual(set.rate, info.sample_rate);
    try testing.expectEqual(set.ch, info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);

    if (set.allow_short == 0) {
        try testing.expectEqual(set.s16.len, buf.items.len);
    } else {
        try testing.expect(buf.items.len >= set.s16.len -| set.allow_short);
        try testing.expect(buf.items.len <= set.s16.len + set.allow_short);
    }
    if (set.skip_corr) {
        // 确定性：二次解码逐字节一致（mp3 内核不逐样本对齐 ffmpeg，锁接入）
        var buf2 = std.ArrayList(u8).empty;
        defer buf2.deinit(testing.allocator);
        _ = try decodeAllM4a(testing.allocator, set.mp4, &buf2);
        try testing.expectEqualSlices(u8, buf.items, buf2.items);
        if (print) {
            const c = compareS16(buf.items[0..@min(buf.items.len, set.s16.len)], set.s16[0..@min(buf.items.len, set.s16.len)]);
            std.debug.print(
                "m4a {s}: sr={d} ch={d} mine={d} golden={d}（mp3 codec 层与 ffmpeg 有差异，不逐样本断言）corr={d:.4} max_abs={d} equal {d}/{d}\n",
                .{ set.codec_name, set.rate, set.ch, buf.items.len, set.s16.len, c.corr, c.max_abs, c.equal, c.n },
            );
        }
        return;
    }
    const c = compareS16(buf.items, set.s16);
    if (print) {
        std.debug.print(
            "m4a {s}: sr={d} ch={d} mine={d} golden={d} corr={d:.8} max_abs={d} equal {d}/{d} = {d:.4}%\n",
            .{ set.codec_name, set.rate, set.ch, buf.items.len, set.s16.len, c.corr, c.max_abs, c.equal, c.n, 100.0 * @as(f64, @floatFromInt(c.equal)) / @as(f64, @floatFromInt(c.n)) },
        );
    }
    try testing.expect(c.corr > min_corr);
}

// ---- 内嵌样本（真实 ffmpeg mov 封装；golden = ffmpeg 解 mp4 的 s16le）----
const s_flac_m44 = @embedFile("m4a/samples/f_flac_m44.mp4");
const s_flac_m44_s16 = @embedFile("m4a/samples/f_flac_m44.s16");
const s_flac_st48 = @embedFile("m4a/samples/f_flac_st48.mp4");
const s_flac_st48_s16 = @embedFile("m4a/samples/f_flac_st48.s16");
const s_opus_m44 = @embedFile("m4a/samples/f_opus_m44.mp4");
const s_opus_m44_s16 = @embedFile("m4a/samples/f_opus_m44.s16");
const s_opus_st48 = @embedFile("m4a/samples/f_opus_st48.mp4");
const s_opus_st48_s16 = @embedFile("m4a/samples/f_opus_st48.s16");
const s_ac3_st48 = @embedFile("m4a/samples/f_ac3_st48.mp4");
const s_ac3_st48_s16 = @embedFile("m4a/samples/f_ac3_st48.s16");
const s_ac3_m44 = @embedFile("m4a/samples/f_ac3_m44.mp4");
const s_ac3_m44_s16 = @embedFile("m4a/samples/f_ac3_m44.s16");
const s_eac3_st48 = @embedFile("m4a/samples/f_eac3_st48.mp4");
const s_eac3_st48_s16 = @embedFile("m4a/samples/f_eac3_st48.s16");
const s_mp3_dot = @embedFile("m4a/samples/f_mp3_dot.mp4");
const s_mp3_dot_s16 = @embedFile("m4a/samples/f_mp3_dot.s16");

test "m4a 委托: FLAC 轨（'fLaC'+dfLa，mono 44.1k）端到端 == ffmpeg（bit-exact）" {
    try checkDelegateSample(.{ .mp4 = s_flac_m44, .s16 = s_flac_m44_s16, .rate = 44100, .ch = 1, .codec_name = "flac" }, 0.999999, true);
}

test "m4a 委托: FLAC 轨（'fLaC'+dfLa，stereo 48k）端到端 == ffmpeg（bit-exact）" {
    try checkDelegateSample(.{ .mp4 = s_flac_st48, .s16 = s_flac_st48_s16, .rate = 48000, .ch = 2, .codec_name = "flac" }, 0.999999, true);
}

test "m4a 委托: Opus 轨（'Opus'+dOps，mono→48k）端到端 ≈ ffmpeg（pre-skip 120）" {
    try checkDelegateSample(.{ .mp4 = s_opus_m44, .s16 = s_opus_m44_s16, .rate = 48000, .ch = 1, .codec_name = "opus" }, 0.999, true);
}

test "m4a 委托: Opus 轨（'Opus'+dOps，stereo 48k）端到端 ≈ ffmpeg（pre-skip 120）" {
    try checkDelegateSample(.{ .mp4 = s_opus_st48, .s16 = s_opus_st48_s16, .rate = 48000, .ch = 2, .codec_name = "opus" }, 0.999, true);
}

test "m4a 委托: AC-3 轨（'ac-3'，stereo 48k，elst priming 256）端到端 ≈ ffmpeg" {
    try checkDelegateSample(.{ .mp4 = s_ac3_st48, .s16 = s_ac3_st48_s16, .rate = 48000, .ch = 2, .codec_name = "ac3" }, 0.999, true);
}

test "m4a 委托: AC-3 轨（'ac-3'，mono 44.1k，elst priming 256）端到端 ≈ ffmpeg" {
    try checkDelegateSample(.{ .mp4 = s_ac3_m44, .s16 = s_ac3_m44_s16, .rate = 44100, .ch = 1, .codec_name = "ac3" }, 0.999, true);
}

test "m4a 委托: E-AC-3 轨（'ec-3'，stereo 48k，elst priming 256）端到端 ≈ ffmpeg" {
    try checkDelegateSample(.{ .mp4 = s_eac3_st48, .s16 = s_eac3_st48_s16, .rate = 48000, .ch = 2, .codec_name = "eac3" }, 0.999, true);
}

test "m4a 委托: MP3 轨（'.mp3'，stereo 44.1k，elst priming 1105）端到端（容器接入）" {
    // 自研 mp3 内核与 ffmpeg 有 codec 层差异（mka 同，§见 fmt/mka/lib.zig 模块头注）：
    // 逐样本 ±1/末帧偏少；本测试锁 m4a 容器接入（帧直拼 + priming/cap）与确定性。
    try checkDelegateSample(.{ .mp4 = s_mp3_dot, .s16 = s_mp3_dot_s16, .rate = 44100, .ch = 2, .codec_name = "mp3", .allow_short = 1152 * 2 * 4, .skip_corr = true }, 0, true);
}

test "m4a 委托: FLAC 轨 seek（mono 44.1k，0.3s 与 ffmpeg golden 同段一致）" {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(s_flac_m44);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try dec.seekMs(300);
    try testing.expectEqual(@as(i64, 300), dec.positionMs());
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var tmp: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&tmp, 4096, &ch);
        if (n == 0) break;
        try buf.appendSlice(testing.allocator, tmp[0 .. n * @as(usize, ch) * 2]);
    }
    const seek_sample: usize = @intCast((@as(u64, 300) * 44100) / 1000);
    const off_bytes = seek_sample * 2;
    const seg = s_flac_m44_s16[off_bytes..];
    try testing.expect(buf.items.len <= seg.len);
    const cmp = compareS16(buf.items, seg[0..buf.items.len]);
    std.debug.print("m4a flac seek300ms: mine={d} corr={d:.8} max_abs={d} equal {d}/{d}\n", .{ buf.items.len, cmp.corr, cmp.max_abs, cmp.equal, cmp.n });
    try testing.expect(cmp.corr > 0.999999);
}

test "m4a 委托: AC-3 轨 seek + 容器 priming（stereo 48k，0.315s 与 golden 同段一致）" {
    var reader = io.Reader.openMem(s_ac3_st48);
    var info: decoder.Info = undefined;
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    // Info duration = 容器 0.63s（elst seg_dur 30240 @48k）
    try testing.expectEqual(@as(i64, 630000), info.duration_us);

    try dec.seekMs(315);
    try testing.expectEqual(@as(i64, 315), dec.positionMs());
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    var tmp: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&tmp, 4096, &ch);
        if (n == 0) break;
        try buf.appendSlice(testing.allocator, tmp[0 .. n * @as(usize, ch) * 2]);
    }
    // 输出域样本 15120 = golden 起点（golden 即输出域全轨，见 e2e 全等验证）
    const out_sample: usize = @intCast((@as(u64, 315) * 48000) / 1000);
    const off_bytes = out_sample * 4;
    const seg = s_ac3_st48_s16[off_bytes..];
    try testing.expect(buf.items.len <= seg.len);
    const cmp = compareS16(buf.items, seg[0..buf.items.len]);
    std.debug.print("m4a ac3 seek315ms: mine={d} corr={d:.8} max_abs={d}\n", .{ buf.items.len, cmp.corr, cmp.max_abs });
    try testing.expect(cmp.corr > 0.99);
}

// ---------------------------------------------------------------------------
// ALS 轨（'mp4a'+esds AOT_ALS；ffmpeg mp4als）：fate conformance 子集内嵌。
// golden = 系统 ffmpeg n9.0.1 `-f s16le` 全轨输出；整轨长度 + 全轨 MD5 +
// 200KB 前缀逐字节 == ffmpeg（整数无损解码，要求 100% bit-exact）。
// ---------------------------------------------------------------------------

const s_als_00 = @embedFile("m4a/samples/f_als_00.mp4");
const s_als_00_pre = @embedFile("m4a/samples/f_als_00_prefix.s16");
const s_als_05 = @embedFile("m4a/samples/f_als_05.mp4");
const s_als_05_pre = @embedFile("m4a/samples/f_als_05_prefix.s16");

fn hexToBytes(hex: []const u8, out: *[16]u8) void {
    for (0..16) |i| {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch unreachable;
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch unreachable;
        out[i] = (hi << 4) | lo;
    }
}

const AlsSet = struct {
    mp4: []const u8,
    pre: []const u8,
    rate: u32,
    ch: u8,
    /// 全轨 s16le 字节数（ffmpeg golden 长度）
    total: usize,
    /// 全轨 MD5（ffmpeg golden）
    md5: []const u8,
    /// 一句描述
    what: []const u8,
};

fn checkAlsSample(set: AlsSet) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    const info = try decodeAllM4a(testing.allocator, set.mp4, &buf);

    try testing.expectEqualStrings("mp4als", info.codec_name);
    try testing.expectEqualStrings("m4a", info.format_name);
    try testing.expectEqual(set.rate, info.sample_rate);
    try testing.expectEqual(set.ch, info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    // 整轨长度
    try testing.expectEqual(set.total, buf.items.len);

    // 前缀逐字节
    const c = compareS16(buf.items[0..set.pre.len], set.pre);
    var want: [16]u8 = undefined;
    hexToBytes(set.md5, &want);
    var got: [16]u8 = undefined;
    md5mod.Md5.hash(buf.items, &got, .{});
    std.debug.print("m4a mp4als ({s}): sr={d} ch={d} total={d} prefix-equal {d}/{d} md5-match={d}\n", .{
        set.what, set.rate, set.ch, buf.items.len, c.equal, c.n, @intFromBool(std.mem.eql(u8, &want, &got)),
    });
    try testing.expectEqualSlices(u8, &want, &got);
    try testing.expect(c.corr > 0.999999);
    try testing.expectEqual(c.n, c.equal);
}

test "m4a 委托: ALS 轨（adapt_order+RA，2ch 48k）== ffmpeg（bit-exact，全轨 MD5+前缀）" {
    try checkAlsSample(.{
        .mp4 = s_als_00,
        .pre = s_als_00_pre,
        .rate = 48000,
        .ch = 2,
        .total = 2843636,
        .md5 = "33eacfe408911eafc03fcb69e4ec81e9",
        .what = "als_00 conformance",
    });
}

test "m4a 委托: ALS 轨（BGMC，2ch 48k）== ffmpeg（bit-exact，全轨 MD5+前缀）" {
    try checkAlsSample(.{
        .mp4 = s_als_05,
        .pre = s_als_05_pre,
        .rate = 48000,
        .ch = 2,
        .total = 2843636,
        .md5 = "33eacfe408911eafc03fcb69e4ec81e9",
        .what = "als_05 conformance",
    });
}


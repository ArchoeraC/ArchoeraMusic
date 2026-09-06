// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 格式探测（docs/audio-kernel-zig.md §7）
//!
//! 通过魔数嗅探识别容器/编码，返回 `Format`。探测窗口 64 字节；
//! 遇 `ID3` 前导时解析并跳过 ID3v2 头再判定（FLAC / MP3 / DSF 消歧）；
//! 标签超出窗口时 seek 到标签后判定（保持位置不变）。
//!
//! 开关语义（§3.6）：
//!   - `formats` 编译期常量集合，T0 默认开（wav/flac/mp3/ogg/opus）；
//!     m4a 随 ALAC 验收后接管、wv 与 ape 随各自验收后接管（§17.2），其余默认关；
//!   - `probe` 对**未开启**格式直接返回 error.UnsupportedFormat（不误报"已支持"），
//!     由引擎经 FFI 事件上报，并回退 FFmpeg 主后端（§8.3）；
//!   - 纯函数 `identify` 不检查开关，供单测与调试（裸识别能力）。

const std = @import("std");
const Error = @import("error.zig").Error;
const io = @import("io.zig");

/// 探测窗口（设计稿 §7：前 64 字节）
pub const probe_window = 64;

/// 识别出的格式（与 §7 魔数表一一对应；`.unknown` 表示无法识别）
pub const Format = enum {
    ogg_opus,
    ogg_vorbis,
    ogg_flac, // Ogg 容器内 FLAC 流（fmt/oggflac.zig）
    ogg_speex, // Ogg 容器内 Speex 流（fmt/spx/，NB/WB/UWB + VBR）
    flac,
    wav, // WAV / RIFX / RF64 / W64 / AIFF / CAF / AU（未压缩 PCM 家族，fmt/wav/）
    mp3,
    m4a, // MP4/M4A 容器（内 codec 由 fmt/m4a.zig 判定）
    aac, // ADTS 裸流
    latm, // LOAS/LATM 音频传输流（AAC LATM，.latm/.loas，fmt/latm.zig）
    ape,
    wv,
    shn, // Shorten（.shn，整数无损；fmt/shn/）
    tak, // TAK（Tom's lossless Audio Kompressor，.tak；fmt/tak/）
    dsd, // DSF / DFF
    amr,
    amrwb, // AMR-WB（G.722.2，16kHz；`#!AMR-WB\n` 裸流，kernel/fmt/amrwb）
    ac3, // AC-3 / E-AC-3（Dolby Digital）
    mlp, // MLP（Meridian Lossless Packing）
    truehd, // Dolby TrueHD
    wma, // WMA（ASF 容器，wmav1/v2）
    dts, // DTS（DCA Coherent Acoustics）core 16-bit 子流（阶段一 probe 识别）
    mka, // Matroska 纯音频容器（.mka；EBML 0x1A45DFA3 + DocType matroska）
    mpc, // Musepack（MPCK = SV8 / MP+ = SV7）
    tta, // TTA（True Audio，.tta，无损；TTA1 头，fmt/tta）
    unknown,
};

/// 格式特性开关（§3.6 原文默认值）。probe 对未开启格式判 unsupported。
pub const formats = .{
    .wav = true, // T0 自研
    .flac = true, // T0 自研
    .mp3 = true, // T0（dr_mp3）
    .ogg = true, // T0 自研解复用
    .opus = true, // T0（vendored libopus）
    .m4a = true, // ALAC 已验收接管（bit-exact 全绿）；AAC 轨经 fmt/m4a 判 UnsupportedFormat 回退 FFmpeg
    .aac = true, // ADTS 裸流（AAC 自研解码已验收，§9.5/§17.2）
    .latm = true, // LOAS/LATM 音频传输流（AAC-LC 自研解码 + LATM 传输层已验收，§9.5）
    .alac = false, // Phase D（容器内 codec 标记；随 m4a 开关生效）
    .wv = true, // WavPack 已验收接管（4 样本 bit-exact 全绿，§9.9）
    .ape = true, // APE 已验收接管（bit-exact 全绿，§9.10 / §17.2）
    .dsd = true, // T1 自研 DSF/DFF→PCM（§9.11）
    .amr = true, // T1 vendored OpenCORE AMR（§9.13）
    .amrwb = true, // AMR-WB 自研浮点解码（§9.x：amrwbdec 路径逐句移植）
    .ac3 = true, // Dolby Digital（AC-3）自研
    .mlp = true, // MLP / TrueHD 自研
    .truehd = true,
    .vorbis = true, // T0（vendored stb_vorbis，§9.12）
    .wma = true, // WMA(ASF)：wmav1/v2 解码核心已完成（corr 1.0），接入可播
    .dts = true, // DTS core（.dts/.dca）定点解码完成（bitexact 对齐 ffmpeg 定点路径）
    .mka = true, // Matroska 纯音频容器解复用（fmt/mka：EBML → 音轨 → 复用既有 codec）
    .mpc = true, // Musepack：SV8+SV7 均已验收接管（bit-exact 对齐 ffmpeg mpc8/mpc7）
    .tta = true, // TTA：已验收接管（bit-exact 对齐 ffmpeg native tta，§fmt/tta）
    .spx = true, // Ogg-Speex：已验收接管（bit-exact 对齐 ffmpeg native speex，NB/WB/UWB/VBR）
    .shn = true, // Shorten：已验收接管（bit-exact 对齐 ffmpeg native shorten）
    .tak = true, // TAK：已验收接管（bit-exact 对齐 ffmpeg native tak）
};

/// 探测：读取前 64 字节（自动跳过 ID3v2 头）做魔数嗅探。
/// ID3v2 标签超出窗口时 seek 到标签后判定 payload（保持位置不变，probe 不消耗）。
/// 未识别或格式未开启 → error.UnsupportedFormat；IO/中断错误原样透传。
pub fn probe(reader: *io.Reader) Error!Format {
    var head: [probe_window]u8 = undefined;
    const n = try reader.peek(&head);
    var fmt = identify(head[0..n]);
    // ID3v2 标签超出探测窗口：跳过头嗅探 payload（如带 ID3 前导的 FLAC / ADTS / MP3）
    if ((fmt == .unknown or fmt == .mp3) and n >= 10 and std.mem.eql(u8, head[0..3], "ID3")) {
        const skip = 10 + syncsafe(head[6..10]);
        if (skip + 4 > n) {
            const old_pos = reader.pos;
            reader.seek(@intCast(skip), .start) catch return error.UnsupportedFormat;
            var rest: [probe_window]u8 = undefined;
            const m = reader.peek(&rest) catch 0;
            reader.seek(@intCast(old_pos), .start) catch {};
            if (m >= 4) {
                const after = identify(rest[0..m]);
                // 命中明确格式（含 ADTS/MP3/FLAC）→ 采纳；unknown 保持 mp3 兜底
                if (after != .unknown) fmt = after;
            }
        }
    }
    if (fmt == .unknown or !enabled(fmt)) return error.UnsupportedFormat;
    return fmt;
}

/// 该格式是否在当前特性开关下启用（§3.6）
pub fn enabled(fmt: Format) bool {
    return switch (fmt) {
        .wav => formats.wav,
        .flac => formats.flac,
        .mp3 => formats.mp3,
        .ogg_opus => formats.ogg and formats.opus,
        .ogg_vorbis => formats.ogg and formats.vorbis,
        .ogg_flac => formats.ogg and formats.flac,
        .ogg_speex => formats.ogg and formats.spx,
        // ADTS 为 AAC 裸流，独立开关（AAC 未接管，不随 m4a 误启）
        .m4a => formats.m4a,
        .aac => formats.aac,
        .latm => formats.latm,
        .ape => formats.ape,
        .wv => formats.wv,
        .shn => formats.shn,
        .tak => formats.tak,
        .dsd => formats.dsd,
        .amr => formats.amr,
        .amrwb => formats.amrwb,
        .ac3 => formats.ac3,
        .mlp => formats.mlp,
        .truehd => formats.truehd,
        .wma => formats.wma,
        .dts => formats.dts,
        .mka => formats.mka,
        .mpc => formats.mpc,
        .tta => formats.tta,
        .unknown => false,
    };
}

/// ASF Header Object GUID（30 26 B2 75 8E 66 CF 11 A6 D9 00 AA 00 62 CE 6C）
const asf_header_guid = [16]u8{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };

/// 裸识别（不检查开关）：魔数 → Format。
/// 输入不足 4 字节或无法匹配 → .unknown。
pub fn identify(head: []const u8) Format {
    if (head.len < 4) return .unknown;
    const mem = std.mem;

    if (mem.eql(u8, head[0..4], "fLaC")) return .flac;
    if (mem.eql(u8, head[0..4], "OggS")) return identifyOgg(head);

    // Matroska（.mka/.mkv/.webm）：EBML 魔数 + DocType matroska/webm（§7 表）
    if (head.len >= 4 and mem.eql(u8, head[0..4], "\x1A\x45\xDF\xA3")) {
        const window = head[0..head.len];
        if (std.mem.indexOf(u8, window, "matroska") != null or
            std.mem.indexOf(u8, window, "webm") != null) return .mka;
        return .unknown; // 其它 EBML DocType 非目标容器
    }

    // 未压缩 PCM 家族：Apple CAF（`caff` + 头）与 Sun AU（`.snd`）并入 .wav，
    // 由 fmt/wav/lib.zig 的容器内部分派解析（§7 表并入 .wav）
    if (mem.eql(u8, head[0..4], "caff")) return .wav;
    if (mem.eql(u8, head[0..4], ".snd")) return .wav;

    // RIFF 家族：WAV / RIFX / RF64 / W64 / AIFF（§7 表并入 .wav）
    if (mem.eql(u8, head[0..4], "RIFF") or
        mem.eql(u8, head[0..4], "RIFX") or
        mem.eql(u8, head[0..4], "RF64"))
    {
        if (head.len >= 12 and mem.eql(u8, head[8..12], "WAVE")) return .wav;
        return .unknown;
    }
    // Sony Wave64：riff GUID(16) + filesize(8) + wave GUID(16)，"wave" 文本在偏移 24
    if (head.len >= 28 and mem.eql(u8, head[0..4], "riff") and mem.eql(u8, head[24..28], "wave")) return .wav;
    // AIFF / AIFF-C（RIFF 变体；AIFF-C 含压缩类型，如 "ima4"）
    if (head.len >= 12 and mem.eql(u8, head[0..4], "FORM") and
        (mem.eql(u8, head[8..12], "AIFF") or mem.eql(u8, head[8..12], "AIFC"))) return .wav;

    // ID3 前导：解析/跳过 ID3v2 头后判定（MP3 或 DSF）
    if (head.len >= 3 and mem.eql(u8, head[0..3], "ID3")) return identifyAfterId3(head);

    // MPEG sync（0xFF Ex/Fx）→ ADTS 与 MP3 消歧（§7）
    if (isMpegSync(head)) return identifyMpegSync(head);

    // LOAS/LATM（AAC LATM 音频传输流，.latm/.loas）：24-bit 前缀 0x56E000
    // （11-bit 同步字 0x2B7 << 13）+ 13-bit audioMuxLengthBytes（≥ 4 载荷）。
    // 若窗口内含下一 LOAS 同步则一并校验（降误报）。
    if (head.len >= 3) {
        const hdr = (@as(u32, head[0]) << 16) | (@as(u32, head[1]) << 8) | head[2];
        if ((hdr & 0xFFE000) == 0x56E000 and (hdr & 0x1FFF) >= 4) {
            const len: usize = hdr & 0x1FFF;
            if (3 + len + 3 <= head.len) {
                const nxt = (@as(u32, head[3 + len]) << 16) | (@as(u32, head[4 + len]) << 8) | head[5 + len];
                if ((nxt & 0xFFE000) == 0x56E000) return .latm;
            } else {
                return .latm;
            }
        }
    }

    if (head.len >= 8 and mem.eql(u8, head[4..8], "ftyp")) return .m4a; // ISO-BMFF：box size + brand
    if (mem.eql(u8, head[0..4], "MAC ")) return .ape;
    if (mem.eql(u8, head[0..4], "wvpk")) return .wv;
    // Shorten：4 字节魔数 "ajkg"（0x616A6B67，fn bitstream 随后）
    if (head.len >= 4 and mem.eql(u8, head[0..4], "ajkg")) return .shn;
    // TAK：4 字节魔数 "tBaK"
    if (head.len >= 4 and mem.eql(u8, head[0..4], "tBaK")) return .tak;
    // Musepack：SV8 = "MPCK" chunk 流；SV7 = "MP+" + 0x07/0x17（libavformat mpc/mpc8）
    if (mem.eql(u8, head[0..4], "MPCK")) return .mpc;
    if (mem.eql(u8, head[0..3], "MP+")) {
        if (head.len >= 4 and (head[3] == 0x07 or head[3] == 0x17)) return .mpc;
        return .unknown;
    }
    // TTA（True Audio）：TTA1 头（22B，魔数即标识；container 层做字段校验）
    if (mem.eql(u8, head[0..4], "TTA1")) return .tta;
    if (mem.eql(u8, head[0..4], "DSD ")) return .dsd; // DSF 裸头
    if (head.len >= 2 and mem.eql(u8, head[0..2], "\x0b\x77")) return .ac3; // AC-3 / E-AC-3
    if (head.len >= 8 and (mem.eql(u8, head[0..4], "\xf8\x72\x6f\xba") or mem.eql(u8, head[4..8], "\xf8\x72\x6f\xba"))) return .truehd; // TrueHD 主同步（可位于帧内 buf+4）
    if (head.len >= 16 and mem.eql(u8, head[0..4], "FRM8") and mem.eql(u8, head[12..16], "DSD ")) return .dsd; // DFF
    // AMR-NB：`#!AMR\n` 全等；AMR-WB 为 `#!AMR-WB\n`（先判 WB，避免误标 NB）
    if (head.len >= 9 and mem.eql(u8, head[0..9], "#!AMR-WB\n")) return .amrwb;
    if (head.len >= 6 and mem.eql(u8, head[0..6], "#!AMR\n")) return .amr;

    // ASF（Advanced Systems Format，.wma/.asf）Header Object GUID：30 26 B2 75 8E 66 CF 11 A6 D9 …
    if (head.len >= 16 and mem.eql(u8, head[0..16], &asf_header_guid)) return .wma;

    // DTS（DCA Coherent Acoustics）core 子流 sync（四种文件字节形态）
    if (isDcaSync(head)) return .dts;
    // DTS-HD 容器（.dtshd，FATE dcadec-suite 等）：DTSHDHDR 魔数 + STRMDATA 载荷
    if (head.len >= 8 and mem.eql(u8, head[0..8], "DTSHDHDR")) return .dts;

    return .unknown;
}

/// DTS core sync 的四种文件形态（dca_syncwords.h）：
///   BE16 7F FE 80 01 / LE16 FE 7F 01 80 / 14-bit BE 1F FF E8 00 / LE FF 1F 00 E8
/// 14-bit 形态首字节 FF 不落入 MPEG sync（(FF & 0xE0)==0xE0 判据在上方已排除）。
fn isDcaSync(head: []const u8) bool {
    if (head.len < 4) return false;
    const w = std.mem.readInt(u32, head[0..4], .big);
    return w == 0x7FFE8001 or w == 0xFE7F0180 or
        w == 0x1FFFE800 or w == 0xFF1F00E8;
}

/// 判定 MPEG syncword（0xFF Ex/Fx）
fn isMpegSync(head: []const u8) bool {
    return head.len >= 2 and head[0] == 0xFF and (head[1] & 0xE0) == 0xE0;
}

/// MPEG sync 消歧：ADTS（AAC 裸流）layer 位为 00，MP3 为 01/10（Layer III/II）。
/// 依据 §7：「ADTS 校验 layer 位 + 帧长合法性」。
fn identifyMpegSync(head: []const u8) Format {
    if (head.len < 7) return .mp3;
    const layer: u8 = (head[1] >> 1) & 0x03;
    if (layer != 0) return .mp3;
    // ADTS 帧长：((b3 & 0x03) << 11) | (b4 << 3) | (b5 >> 5)
    const frame_len: usize = (@as(usize, head[3] & 0x03) << 11) | (@as(usize, head[4]) << 3) | (head[5] >> 5);
    // ADTS 帧头 7 字节，帧长必须 >= 7（保护位后最少 7）；MP3 帧长 24~1441 字节
    const valid_adts = frame_len >= 7;
    return if (valid_adts) .aac else .mp3;
}

/// Ogg 页首包 payload 判定 codec（OpusHead / vorbis ident）
fn identifyOgg(head: []const u8) Format {
    if (head.len < 28) return .unknown;
    const seg_count: usize = head[26];
    const payload_start = 27 + seg_count;
    if (head.len < payload_start + 7) return .unknown;
    if (std.mem.eql(u8, head[payload_start .. payload_start + 8], "OpusHead")) return .ogg_opus;
    // vorbis ident 包：0x01 'v' 'o' 'r' 'b' 'i' 's'
    if (head[payload_start] == 0x01 and
        std.mem.eql(u8, head[payload_start + 1 .. payload_start + 7], "vorbis"))
        return .ogg_vorbis;
    // Ogg-FLAC 映射头：0x7F "FLAC"（RFC 5334 / Ogg FLAC mapping）
    if (head[payload_start] == 0x7F and
        std.mem.eql(u8, head[payload_start + 1 .. payload_start + 5], "FLAC"))
        return .ogg_flac;
    // Speex ident 包：'s' 'p' 'e' 'e' 'x' 0x20 ×3（8 字节 "Speex   "）
    if (std.mem.eql(u8, head[payload_start .. payload_start + 8], "Speex   ")) return .ogg_speex;
    return .unknown;
}

/// ID3 前导：按 ID3v2 头计算标签大小并跳过，判定其后内容（FLAC / DSF / MP3）。
/// 标签后数据未落入窗口时按 MP3 处理（ID3 绝大多数为 MP3 前导；
/// probe 会对此场景 seek 兜底判定，见 probe）。
fn identifyAfterId3(head: []const u8) Format {
    if (head.len >= 10) {
        const tag_size = syncsafe(head[6..10]);
        const skip = 10 + tag_size;
        if (skip + 4 <= head.len) {
            const rest = head[skip..];
            if (std.mem.eql(u8, rest[0..4], "fLaC")) return .flac; // 带 ID3 前导的 FLAC
            if (std.mem.eql(u8, rest[0..4], "DSD ")) return .dsd; // DSF
            if (isMpegSync(rest)) return identifyMpegSync(rest);
            return .unknown;
        }
    }
    return .mp3;
}

/// 解析 ID3v2 syncsafe 整数（4 字节，每字节 7 位）
fn syncsafe(b: []const u8) usize {
    return (@as(usize, b[0]) << 21) | (@as(usize, b[1]) << 14) | (@as(usize, b[2]) << 7) | b[3];
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fmtBytes(comptime data: []const u8) Format {
    return identify(data);
}

test "identify: WAV 家族（WAV/RIFX/RF64/W64/AIFF）" {
    try testing.expectEqual(Format.wav, fmtBytes("RIFF\x24\x00\x00\x00WAVEfmt "));
    try testing.expectEqual(Format.wav, fmtBytes("RIFX\x24\x00\x00\x00WAVEfmt "));
    try testing.expectEqual(Format.wav, fmtBytes("RF64\x24\x00\x00\x00WAVEfmt "));
    // Sony Wave64：riff GUID(16) + filesize(8) + wave GUID(16)，"wave" 在偏移 24
    var w64 = [_]u8{0} ** 40;
    @memcpy(w64[0..4], "riff");
    w64[4] = 0x2E;
    w64[5] = 0x91;
    w64[6] = 0xCF;
    w64[7] = 0x11;
    @memcpy(w64[24..28], "wave");
    try testing.expectEqual(Format.wav, identify(&w64));
    try testing.expectEqual(Format.wav, fmtBytes("FORM\x24\x00\x00\x00AIFFCOMM"));
}

test "identify: CAF / AU（未压缩 PCM 家族）→ wav" {
    // Apple CAF：caff + version(1) + flags + desc
    try testing.expectEqual(Format.wav, fmtBytes("caff\x00\x01\x00\x00desc\x00\x00\x00\x00\x00\x00\x00\x20"));
    // Sun AU：.snd + 24B 头
    try testing.expectEqual(Format.wav, fmtBytes(".snd\x00\x00\x00\x20\x00\x00\x44\xe8\x00\x00\x00\x03\x00\x00\xac\x44\x00\x00\x00\x01"));
    // 不足 / 变体不误报
    try testing.expectEqual(Format.unknown, fmtBytes("caf"));
    try testing.expectEqual(Format.unknown, fmtBytes(".sn"));
    try testing.expectEqual(Format.unknown, fmtBytes("cafe"));
}

test "probe: CAF / AU 开启 → wav" {
    var r = io.Reader.openMem("caff\x00\x01\x00\x00desc");
    try testing.expectEqual(Format.wav, try probe(&r));
    var r2 = io.Reader.openMem(".snd\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x03");
    try testing.expectEqual(Format.wav, try probe(&r2));
}

test "identify: FLAC" {
    try testing.expectEqual(Format.flac, fmtBytes("fLaC\x00\x00\x00\x22\x10\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
}

test "identify: 带 ID3 前导的 FLAC（标签在窗口内）" {
    var head: [24]u8 = undefined;
    @memcpy(head[0..3], "ID3");
    head[3] = 0x04; // ID3v2.4
    head[4] = 0x00;
    head[5] = 0x00;
    head[6] = 0x00;
    head[7] = 0x00;
    head[8] = 0x00;
    head[9] = 0x04; // synchsafe size 4
    @memcpy(head[10..14], "ABCD"); // 标签内容
    @memcpy(head[14..18], "fLaC"); // 标签后的 FLAC 魔数
    try testing.expectEqual(Format.flac, identify(&head));
}

test "probe: ID3v2 标签超出窗口 → seek 判定 FLAC（位置不消耗）" {
    const junk = [_]u8{0x41} ** 64;
    var file = std.ArrayList(u8).empty;
    defer file.deinit(testing.allocator);
    try file.appendSlice(testing.allocator, "ID3");
    try file.appendSlice(testing.allocator, &.{ 0x04, 0x00, 0x00 }); // ID3v2.4 flags 0
    try file.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x40 }); // synchsafe size 64
    try file.appendSlice(testing.allocator, &junk);
    try file.appendSlice(testing.allocator, "fLaC\x00\x00\x00\x22");
    var r = io.Reader.openMem(file.items);
    try testing.expectEqual(Format.flac, try probe(&r));
    // probe 不消耗位置
    try testing.expectEqual(@as(u64, 0), r.pos);
}

test "identify: Ogg（Opus / Vorbis）" {
    // 构造 Ogg 页：27 字节头 + segment table + payload
    var ogg = [_]u8{0} ** 64;
    @memcpy(ogg[0..4], "OggS");
    ogg[26] = 1; // 1 个 segment
    @memcpy(ogg[28..36], "OpusHead");
    try testing.expectEqual(Format.ogg_opus, identify(&ogg));

    ogg[28] = 0x01;
    @memcpy(ogg[29..35], "vorbis");
    try testing.expectEqual(Format.ogg_vorbis, identify(&ogg));
}

test "identify: MP3（裸 sync / ID3 前导）" {
    // MP3 帧头：0xFF 0xFB（Layer III，MPEG1）
    try testing.expectEqual(Format.mp3, fmtBytes("\xFF\xFB\x90\x64\x00\x00\x00\x00"));
    // ID3v2 前导（tag size = 0）+ MPEG sync
    try testing.expectEqual(Format.mp3, fmtBytes("ID3\x04\x00\x00\x00\x00\x00\x00\xFF\xFB\x90\x64"));
    // ID3v2.3 前导 + 17 字节标签 + sync（数组显式构造，避免手数转义出错）
    var head: [32]u8 = undefined;
    @memcpy(head[0..3], "ID3");
    head[3] = 0x03; // ID3v2.3
    head[4] = 0x00; // revision
    head[5] = 0x00; // flags
    head[6] = 0x00; // syncsafe 大小 = 0x11 = 17
    head[7] = 0x00;
    head[8] = 0x00;
    head[9] = 0x11;
    @memset(head[10..27], 0); // 17 字节标签内容
    @memcpy(head[27..31], "\xFF\xFB\x90\x64"); // 标签后的 MPEG sync
    try testing.expectEqual(Format.mp3, identify(&head));
}

test "identify: ADTS（AAC 裸流）与 MP3 消歧" {
    // ADTS 帧头（7 字节）：0xFF 0xF1（layer=00, MPEG-4）
    try testing.expectEqual(Format.aac, fmtBytes("\xFF\xF1\x50\x80\x01\x1F\xFC\x00\x00\x00"));
    // 0xFF 0xF9（MPEG-2 ADTS）
    try testing.expectEqual(Format.aac, fmtBytes("\xFF\xF9\x50\x80\x01\x1F\xFC"));
}

test "identify: LOAS/LATM（0x56E000 前缀 + audioMuxLengthBytes）" {
    // 3 字节 LOAS 头：0x2B7<<13 | 0x0140 → 56 E1 40（整帧 323 字节，超窗口 → 单头判定）
    try testing.expectEqual(Format.latm, fmtBytes("\x56\xE1\x40\x20\x00\x12"));
    // 长度过小（<4）拒绝
    try testing.expectEqual(Format.unknown, fmtBytes("\x56\xE0\x00\x00\x00"));
    // 同步字错位拒绝
    try testing.expectEqual(Format.unknown, fmtBytes("\x57\xE1\x40\x00"));
    // 两帧均落在窗口内：len=5 → 整帧 8 字节，第二帧头在偏移 8；均同步 → latm
    try testing.expectEqual(Format.latm, fmtBytes("\x56\xE0\x05\x00\x00\x00\x00\x00\x56\xE0\x05\x00"));
    // 第一帧同步、后续非同步（帧长落在窗口内）→ 不判 latm（降误报）
    try testing.expectEqual(Format.unknown, fmtBytes("\x56\xE0\x05\x00\x00\x00\x00\x00\x47\x41\x52\x42"));
}

test "probe: latm 开关已开 → 识别（解码已接入 fmt/latm）" {
    var r = io.Reader.openMem("\x56\xE1\x40\x20\x00\x12\x08\x1f");
    try testing.expectEqual(Format.latm, probe(&r));
}

test "identify: m4a/ape/wv/dsd/dff/dsf/amr" {
    try testing.expectEqual(Format.m4a, fmtBytes("\x00\x00\x00\x18ftypM4A "));
    try testing.expectEqual(Format.ape, fmtBytes("MAC \x00\x00\x00\x00"));
    try testing.expectEqual(Format.wv, fmtBytes("wvpk\x00\x00\x00\x00"));
    try testing.expectEqual(Format.dsd, fmtBytes("DSD \x00\x00\x00\x00"));
    try testing.expectEqual(Format.dsd, fmtBytes("FRM8\x00\x00\x00\x00\x00\x00\x00\x00DSD "));
    try testing.expectEqual(Format.dsd, fmtBytes("ID3\x04\x00\x00\x00\x00\x00\x00DSD "));
    try testing.expectEqual(Format.amr, fmtBytes("#!AMR\n"));
    try testing.expectEqual(Format.amrwb, fmtBytes("#!AMR-WB\n"));
    try testing.expectEqual(Format.unknown, fmtBytes("#!AMR-W")); // 截断不误报
    try testing.expectEqual(Format.wma, fmtBytes("\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c")); // ASF（.wma）
}

test "identify: Musepack SV8（MPCK）与 SV7（MP+ 07/17）" {
    try testing.expectEqual(Format.mpc, fmtBytes("MPCKSH\x0e\xf7\x65\xa0\xdb\x08"));
    try testing.expectEqual(Format.mpc, fmtBytes("MP+\x07\xc8\x01\x00\x00"));
    try testing.expectEqual(Format.mpc, fmtBytes("MP+\x17\x00\x00\x00\x00"));
    // 变体不误报
    try testing.expectEqual(Format.unknown, fmtBytes("MP+"));
    try testing.expectEqual(Format.unknown, fmtBytes("MP+\x08"));
    try testing.expectEqual(Format.unknown, fmtBytes("MPCX"));
}

test "probe: mpc 开启 → 识别（SV8 解码已接入；SV7 由 open 回退 FFmpeg）" {
    var r = io.Reader.openMem("MPCKSH\x0e\xf7\x65\xa0\xdb\x08\x9f\xff\x75\x00");
    try testing.expectEqual(Format.mpc, probe(&r));
    var r7 = io.Reader.openMem("MP+\x07\xc8\x01\x00\x00");
    try testing.expectEqual(Format.mpc, probe(&r7));
}

test "identify: TTA（TTA1 头）" {
    try testing.expectEqual(Format.tta, fmtBytes("TTA1\x01\x00\x02\x00\x10\x00\x44\xac\x00\x00"));
    try testing.expectEqual(Format.tta, fmtBytes("TTA1\x01\x00\x01\x00\x10\x00\x44\xac\x00\x00\xf5\xff\x07\x00"));
    // 不足 / 变体不误报
    try testing.expectEqual(Format.unknown, fmtBytes("TTA"));
    try testing.expectEqual(Format.unknown, fmtBytes("TTA2"));
}

test "probe: tta 开启 → 识别（fmt/tta 已接入）" {
    var r = io.Reader.openMem("TTA1\x01\x00\x02\x00\x10\x00\x44\xac\x00\x00\xf5\xff\x07\x00\x94\x3d\xef\x0f");
    try testing.expectEqual(Format.tta, probe(&r));
    try testing.expectEqual(@as(u64, 0), r.pos);
}

test "identify: DTS core sync 四种形态" {    // BE16（ffmpeg dca 编码器输出）：7F FE 80 01
    try testing.expectEqual(Format.dts, fmtBytes("\x7F\xFE\x80\x01\xFC\x3C\x00\x00"));
    // LE16（每 16-bit 字内字节交换）：FE 7F 01 80
    try testing.expectEqual(Format.dts, fmtBytes("\xFE\x7F\x01\x80\x3C\xFC\x00\x00"));
    // 14-bit 打包（旧式；仅识别不解析）
    try testing.expectEqual(Format.dts, fmtBytes("\x1F\xFF\xE8\x00\x00\x00\x00\x00"));
    try testing.expectEqual(Format.dts, fmtBytes("\xFF\x1F\x00\xE8\x00\x00\x00\x00"));
    // 非 DTS 不误报
    try testing.expectEqual(Format.unknown, fmtBytes("\x7F\xFE\x80\x02"));
}

test "probe: DTS 开关已开 → 识别（解码已接入）" {
    // formats.dts = true（core 解码已完成接入）：probe 识别 .dts
    var r = io.Reader.openMem("\x7F\xFE\x80\x01\xFC\x3C\x00\x00");
    try testing.expectEqual(Format.dts, probe(&r));
    // .dtshd 容器（DTSHDHDR 魔数）→ 同一 Format.dts（解码器内按载荷分派 core+XLL）
    var hd = io.Reader.openMem("DTSHDHDR");
    try testing.expectEqual(Format.dts, probe(&hd));
}

test "identify: Matroska（.mka）EBML + DocType" {
    // EBML 头魔数 + DocType "matroska"（probe_window=64 内含 DocType）
    var head: [64]u8 = [_]u8{0} ** 64;
    @memcpy(head[0..4], "\x1A\x45\xDF\xA3");
    // 在窗口内放置 DocType 元素：0x42 0x82 0x88 "matroska"（offset 0x15 附近）
    const doc = "matroska";
    @memcpy(head[0x15..][0..2], &[_]u8{ 0x42, 0x82 });
    head[0x15 + 2] = @intCast(doc.len);
    @memcpy(head[0x15 + 3 ..][0..doc.len], doc);
    try testing.expectEqual(Format.mka, identify(&head));
    try testing.expectEqual(Format.mka, fmtBytes("\x1A\x45\xDF\xA3\xA3\x42\x82\x88matroska"));
    // 其它 EBML DocType（非 matroska/webm）→ unknown
    try testing.expectEqual(Format.unknown, fmtBytes("\x1A\x45\xDF\xA3\xA3\x42\x82\x83abc"));
}

test "probe: mka 开启 → 识别（fmt/mka 已接入）" {
    var head: [64]u8 = [_]u8{0} ** 64;
    @memcpy(head[0..4], "\x1A\x45\xDF\xA3");
    const doc = "matroska";
    @memcpy(head[0x15..][0..2], &[_]u8{ 0x42, 0x82 });
    head[0x15 + 2] = @intCast(doc.len);
    @memcpy(head[0x15 + 3 ..][0..doc.len], doc);
    var r = io.Reader.openMem(head[0..]);
    try testing.expectEqual(Format.mka, probe(&r));
    try testing.expectEqual(@as(u64, 0), r.pos);
}

test "probe: abort 透传 Aborted（mka 输入）" {
    var head: [64]u8 = [_]u8{0} ** 64;
    @memcpy(head[0..4], "\x1A\x45\xDF\xA3");
    const doc = "matroska";
    @memcpy(head[0x15..][0..2], &[_]u8{ 0x42, 0x82 });
    head[0x15 + 2] = @intCast(doc.len);
    @memcpy(head[0x15 + 3 ..][0..doc.len], doc);
    var r = io.Reader.openMem(head[0..]);
    r.abort();
    try testing.expectError(error.Aborted, probe(&r));
}

test "identify: 未知 / 不足" {
    try testing.expectEqual(Format.unknown, fmtBytes(""));
    try testing.expectEqual(Format.unknown, fmtBytes("abc"));
    try testing.expectEqual(Format.unknown, fmtBytes("RIFF\x24\x00\x00\x00XXXX"));
}

test "probe: 开关语义（wav/m4a/aac/dsd 开）" {
    // wav：T0 默认开 → 返回 wav
    var r = io.Reader.openMem("RIFF\x24\x00\x00\x00WAVEfmt ");
    try testing.expectEqual(Format.wav, try probe(&r));

    // m4a：ALAC 已验收接管 → 返回 m4a
    var r1 = io.Reader.openMem("\x00\x00\x00\x18ftypM4A ");
    try testing.expectEqual(Format.m4a, try probe(&r1));

    // ADTS：aac 已验收接管 → 返回 aac（§9.5/§17.2）
    var r2 = io.Reader.openMem("\xFF\xF1\x50\x80\x01\x1F\xFC");
    try testing.expectEqual(Format.aac, try probe(&r2));

    // DSF：dsd 已接管（§9.11）→ 返回 dsd
    var r3 = io.Reader.openMem("DSD \x00\x00\x00\x00");
    try testing.expectEqual(Format.dsd, try probe(&r3));

    // 未知 → UnsupportedFormat
    var r4 = io.Reader.openMem("GARBAGE-DATA");
    try testing.expectError(error.UnsupportedFormat, probe(&r4));
}

test "probe: abort 透传 Aborted" {
    var r = io.Reader.openMem("RIFF\x24\x00\x00\x00WAVEfmt ");
    r.abort();
    try testing.expectError(error.Aborted, probe(&r));
}

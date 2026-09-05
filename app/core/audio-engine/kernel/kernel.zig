//! archoera_kernel — 自研音频解码内核（FFmpeg 渐进替换）
//!
//! 定位（docs/audio-kernel-zig.md v3）：
//!   FFmpeg 保持默认主引擎；本内核按格式逐项验收后接管解码。
//!   C 壳（audio-engine/src/*.c）通过 kernel_bridge.h（zk_* C ABI）调用本内核，
//!   Dart FFI 层零改动。
//!
//! 文件组织（后续步骤逐步引入）：
//!   error.zig     —— 统一错误类型与错误码 ↔ zk_* 状态码映射（e2）
//!   io.zig        —— 只读字节流 Reader 抽象（内存 / 文件 / 自定义 IO，e2）
//!   probe.zig     —— 魔数嗅探：识别容器/编码格式（e2）
//!   decoder.zig   —— 统一解码接口 + 格式工厂（e3）
//!   fmt/wav/      —— 自研 WAV 家族（RIFF/RIFX/RF64/W64/AIFF + Apple CAF + Sun AU，
//!                    未压缩 PCM 家族，e3，多模块：
//!                    chunk.zig 容器帧层 / decl.zig 格式声明 / g711.zig 编码）
//!   根文件         —— 聚合子模块 + 版本常量（本文件）

const std = @import("std");

pub const err = @import("error.zig");
pub const io = @import("io.zig");
pub const probe = @import("probe.zig");
pub const decoder = @import("decoder.zig");
pub const gsm = @import("fmt/wav/gsm.zig");
pub const mace = @import("fmt/wav/mace.zig");
pub const wav = @import("fmt/wav/lib.zig");
pub const convert = @import("pcm/convert.zig");
pub const engine = @import("engine.zig");

/// 内核版本（语义化版本，与 build.zig.zon 保持同步）
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

/// 内核版本字符串（"major.minor.patch"），供 C ABI 的 zk_version 查询使用
pub const version_string = "0.1.0";

// ---------------------------------------------------------------------------
// C ABI 桥接（docs/audio-kernel-zig.md §16.1，头契约：include/kernel_bridge.h）
// ---------------------------------------------------------------------------

/// 打开解码器。成功返回 `*engine.Engine`（C 侧 `ZkDecoder`）；
/// 失败返回 null 并写 errbuf（errbuf[0..4] = LE 状态码，其后 NUL 终止诊断消息）。
export fn zk_decoder_open(
    path: [*:0]const u8,
    info: *engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: c_int,
) ?*engine.Engine {
    return engine.zkOpen(path, info, errbuf, errbuf_size);
}

/// 解码最多 max_frames 帧 float32 交错到 out。
/// 返回 >=0 帧数（0 = EOF）；错误返回负值（-err.Status，见 include/kernel_bridge.h）。
export fn zk_decoder_read(
    d: *engine.Engine,
    out: [*]f32,
    max_frames: usize,
    out_channels: *c_int,
) isize {
    return engine.zkRead(d, out, max_frames, out_channels);
}

/// 跳转毫秒位置；0 = 成功，非 0 = 稳定状态码。
export fn zk_decoder_seek_ms(d: *engine.Engine, ms: i64) c_int {
    return engine.zkSeekMs(d, ms);
}

/// 当前播放位置（毫秒，自文件开头计）。
export fn zk_decoder_position_ms(d: *engine.Engine) i64 {
    return engine.zkPositionMs(d);
}

/// 释放解码会话（含底层文件句柄与全部缓冲）；d 为 NULL 时为空操作（头契约）。
export fn zk_decoder_close(d: ?*engine.Engine) void {
    if (d) |e| engine.zkClose(e);
}

test {
    // 聚合本文件与全部子模块的测试（decoder/fmt 随 e3 引入）
    std.testing.refAllDecls(@This());
    _ = @import("error.zig");
    _ = @import("io.zig");
    _ = @import("probe.zig");
    _ = @import("decoder.zig");
    _ = @import("fmt/wav/gsm.zig");
    _ = @import("fmt/wav/mace.zig");
    _ = @import("fmt/wav/lib.zig");
    _ = @import("fmt/flac/crc.zig");
    _ = @import("fmt/flac/bitreader.zig");
    _ = @import("fmt/flac/streaminfo.zig");
    _ = @import("fmt/flac/frame.zig");
    _ = @import("fmt/flac/residual.zig");
    _ = @import("fmt/flac/subframe.zig");
    _ = @import("fmt/flac/lib.zig");
    _ = @import("fmt/alac/bitreader.zig");
    _ = @import("fmt/alac/lib.zig");
    _ = @import("fmt/m4a.zig");
    _ = @import("fmt/als/core.zig");
    _ = @import("fmt/als/tables.zig");
    _ = @import("fmt/als/lib.zig");
    _ = @import("fmt/mp3/layer12.zig");
    _ = @import("fmt/mp3/layer3_tables.zig");
    _ = @import("fmt/mp3/huffman_tables.zig");
    _ = @import("fmt/mp3/header.zig");
    _ = @import("fmt/mp3/bitreader.zig");
    _ = @import("fmt/mp3/id3.zig");
    _ = @import("fmt/aac/bitreader.zig");
    _ = @import("fmt/aac/tables.zig");
    _ = @import("fmt/aac/huffman_tables.zig");
    _ = @import("fmt/aac/rt_tables.zig");
    _ = @import("fmt/aac/asc.zig");
    _ = @import("fmt/aac/mdct_tables.zig");
    _ = @import("fmt/aac/mdct.zig");
    _ = @import("fmt/aac/sbr_tables.zig");
    _ = @import("fmt/aac/sbr_huff.zig");
    _ = @import("fmt/aac/ps_tables.zig");
    _ = @import("fmt/aac/ps_huff.zig");
    _ = @import("fmt/aac/ps.zig");
    _ = @import("fmt/aac/sbr.zig");
    _ = @import("fmt/aac/lib.zig");
    _ = @import("fmt/adts.zig");
    _ = @import("fmt/latm.zig");
    _ = @import("fmt/mp3/synth.zig");
    _ = @import("fmt/mp3/layer3.zig");
    _ = @import("fmt/mp3/lib.zig");
    _ = @import("fmt/wv/bitreader.zig");
    _ = @import("fmt/wv/lib.zig");
    _ = @import("fmt/ape/bitreader.zig");
    _ = @import("fmt/ape/rangecoder.zig");
    _ = @import("fmt/ape/predictor.zig");
    _ = @import("fmt/ape/container.zig");
    _ = @import("fmt/ape/lib.zig");
    _ = @import("fmt/ogg.zig");
    _ = @import("fmt/opus/header.zig");
    _ = @import("fmt/opus/packet.zig");
    _ = @import("fmt/opus/rc.zig");
    _ = @import("fmt/opus/fft.zig");
    _ = @import("fmt/opus/pvq.zig");
    _ = @import("fmt/opus/celt_tables.zig");
    _ = @import("fmt/opus/celt_types.zig");
    _ = @import("fmt/opus/celt.zig");
    _ = @import("fmt/ac3/tables.zig");
    _ = @import("fmt/ac3/ctx.zig");
    _ = @import("fmt/ac3/bitalloc.zig");
    _ = @import("fmt/ac3/exponents.zig");
    _ = @import("fmt/ac3/coupling.zig");
    _ = @import("fmt/ac3/mantissa.zig");
    _ = @import("fmt/ac3/downmix.zig");
    _ = @import("fmt/ac3/header.zig");
    _ = @import("fmt/ac3/kbdwin.zig");
    _ = @import("fmt/ac3/lib.zig");
    _ = @import("fmt/wma/asf.zig");
    _ = @import("fmt/wma/packets.zig");
    _ = @import("fmt/wma/wma_mdct_tables.zig");
    _ = @import("fmt/wma/wma_mdct.zig");
    _ = @import("fmt/wma/wmadata.zig");
    _ = @import("fmt/wma/wmadec.zig");
    _ = @import("fmt/wma/wmapro/mdct_tables.zig");
    _ = @import("fmt/wma/wmapro/mdct.zig");
    _ = @import("fmt/wma/wmapro/tables.zig");
    _ = @import("fmt/wma/wmapro/core.zig");
    _ = @import("fmt/wma/wmapro/lib.zig");
    _ = @import("fmt/wma/wmavoice/tables.zig");
    _ = @import("fmt/wma/wmavoice/bitio.zig");
    _ = @import("fmt/wma/wmavoice/tx.zig");
    _ = @import("fmt/wma/wmavoice/dsp.zig");
    _ = @import("fmt/wma/wmavoice/core.zig");
    _ = @import("fmt/wma/wmavoice/lib.zig");
    _ = @import("fmt/mlp/tables.zig");
    _ = @import("fmt/mlp/ctx.zig");
    _ = @import("fmt/mlp/lib.zig");
    _ = @import("fmt/dts/tables.zig");
    _ = @import("fmt/dts/header.zig");
    _ = @import("fmt/dts/dca_tables.zig");
    _ = @import("fmt/dts/huff_tables.zig");
    _ = @import("fmt/dts/huff.zig");
    _ = @import("fmt/dts/dsp.zig");
    _ = @import("fmt/dts/core.zig");
    _ = @import("fmt/dts/lib.zig");
    _ = @import("fmt/mka/ebml.zig");
    _ = @import("fmt/mka/lib.zig");
    _ = @import("fmt/mpc/tables.zig");
    _ = @import("fmt/mpc/vlc.zig");
    _ = @import("fmt/mpc/synth.zig");
    _ = @import("fmt/mpc/sv8.zig");
    _ = @import("fmt/mpc/sv7.zig");
    _ = @import("fmt/mpc/lib.zig");
    _ = @import("fmt/tta/core.zig");
    _ = @import("fmt/tta/lib.zig");
    _ = @import("fmt/spx/decode.zig");
    _ = @import("fmt/spx/data.zig");
    _ = @import("fmt/spx/lib.zig");
    _ = @import("fmt/shn/core.zig");
    _ = @import("fmt/shn/lib.zig");
    _ = @import("fmt/tak/tables.zig");
    _ = @import("fmt/tak/core.zig");
    _ = @import("fmt/tak/lib.zig");
    _ = @import("fmt/amrwb/tables.zig");
    _ = @import("fmt/amrwb/dsp.zig");
    _ = @import("fmt/amrwb/codec.zig");
    _ = @import("fmt/amrwb/lib.zig");
    _ = @import("pcm/convert.zig");
    _ = @import("engine.zig");
}

//! AAC-LC 解码器（自研 Zig，ISO/IEC 14496-3；语义与 FFmpeg n9.0.1
//! libavcodec/aac/aacdec*.c 浮点路径逐位对照（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 范围（Phase C）：
//!   - AOT 2 (AAC-LC)，无 SBR/PS（HE-AAC → UnsupportedFormat 回退 FFmpeg 主后端 §8.3）；
//!   - raw_data_block 元素：SCE / CPE / LFE / DSE(skip) / FIL(skip；含隐式 SBR 载荷跳过，
//!     对齐 FFmpeg 对 LC 的行为) / PCE（chan_config=0 定义布局）/ CCE（耦合声道）；
//!   - 工具：MS 立体声 / intensity 立体声 / TNS / PNS / pulse / 声道耦合（CCE）；
//!     Main/LTP 预测、LD/ELD/USAC 不支持；
//!   - 容器：ADTS 裸流（本文件 Decoder VTable）。M4A 分包模式待 m4a.zig esds 接线。
//!
//! 输出契约：s16 交错小端（float ×32768 四舍五入 + 饱和），与
//! `ffmpeg -i x.aac -f s16le` 对照验收（§17.2：float 域 <1e-4 + s16 逐位统计）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const asc = @import("asc.zig");


const brmod = @import("bitreader.zig");
const t = @import("tables.zig");
const h = @import("huffman_tables.zig");
const rt = @import("rt_tables.zig");
const mdct_mod = @import("mdct.zig");
const sbr_mod = @import("sbr.zig");

const BitReader = brmod.BitReader;
const Vlc = brmod.Vlc;

// ---- BandType ----
const ZERO_BT: u8 = 0;
const RESERVED_BT: u8 = 12;
const NOISE_BT: u8 = 13;
const INTENSITY_BT2: u8 = 14;
const INTENSITY_BT: u8 = 15;

// ---- 常量 ----
const SCALE_DIFF_ZERO: i32 = 60;
const NOISE_PRE: i32 = 256;
const NOISE_PRE_BITS: u6 = 9;
const NOISE_OFFSET: i32 = 90;
const MAX_SFB: usize = 64;
const MAX_GROUPS: usize = 8;
const MAX_ELEM_ID: usize = 16;
const TNS_MAX_ORDER: usize = 20;
const FRAME_LEN: usize = 1024;

pub const Aac = struct {
    // 字段均带默认值：容器可用 `.{ .aac = .{} }` 建立定义基线（重型状态指针为
    // null），initCommon 逐字段赋值完成 open；gpa/cfg/mdct_* 在 initCommon 前不读
    gpa: std.mem.Allocator = undefined,
    cfg: asc.M4ACfg = undefined,
    channels: u8 = 0,
    sample_rate: u32 = 0,
    sampling_index: usize = 0,
    frame_samples: u16 = 1024,

    reader: ?*io.Reader = null,
    eof: bool = false,

    // 元素表（按 type 与 id 双索引：che[type][id]；SCE/LFE 用 ch[0]，CPE 用 ch[0..1]）。
    // Level-2 内存优化：重型 ChannelState 网格不再内嵌（原 64 槽 × ~126KB ≈ 8.1MB，
    // 稀疏写也会以页粒度整段变驻留），改为元素首次出现时独立小堆分配（每槽
    // ~126KB，互不相邻）；未出现元素的内存完全不分配，deinit 释放。
    che: [4][MAX_ELEM_ID]?*Che = [_][MAX_ELEM_ID]?*Che{[_]?*Che{null} ** MAX_ELEM_ID} ** 4,
    // chan_config 布局（元素序列）；PCE（chan_config=0）时指向 layout_buf
    layout: []const LayoutElem = &.{},
    // PCE 动态布局缓冲（chan_config=0 的节目配置元素）
    layout_buf: [MAX_ELEM_ID * 4]LayoutElem = undefined,
    layout_len: usize = 0,
    /// PCE 已解析（chan_config=0 时首帧解析；随布局输出）
    pce_done: bool = false,

    // VLC 表
    vlc_sf: Vlc = .{},
    vlc_spec: [11]Vlc = [_]Vlc{.{}} ** 11,

    // 共享工作区
    buf_mdct: [FRAME_LEN]f32 = [_]f32{0} ** FRAME_LEN,
    temp: [FRAME_LEN]f32 = [_]f32{0} ** FRAME_LEN,
    mdct_scratch: [512]mdct_mod.Mdct(f32).Cplx = undefined,
    mdct_long: mdct_mod.Mdct(f32) = mdct_mod.Mdct(f32).init(1024),
    mdct_short: mdct_mod.Mdct(f32) = mdct_mod.Mdct(f32).init(128),
    // LTP（AOT 4）前向 MDCT（1024 点，scale -65536 折入表）
    mdct_ltp: mdct_mod.Mdct(f32) = mdct_mod.Mdct(f32).initLtp(),

    random_state: u32 = 0x1f2e3d4c,

    // SBR 状态（HE-AAC）：~0.25MB 重型结构不内嵌，首次出现 SBR 扩展 / ASC 声明时
    // 独立小堆分配（ensureSbr）；FIL 解析 + IMDCT 后合成
    sbr: ?*sbr_mod.Sbr = null,
    sbr_enabled: bool = false,
    /// 最近一个音频元素类型（FIL 的 SBR 关联）
    prev_elem_type: i32 = -1,
    /// SBR 输出缓冲（每帧 2×1024 样本，双声道）
    sbr_buf: [2048]f32 = undefined,
    sbr_buf2: [2048]f32 = undefined,

    out_buf: std.ArrayList(u8) = .empty,
    out_pos: usize = 0, // 已消费输出字节游标
    pos_samples: u64 = 0,
    stat_frames: u64 = 0,

    pub fn initCommon(self: *Aac, gpa: std.mem.Allocator, cfg: asc.M4ACfg) Error!void {
        const si: usize = if (!cfg.sampling_explicit)
            cfg.sampling_index
        else
            samplingIndexForRate(cfg.sample_rate) orelse return error.Corrupt;
        // 显式逐字段初始化（open 不得整结构 memcpy/物化默认常量）。Level-2：
        // 重型状态已全部移出结构本体——Che 元素槽位与 SBR 均为首用时独立小堆
        // 分配。此处先释放上一会话残留（容器 open 以 `.{}` 建立 null 基线时
        // free 为空操作；latm 配置变更重入时释放旧槽位），再赋标量字段。
        self.deinit();
        self.gpa = gpa;
        self.cfg = cfg;
        self.reader = null;
        self.eof = false;
        self.channels = if (cfg.chan_config < chan_layouts.len) chanLayoutChannels(cfg.chan_config) else 1;
        self.sample_rate = cfg.sample_rate;
        self.sampling_index = si;
        self.frame_samples = if (cfg.frame_length_short) 960 else 1024;
        self.layout = if (cfg.chan_config < chan_layouts.len) chan_layouts[cfg.chan_config] else &.{};
        self.layout_len = 0;
        self.pce_done = false;
        self.random_state = 0x1f2e3d4c;
        self.prev_elem_type = -1;
        self.out_buf = .empty;
        self.out_pos = 0;
        self.pos_samples = 0;
        self.stat_frames = 0;
        self.mdct_long = mdct_mod.Mdct(f32).init(1024);
        self.mdct_short = mdct_mod.Mdct(f32).init(128);
        self.mdct_ltp = mdct_mod.Mdct(f32).initLtp();
        self.sbr_enabled = false;
        // ASC 显式声明 SBR（HE-AAC）：预置启用（对齐 ffmpeg m4ac.sbr=1，使前导帧
        // start==0 也执行纯上采样 QMF 暖机，避免 X_low 提前 1 帧）
        if (cfg.sbr == 1) {
            try self.ensureSbr();
            self.sbr_enabled = true;
        }
        self.buildVlcs();
    }

    /// 释放重型堆分配状态（Che 元素槽位 + SBR；out_buf 归容器释放）。
    /// 重复调用安全（指针释放后置 null）；要求容器已建立定义基线
    /// （open 以 `.{ .aac = .{} }` 初始化，未初始化元素槽位为 null）。
    pub fn deinit(self: *Aac) void {
        for (0..4) |ty| {
            for (0..MAX_ELEM_ID) |id| {
                if (self.che[ty][id]) |c| {
                    self.gpa.destroy(c);
                    self.che[ty][id] = null;
                }
            }
        }
        if (self.sbr) |s| {
            self.gpa.destroy(s);
            self.sbr = null;
        }
        self.sbr_enabled = false;
    }

    /// 惰性初始化 SBR 状态（对齐原 initCommon 无条件 Sbr.init+zeroState；仅 HE/
    /// 首次遇到 SBR 扩展时才真正分配+写入，普通 LC 全程不触碰 SBR 缓冲）
    fn ensureSbr(self: *Aac) Error!void {
        if (self.sbr == null) {
            const s = self.gpa.create(sbr_mod.Sbr) catch return error.OutOfMemory;
            s.* = sbr_mod.Sbr.init();
            s.zeroState();
            s.sample_rate = @as(i32, @intCast(self.cfg.sample_rate)) * 2;
            self.sbr = s;
        }
    }

    /// 元素首次出现时独立小堆分配该槽位并整块零化（历史缓冲 output/saved/
    /// ltp_state/预测器等首用前必须为 0，等价原 open 期全量清零；此后跨帧保留，
    /// present 每帧复位而缓冲不清）。未出现元素的内存完全不分配。
    fn getChe(self: *Aac, ty: usize, id: usize) Error!*Che {
        if (self.che[ty][id]) |c| return c;
        const c = self.gpa.create(Che) catch return error.OutOfMemory;
        @memset(std.mem.asBytes(c), 0);
        self.che[ty][id] = c;
        return c;
    }

    fn buildVlcs(self: *Aac) void {
        self.vlc_sf.build(&h.scalefactor_code, &h.scalefactor_bits, null);
        for (0..11) |i| {
            self.vlc_spec[i].build(h.spectral_codes[i], h.spectral_bits[i], h.spectral_idx[i]);
        }
    }

    // ---------------- ICS 信息 ----------------

    fn decodeIcsInfo(self: *Aac, ch: *ChannelState, br: *BitReader) Error!void {
        _ = try br.readBits(1); // 保留位
        ch.ics.window_sequence[1] = ch.ics.window_sequence[0];
        ch.ics.window_sequence[0] = @intCast(try br.readBits(2));
        ch.ics.use_kb_window[1] = ch.ics.use_kb_window[0];
        ch.ics.use_kb_window[0] = (try br.readBits(1)) != 0;

        ch.ics.num_window_groups = 1;
        ch.ics.group_len = .{ 1, 0, 0, 0, 0, 0, 0, 0 };

        const si = self.sampling_index;
        if (ch.ics.window_sequence[0] == 2) { // EIGHT_SHORT
            ch.ics.max_sfb = @intCast(try br.readBits(4));
            var g: usize = 0;
            while (g < 7) : (g += 1) {
                if ((try br.readBits(1)) != 0) {
                    ch.ics.group_len[ch.ics.num_window_groups - 1] += 1;
                } else {
                    ch.ics.num_window_groups += 1;
                    ch.ics.group_len[ch.ics.num_window_groups - 1] = 1;
                }
            }
            ch.ics.swb_offset = t.swb_offset_128[si];
            ch.ics.num_swb = t.num_swb_128[si];
            ch.ics.tns_max_bands = t.tns_max_bands_128[si];
            ch.ics.num_windows = 8;
        } else {
            ch.ics.max_sfb = @intCast(try br.readBits(6));
            ch.ics.num_windows = 1;
            ch.ics.swb_offset = t.swb_offset_1024[si];
            ch.ics.num_swb = t.num_swb_1024[si];
            ch.ics.tns_max_bands = t.tns_max_bands_1024[si];
            // predictor_present：Main（AOT 1）→ decode_prediction；LTP（AOT 4）→ decode_ltp；LC → 拒
            ch.ics.predictor_present = (try br.readBits(1)) != 0;
            // ffmpeg 每帧清零 predictor_reset_group（aacdec.c decode_ics_info），
            // 非 predictor 帧不得沿用旧 reset 组反复重置预测器
            ch.ics.predictor_reset_group = 0;
            if (ch.ics.predictor_present) {
                switch (self.cfg.object_type) {
                    asc.AOT_AAC_MAIN => try self.decodePrediction(ch, br),
                    asc.AOT_AAC_LTP => {
                        // decode_ics_info：先读 ics.ltp.present，为 1 才跟 lag/coef/used
                        ch.ics.ltp.present = (try br.readBits(1)) != 0;
                        if (ch.ics.ltp.present) try decodeLtpFields(ch, br);
                    },
                    else => return error.Corrupt, // LC 不允许预测
                }
            }
        }
        if (ch.ics.max_sfb > ch.ics.num_swb) return error.Corrupt;
    }

    /// Main profile：decode_prediction（predictor_reset_group + prediction_used）
    fn decodePrediction(self: *Aac, ch: *ChannelState, br: *BitReader) Error!void {
        if ((try br.readBits(1)) != 0) {
            ch.ics.predictor_reset_group = @intCast(try br.readBits(5));
            if (ch.ics.predictor_reset_group == 0 or ch.ics.predictor_reset_group > 30) return error.Corrupt;
        }
        const lim = @min(ch.ics.max_sfb, pred_sfb_max[self.sampling_index]);
        for (0..lim) |sfb| {
            ch.ics.prediction_used[sfb] = (try br.readBits(1)) != 0;
        }
    }

    /// LTP：decode_ltp 字段（lag + coef + used 掩码；present 位在 decodeIcsInfo 已读）
    fn decodeLtpFields(ch: *ChannelState, br: *BitReader) Error!void {
        const ltp = &ch.ics.ltp;
        ltp.lag = @intCast(try br.readBits(11));
        ltp.coef = ltp_coef[try br.readBits(3)];
        const lim = @min(ch.ics.max_sfb, MAX_LTP_LONG_SFB);
        for (0..lim) |sfb| {
            ltp.used[sfb] = (try br.readBits(1)) != 0;
        }
    }

    // ---------------- section data / scalefactors ----------------

    fn decodeBandTypes(ch: *ChannelState, br: *BitReader) Error!void {
                const bits: u6 = if (ch.ics.window_sequence[0] == 2) 3 else 5;
        const run_end_val: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
        var g: usize = 0;
        while (g < ch.ics.num_window_groups) : (g += 1) {
            var k: usize = 0;
            while (k < ch.ics.max_sfb) {
                var sect_end: usize = k;
                const sect_band_type: u8 = @intCast(try br.readBits(4));
                if (sect_band_type == RESERVED_BT) return error.Corrupt;
                while (true) {
                    const incr: u32 = try br.readBits(bits);
                    sect_end += incr;
                    if (sect_end > ch.ics.max_sfb) return error.Corrupt;
                    if (incr != run_end_val) break;
                }
                while (k < sect_end) : (k += 1) {
                    ch.band_type[g * ch.ics.max_sfb + k] = sect_band_type;
                }
            }
        }
    }

    fn decodeScalefactors(self: *Aac, ch: *ChannelState, br: *BitReader, global_gain: u32) Error!void {
                var offset = [3]i32{
            @intCast(global_gain),
            @as(i32, @intCast(global_gain)) - NOISE_OFFSET,
            0,
        };
        var noise_flag = true;
        var g: usize = 0;
        while (g < ch.ics.num_window_groups) : (g += 1) {
            var sfb: usize = 0;
            while (sfb < ch.ics.max_sfb) : (sfb += 1) {
                switch (ch.band_type[g * ch.ics.max_sfb + sfb]) {
                    ZERO_BT => ch.sfo[g * ch.ics.max_sfb + sfb] = 0,
                    INTENSITY_BT, INTENSITY_BT2 => {
                        offset[2] += @as(i32, try self.vlc_sf.decode(br)) - SCALE_DIFF_ZERO;
                        offset[2] = std.math.clamp(offset[2], -155, 100);
                        ch.sfo[g * ch.ics.max_sfb + sfb] = offset[2] - 100;
                    },
                    NOISE_BT => {
                        if (noise_flag) {
                            noise_flag = false;
                            offset[1] += @as(i32, @intCast(try br.readBits(NOISE_PRE_BITS))) - NOISE_PRE;
                        } else {
                            offset[1] += @as(i32, try self.vlc_sf.decode(br)) - SCALE_DIFF_ZERO;
                        }
                        offset[1] = std.math.clamp(offset[1], -100, 155);
                        ch.sfo[g * ch.ics.max_sfb + sfb] = offset[1];
                    },
                    else => {
                        offset[0] += @as(i32, try self.vlc_sf.decode(br)) - SCALE_DIFF_ZERO;
                        if (offset[0] < 0 or offset[0] > 255) return error.Corrupt;
                        ch.sfo[g * ch.ics.max_sfb + sfb] = offset[0] - 100;
                    },
                }
            }
        }
    }

    fn dequantScalefactors(ch: *ChannelState) void {
        var idx: usize = 0;
        var g: usize = 0;
        while (g < ch.ics.num_window_groups) : (g += 1) {
            var sfb: usize = 0;
            while (sfb < ch.ics.max_sfb) : ({
                sfb += 1;
                idx += 1;
            }) {
                ch.sf[idx] = switch (ch.band_type[g * ch.ics.max_sfb + sfb]) {
                    ZERO_BT => 0.0,
                    INTENSITY_BT, INTENSITY_BT2 => rt.pow2sf_tab[@intCast(-ch.sfo[idx] - 100 + rt.pow_sf2_zero)],
                    else => -rt.pow2sf_tab[@intCast(ch.sfo[idx] + rt.pow_sf2_zero)],
                };
            }
        }
    }

    // ---------------- pulse / TNS ----------------

    const Pulse = struct {
        num_pulse: u8 = 0,
        pos: [4]u16 = .{ 0, 0, 0, 0 },
        amp: [4]u8 = .{ 0, 0, 0, 0 },
    };

    fn decodePulses(pulse: *Pulse, br: *BitReader, swb_offset: []const u16, num_swb: u8) Error!void {
                pulse.num_pulse = @intCast((try br.readBits(2)) + 1);
        const start_swb: u8 = @intCast(try br.readBits(6));
        if (start_swb >= num_swb) return error.Corrupt;
        pulse.pos[0] = swb_offset[start_swb];
        pulse.pos[0] += @intCast(try br.readBits(5));
        if (pulse.pos[0] >= swb_offset[num_swb]) return error.Corrupt;
        pulse.amp[0] = @intCast(try br.readBits(4));
        var i: usize = 1;
        while (i < pulse.num_pulse) : (i += 1) {
            pulse.pos[i] = pulse.pos[i - 1] + @as(u16, @intCast(try br.readBits(5)));
            if (pulse.pos[i] >= swb_offset[num_swb]) return error.Corrupt;
            pulse.amp[i] = @intCast(try br.readBits(4));
        }
    }

    fn decodeTns(ch: *ChannelState, br: *BitReader) Error!void {
                const is8 = ch.ics.window_sequence[0] == 2;
        var w: usize = 0;
        while (w < ch.ics.num_windows) : (w += 1) {
            const n_filt: u8 = @intCast(try br.readBits(if (is8) @as(u6, 1) else 2));
            ch.tns_n_filt[w] = n_filt;
            if (n_filt == 0) continue;
            const coef_res: u1 = @intCast(try br.readBits(1));
            var filt: usize = 0;
            while (filt < n_filt) : (filt += 1) {
                ch.tns_length[w][filt] = @intCast(try br.readBits(if (is8) @as(u6, 4) else 6));
                ch.tns_order[w][filt] = @intCast(try br.readBits(if (is8) @as(u6, 3) else 5));
                const order = ch.tns_order[w][filt];
                const max_order: u8 = if (is8) 7 else 12;
                if (order > max_order) return error.Corrupt;
                if (order != 0) {
                    ch.tns_direction[w][filt] = (try br.readBits(1)) != 0;
                    const coef_compress: bool = (try br.readBits(1)) != 0;
                    const coef_len: u6 = @intCast(@as(u32, coef_res) + 3 - @intFromBool(coef_compress));
                    const map = t.tns_tmp2_map[2 * @as(usize, @intFromBool(coef_compress)) + coef_res];
                    var i: usize = 0;
                    while (i < order) : (i += 1) {
                        ch.tns_coef[w][filt][i] = map[@intCast(try br.readBits(coef_len))];
                    }
                }
            }
        }
    }

    // ---------------- 频谱解码 + 反量化 ----------------

    inline fn vmul4(dst: [*]f32, vq: []const f32, idx_in: u32, sfv: f32) [*]f32 {
        dst[0] = vq[idx_in & 3] * sfv;
        dst[1] = vq[(idx_in >> 2) & 3] * sfv;
        dst[2] = vq[(idx_in >> 4) & 3] * sfv;
        dst[3] = vq[(idx_in >> 6) & 3] * sfv;
        return dst + 4;
    }

    inline fn vmul4s(dst: [*]f32, vq: []const f32, idx_in: u32, sign_in: u32, sfv: f32) [*]f32 {
        var sign = sign_in;
        var nz: u32 = idx_in >> 12;
        const sbits: u32 = @bitCast(sfv);
        var tb: u32 = sbits ^ (sign & (@as(u32, 1) << 31));
        dst[0] = vq[idx_in & 3] * @as(f32, @bitCast(tb));
        sign = sign << @intCast(nz & 1);
        nz >>= 1;
        tb = sbits ^ (sign & (@as(u32, 1) << 31));
        dst[1] = vq[(idx_in >> 2) & 3] * @as(f32, @bitCast(tb));
        sign = sign << @intCast(nz & 1);
        nz >>= 1;
        tb = sbits ^ (sign & (@as(u32, 1) << 31));
        dst[2] = vq[(idx_in >> 4) & 3] * @as(f32, @bitCast(tb));
        sign = sign << @intCast(nz & 1);
        tb = sbits ^ (sign & (@as(u32, 1) << 31));
        dst[3] = vq[(idx_in >> 6) & 3] * @as(f32, @bitCast(tb));
        return dst + 4;
    }

    inline fn vmul2(dst: [*]f32, vq: []const f32, idx_in: u32, sfv: f32) [*]f32 {
        dst[0] = vq[idx_in & 15] * sfv;
        dst[1] = vq[(idx_in >> 4) & 15] * sfv;
        return dst + 2;
    }

    inline fn vmul2s(dst: [*]f32, vq: []const f32, idx_in: u32, sign_in: u32, sfv: f32) [*]f32 {
        const sbits: u32 = @bitCast(sfv);
        const s0: u32 = sbits ^ ((sign_in >> 1) << 31);
        const s1: u32 = sbits ^ ((sign_in & 1) << 31);
        dst[0] = vq[idx_in & 15] * @as(f32, @bitCast(s0));
        dst[1] = vq[(idx_in >> 4) & 15] * @as(f32, @bitCast(s1));
        return dst + 2;
    }

    fn decodeSpectrumAndDequant(
        self: *Aac,
        ch: *ChannelState,
        br: *BitReader,
        pulse: ?*const Pulse,
    ) Error!void {
                const ics = &ch.ics;
        const c: u16 = @intCast(FRAME_LEN / ics.num_windows);
        const offsets = ics.swb_offset;
        const coef_base = &ch.coeffs;

        {
            var gw: usize = 0;
            while (gw < ics.num_windows) : (gw += 1) {
                const from = gw * 128 + offsets[ics.max_sfb];
                const to = gw * 128 + c;
                @memset(coef_base[from..to], 0);
            }
        }

        var idx: usize = 0;
        var g: usize = 0;
        var g_off: usize = 0; // 跨组窗口基址累加（对齐 C 的 coef += g_len << 7）
        while (g < ics.num_window_groups) : (g += 1) {
            const g_len: usize = ics.group_len[g];
            var sfb: usize = 0;
            while (sfb < ics.max_sfb) : ({
                sfb += 1;
                idx += 1;
            }) {
                const bt = ch.band_type[idx];
                // C 参考为无符号减法：ZERO_BT-1 回绕为大值 → 命中置零分支
                const cbt_m1: u32 = @as(u32, bt) -% 1;
                const sfv = ch.sf[idx];
                var band_off: usize = g_off + offsets[sfb];
                const off_len: usize = offsets[sfb + 1] - offsets[sfb];

                var group: usize = 0;
                while (group < g_len) : ({
                    group += 1;
                    band_off += 128;
                }) {
                    const cfo: [*]f32 = coef_base[band_off .. band_off + off_len].ptr;

                    if (cbt_m1 >= INTENSITY_BT2 - 1) {
                        // INTENSITY / ZERO
                        @memset(coef_base[band_off .. band_off + off_len], 0);
                    } else if (cbt_m1 == NOISE_BT - 1) {
                        // PNS
                        var k: usize = 0;
                        while (k < off_len) : (k += 1) {
                            self.random_state = @bitCast(lcgRandom(self.random_state));
                            // C 参考中 random_state 为 int（有符号）：float 转换保留符号
                            const rs: i32 = @bitCast(self.random_state);
                            cfo[k] = @floatFromInt(rs);
                        }
                        var energy: f32 = 0;
                        k = 0;
                        while (k < off_len) : (k += 1) energy += cfo[k] * cfo[k];
                        const scale = sfv / @sqrt(energy);
                        k = 0;
                        while (k < off_len) : (k += 1) cfo[k] *= scale;
                    } else {
                        const book: usize = @intCast(cbt_m1);
                        const vq = h.spectral_vals[book];
                        var cf: [*]f32 = cfo;
                        switch (book >> 1) {
                            0 => {
                                var len = off_len;
                                while (len > 0) : (len -= 4) {
                                    const code = try self.vlc_spec[book].decode(br);                                    cf = vmul4(cf, vq, code, sfv);
                                }
                            },
                            1 => {
                                var len = off_len;
                                while (len > 0) : (len -= 4) {
                                    const cb_idx = try self.vlc_spec[book].decode(br);
                                    const nnz: u32 = (cb_idx >> 8) & 15;
                                    // C 用 GET_CACHE（左对齐缓存）：符号位须置于位 31 起，
                                    // 右对齐 readBits 后需左移对齐，否则符号全部丢失
                                    const sign: u32 = if (nnz != 0)
                                        (try br.readBits(@intCast(nnz))) << @intCast(32 - @min(nnz, 32))
                                    else
                                        0;
                                    cf = vmul4s(cf, vq, cb_idx, sign, sfv);
                                }
                            },
                            2 => {
                                var len = off_len;
                                while (len > 0) : (len -= 2) {
                                    const cb_idx = try self.vlc_spec[book].decode(br);
                                    cf = vmul2(cf, vq, cb_idx, sfv);
                                }
                            },
                            3, 4 => {
                                var len = off_len;
                                while (len > 0) : (len -= 2) {
                                    const cb_idx = try self.vlc_spec[book].decode(br);
                                    const nnz: u32 = (cb_idx >> 8) & 15;
                                    var sign: u32 = 0;
                                    if (nnz != 0) {
                                        sign = (try br.readBits(@intCast(nnz))) << @intCast(cb_idx >> 12);
                                    }
                                    cf = vmul2s(cf, vq, cb_idx, sign, sfv);
                                }
                            },
                            else => {
                                // ESC 码本（book 11）：值按位写入，带尾统一乘 sf
                                var len = off_len;
                                while (len > 0) : (len -= 2) {
                                    var cb_idx = try self.vlc_spec[10].decode(br);
                                    if (cb_idx == 0x0000) {
                                        cf[0] = 0;
                                        cf[1] = 0;
                                        cf += 2;
                                        continue;
                                    }
                                    const nnz: u32 = cb_idx >> 12;
                                    const nzt: u32 = (cb_idx >> 8) & 15;
                                    var bits: u32 = 0;
                                    if (nnz != 0) {
                                        bits = (try br.readBits(@intCast(nnz))) << @intCast(32 - nnz);
                                    }
                                    var j: usize = 0;
                                    while (j < 2) : (j += 1) {
                                        if ((nzt & (@as(u32, 1) << @intCast(j))) != 0) {
                                            const peek: u32 = try br.showBits(32);
                                            const b_esc: u32 = @clz(~peek);
                                            if (b_esc > 8) return error.Corrupt;
                                            try br.skipBits(b_esc + 1);
                                            const be: u32 = b_esc + 4;
                                            const n: u32 = (@as(u32, 1) << @intCast(be)) + (try br.readBits(@intCast(be)));
                                            cf[0] = @bitCast(rt.cbrt_tab[n] | (bits & (@as(u32, 1) << 31)));
                                            cf += 1;
                                            bits = @truncate(@as(u64, bits) << 1);
                                        } else {
                                            const vv: u32 = @as(u32, @bitCast(vq[cb_idx & 15]));
                                            cf[0] = @bitCast((bits & (@as(u32, 1) << 31)) | vv);
                                            cf += 1;
                                            if (vv != 0) bits = @truncate(@as(u64, bits) << 1);
                                        }
                                        cb_idx >>= 4;
                                    }
                                }
                                var k: usize = 0;
                                while (k < off_len) : (k += 1) cfo[k] *= sfv;
                            },
                        }
                    }
                }
            }
            g_off += g_len * 128;
        }

        if (pulse) |p| {
            var pidx: usize = 0;
            var i: usize = 0;
            while (i < p.num_pulse) : (i += 1) {
                var co = coef_base[p.pos[i]];
                while (offsets[pidx + 1] <= p.pos[i]) pidx += 1;
                const bt = ch.band_type[pidx];
                const sfv = ch.sf[pidx];
                if (bt != NOISE_BT and sfv != 0) {
                    var ico: f32 = -@as(f32, @floatFromInt(p.amp[i]));
                    if (co != 0) {
                        co /= sfv;
                        // ffmpeg 浮点路径除数是 sqrtf(sqrtf(|co|)) = 4 次根（非 cbrt）
                        ico = co / @sqrt(@sqrt(@abs(co))) + (if (co > 0) @as(f32, -ico) else ico);
                    }
                    coef_base[p.pos[i]] = std.math.cbrt(@abs(ico)) * ico * sfv;
                }
            }
        }
    }

    // ---------------- TNS 滤波 ----------------

    fn applyTns(buf: []f32, ch: *ChannelState, decode_mode: bool) void {
        const mmm = @min(ch.ics.tns_max_bands, ch.ics.max_sfb);
        if (mmm == 0) return;
        var lpc: [TNS_MAX_ORDER]f32 = undefined;
        var tmp: [TNS_MAX_ORDER + 1]f32 = undefined;

        var w: usize = 0;
        while (w < ch.ics.num_windows) : (w += 1) {
            var bottom: usize = ch.ics.num_swb;
            var filt: usize = 0;
            while (filt < ch.tns_n_filt[w]) : (filt += 1) {
                const top = bottom;
                bottom = if (top > ch.tns_length[w][filt]) top - ch.tns_length[w][filt] else 0;
                const order: usize = ch.tns_order[w][filt];
                if (order == 0) continue;

                // tns_decode_coef：反射系数 → LPC（原地 Schur）
                var i: usize = 0;
                while (i < order) : (i += 1) {
                    const r: f32 = -ch.tns_coef[w][filt][i];
                    lpc[i] = r;
                    var j: usize = 0;
                    while (j < (i + 1) / 2) : (j += 1) {
                        const f = lpc[j];
                        const b = lpc[i - 1 - j];
                        lpc[j] = f + r * b;
                        lpc[i - 1 - j] = b + r * f;
                    }
                }

                const start_abs = ch.ics.swb_offset[@min(bottom, mmm)];
                const end_abs = ch.ics.swb_offset[@min(top, mmm)];
                const size: isize = @as(isize, @intCast(end_abs)) - @as(isize, @intCast(start_abs));
                if (size <= 0) continue;

                var inc: isize = 1;
                var start: isize = @intCast(start_abs);
                if (ch.tns_direction[w][filt]) {
                    inc = -1;
                    start = @intCast(end_abs - 1);
                }
                start += @intCast(w * 128);

                if (decode_mode) {
                    var m: usize = 0;
                    while (m < size) : ({
                        m += 1;
                        start += inc;
                    }) {
                        i = 1;
                        const lim = @min(m, order);
                        while (i <= lim) : (i += 1) {
                            const si: usize = @intCast(start);
                            buf[si] -= buf[@intCast(@as(isize, @intCast(si)) - @as(isize, @intCast(i)) * inc)] * lpc[i - 1];
                        }
                    }
                } else {
                    var m: usize = 0;
                    while (m < size) : ({
                        m += 1;
                        start += inc;
                    }) {
                        const si: usize = @intCast(start);
                        tmp[0] = buf[si];
                        i = 1;
                        const lim = @min(m, order);
                        while (i <= lim) : (i += 1) {
                            buf[si] += tmp[i] * lpc[i - 1];
                        }
                        i = order;
                        while (i > 0) : (i -= 1) tmp[i] = tmp[i - 1];
                    }
                }
            }
        }
    }

    // ---------------- MS / intensity ----------------

    fn applyMidSideStereo(che: *Che) void {
        const ics = &che.ch[0].ics;
        var ch_off: usize = 0;
        var g: usize = 0;
        while (g < ics.num_window_groups) : (g += 1) {
            var sfb: usize = 0;
            while (sfb < che.max_sfb_ste) : (sfb += 1) {
                const idx = g * che.max_sfb_ste + sfb;
                if (che.ms_mask[idx] and
                    che.ch[0].band_type[idx] < NOISE_BT and
                    che.ch[1].band_type[idx] < NOISE_BT)
                {
                    const len = ics.swb_offset[sfb + 1] - ics.swb_offset[sfb];
                    var group: usize = 0;
                    while (group < ics.group_len[g]) : (group += 1) {
                        const base = ch_off + ics.swb_offset[sfb] + group * 128;
                        var i: usize = base;
                        const end = base + len;
                        while (i < end) : (i += 1) {
                            const tt = che.ch[0].coeffs[i] - che.ch[1].coeffs[i];
                            che.ch[0].coeffs[i] += che.ch[1].coeffs[i];
                            che.ch[1].coeffs[i] = tt;
                        }
                    }
                }
            }
            ch_off += @as(usize, ics.group_len[g]) * 128;
        }
    }

    fn applyIntensityStereo(che: *Che, ms_present: bool) void {
        const ics = &che.ch[1].ics;
        var ch0_off: usize = 0;
        var ch1_off: usize = 0;
        var g: usize = 0;
        while (g < ics.num_window_groups) : (g += 1) {
            var sfb: usize = 0;
            while (sfb < ics.max_sfb) : (sfb += 1) {
                const idx = g * ics.max_sfb + sfb;
                const bt = che.ch[1].band_type[idx];
                if (bt == INTENSITY_BT or bt == INTENSITY_BT2) {
                    var c: f32 = @floatFromInt(-1 + 2 * (@as(i32, bt) - 14));
                    if (ms_present) {
                        c *= if (che.ms_mask[idx]) @as(f32, -1.0) else 1.0;
                    }
                    const scale = c * che.ch[1].sf[idx];
                    const len = ics.swb_offset[sfb + 1] - ics.swb_offset[sfb];
                    var group: usize = 0;
                    while (group < ics.group_len[g]) : (group += 1) {
                        const src = ch0_off + group * 128 + ics.swb_offset[sfb];
                        const dst = ch1_off + group * 128 + ics.swb_offset[sfb];
                        var i: usize = 0;
                        while (i < len) : (i += 1) {
                            che.ch[1].coeffs[dst + i] = che.ch[0].coeffs[src + i] * scale;
                        }
                    }
                }
            }
            ch0_off += @as(usize, ics.group_len[g]) * 128;
            ch1_off += @as(usize, ics.group_len[g]) * 128;
        }
    }

    // ---------------- IMDCT + 加窗 + 重叠相加 ----------------

    /// float_dsp vector_fmul_window_c（指针预偏移 dst/win/src0 各 +len 后的展开）：
    ///   dst[len+k] = src0[k]*win[len-1-k] − src1[len-1-k]*win[len+k]
    ///   dst[len-1-k] = src0[k]*win[len+k] + src1[len-1-k]*win[len-1-k]
    fn vectorFmulWindow(dst: []f32, src0: []const f32, src1: []const f32, win: []const f32, comptime len: usize) void {
        // float_dsp vector_fmul_window_c（dst/win/src0 预偏 len 后的展开）：
        //   out[k]          = src0[k]*win[2len-1-k] − src1[len-1-k]*win[k]
        //   out[2len-1-k]   = src0[k]*win[k] + src1[len-1-k]*win[2len-1-k]
        var k: usize = 0;
        while (k < len) : (k += 1) {
            const jj = len - 1 - k;
            const wj = win[2 * len - 1 - k];
            const wi = win[k];
            dst[k] = src0[k] * wj - src1[jj] * wi;
            dst[2 * len - 1 - k] = src0[k] * wi + src1[jj] * wj;
        }
    }

    fn imdctAndWindowing(self: *Aac, ch: *ChannelState) void {
        const ics = &ch.ics;
        const in = &ch.coeffs;
        const out = &ch.output;
        const saved = &ch.saved;
        const swin: []const f32 = if (ics.use_kb_window[0]) &rt.kbd_short_128 else &rt.sine_128;
        const lwin_prev: []const f32 = if (ics.use_kb_window[1]) &rt.kbd_long_1024 else &rt.sine_1024;
        const swin_prev: []const f32 = if (ics.use_kb_window[1]) &rt.kbd_short_128 else &rt.sine_128;
        const buf = &self.buf_mdct;
        const temp = &self.temp;

        if (ics.window_sequence[0] == 2) {
            var i: usize = 0;
            while (i < 1024) : (i += 128) {
                self.mdct_short.transform(buf[i .. i + 128], in[i .. i + 128], &self.mdct_scratch);
            }
        } else {
            self.mdct_long.transform(buf, in, &self.mdct_scratch);
        }

        const ws1 = ics.window_sequence[1];
        const ws0 = ics.window_sequence[0];
        if ((ws1 == 0 or ws1 == 3) and (ws0 == 0 or ws0 == 1)) {
            vectorFmulWindow(out, saved, buf, lwin_prev, 512);
        } else {
            @memcpy(out[0..448], saved[0..448]);
            if (ws0 == 2) {
                vectorFmulWindow(out[448 .. 448 + 128], saved[448..576], buf[0 .. 0 + 128], swin_prev, 64);
                var w: usize = 1;
                while (w < 4) : (w += 1) {
                    vectorFmulWindow(out[448 + w * 128 .. 448 + (w + 1) * 128], buf[(w - 1) * 128 + 64 .. w * 128 + 64], buf[w * 128 .. (w + 1) * 128], swin, 64);
                }
                vectorFmulWindow(temp[0..128], buf[3 * 128 + 64 .. 4 * 128 + 64], buf[4 * 128 .. 5 * 128], swin, 64);
                @memcpy(out[960..1024], temp[0..64]);
            } else {
                vectorFmulWindow(out[448 .. 448 + 128], saved[448..576], buf[0..128], swin_prev, 64);
                @memcpy(out[576..1024], buf[64..512]);
            }
        }

        if (ws0 == 2) {
            @memcpy(saved[0..64], temp[64..128]);
            vectorFmulWindow(saved[64 .. 64 + 128], buf[4 * 128 + 64 .. 5 * 128 + 64], buf[5 * 128 .. 6 * 128], swin, 64);
            vectorFmulWindow(saved[192 .. 192 + 128], buf[5 * 128 + 64 .. 6 * 128 + 64], buf[6 * 128 .. 7 * 128], swin, 64);
            vectorFmulWindow(saved[320 .. 320 + 128], buf[6 * 128 + 64 .. 7 * 128 + 64], buf[7 * 128 .. 8 * 128], swin, 64);
            @memcpy(saved[448..512], buf[7 * 128 + 64 .. 8 * 128]);
        } else if (ws0 == 1) {
            @memcpy(saved[0..448], buf[512..960]);
            @memcpy(saved[448..512], buf[7 * 128 + 64 .. 8 * 128]);
        } else {
            @memcpy(saved[0..512], buf[512..1024]);
        }
    }

    // ---------------- AAC Main 预测（apply_prediction） ----------------

    fn applyPrediction(self: *Aac, ch: *ChannelState) void {
            if (!ch.ics.predictor_initialized) {
            for (0..MAX_PREDICTORS) |i| resetPredictState(&ch.predictor_state[i]);
            ch.ics.predictor_initialized = true;
        }
        if (ch.ics.window_sequence[0] != 2) { // 非 EIGHT_SHORT
            const lim = pred_sfb_max[self.sampling_index];
            for (0..lim) |sfb| {
                var k = ch.ics.swb_offset[sfb];
                while (k < ch.ics.swb_offset[sfb + 1]) : (k += 1) {
                    predict(&ch.predictor_state[k], &ch.coeffs[k], ch.ics.predictor_present and ch.ics.prediction_used[sfb]);
                }
            }
            if (ch.ics.predictor_reset_group != 0) {
                var i: usize = ch.ics.predictor_reset_group - 1;
                while (i < MAX_PREDICTORS) : (i += 30) resetPredictState(&ch.predictor_state[i]);
            }
        } else {
            for (0..MAX_PREDICTORS) |i| resetPredictState(&ch.predictor_state[i]);
        }
    }

    // ---------------- AAC LTP（apply_ltp / update_ltp / windowing_and_mdct_ltp） ----------------

    /// float_dsp vector_fmul_reverse_c：dst[i] = src0[i] * src1[len-1-i]
    fn vectorFmulReverse(dst: []f32, src0: []const f32, src1: []const f32, comptime len: usize) void {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            dst[i] = src0[i] * src1[len - 1 - i];
        }
    }

    /// windowing_and_mdct_ltp：对 in（predTime，2048）原地加窗后前向 MDCT 到 buf_mdct。
    /// 窗口选当前/上一帧 use_kb_window；LONG_STOP(3)/LONG_START(1) 走 448/128 拼接。
    fn windowingAndMdctLtp(self: *Aac, in: []f32, ics: *const Ics) void {
        const lw0: []const f32 = if (ics.use_kb_window[0]) &rt.kbd_long_1024 else &rt.sine_1024;
        const sw0: []const f32 = if (ics.use_kb_window[0]) &rt.kbd_short_128 else &rt.sine_128;
        const lw1: []const f32 = if (ics.use_kb_window[1]) &rt.kbd_long_1024 else &rt.sine_1024;
        const sw1: []const f32 = if (ics.use_kb_window[1]) &rt.kbd_short_128 else &rt.sine_128;
        const ws0 = ics.window_sequence[0];

        if (ws0 != 3) { // != LONG_STOP
            var i: usize = 0;
            while (i < 1024) : (i += 1) in[i] *= lw1[i];
        } else {
            @memset(in[0..448], 0);
            vectorFmulReverse(in[448..576], in[448..576], sw1, 128);
        }
        if (ws0 != 1) { // != LONG_START
            var i: usize = 0;
            while (i < 1024) : (i += 1) in[1024 + i] *= lw0[1023 - i];
        } else {
            vectorFmulReverse(in[1024 + 448 .. 1024 + 576], in[1024 + 448 .. 1024 + 576], sw0, 128);
            @memset(in[1024 + 576 ..], 0);
        }

        self.mdct_ltp.transformFwd(self.buf_mdct[0..1024], in[0..2048], &self.mdct_scratch);
    }

    /// apply_ltp：predTime = ltp_state[+2048-lag]·coef → 加窗前向 MDCT 得 predFreq，
    /// TNS（encode 方向）后对 used sfb 加回 coeffs。
    fn applyLtp(self: *Aac, ch: *ChannelState) void {
        const ics = &ch.ics;
        if (ics.window_sequence[0] == 2) return; // EIGHT_SHORT
        const ltp = &ics.ltp;
        const predTime = ch.output[0..2048];
        const predFreq = self.buf_mdct[0..1024];

        var num_samples: usize = 2048;
        if (ltp.lag < 1024) num_samples = ltp.lag + 1024;
        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            predTime[i] = ch.ltp_state[i + 2048 - ltp.lag] * ltp.coef;
        }
        @memset(predTime[num_samples..], 0);

        self.windowingAndMdctLtp(predTime, ics);

        if (ch.tns_present) applyTns(predFreq, ch, false);

        const lim = @min(ics.max_sfb, MAX_LTP_LONG_SFB);
        const offsets = ics.swb_offset;
        var sfb: usize = 0;
        while (sfb < lim) : (sfb += 1) {
            if (ltp.used[sfb]) {
                var k = offsets[sfb];
                while (k < offsets[sfb + 1]) : (k += 1) {
                    ch.coeffs[k] += predFreq[k];
                }
            }
        }
    }

    /// update_ltp：IMDCT 后把 buf_mdct 的过渡段存入 saved_ltp（复用 coeffs），
    /// 再平移 ltp_state 并接入 output + saved_ltp。
    fn updateLtp(self: *Aac, ch: *ChannelState) void {
        const ics = &ch.ics;
        const buf = &self.buf_mdct;
        const saved_ltp = ch.coeffs[0..1024];
        const sw0: []const f32 = if (ics.use_kb_window[0]) &rt.kbd_short_128 else &rt.sine_128;
        const lw0: []const f32 = if (ics.use_kb_window[0]) &rt.kbd_long_1024 else &rt.sine_1024;
        const ws0 = ics.window_sequence[0];

        if (ws0 == 2) { // EIGHT_SHORT
            @memcpy(saved_ltp[0..512], ch.saved[0..512]);
            @memset(saved_ltp[576..1024], 0);
            vectorFmulReverse(saved_ltp[448..512], buf[960..1024], sw0[64..128], 64);
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                saved_ltp[i + 512] = buf[1023 - i] * sw0[63 - i];
            }
        } else if (ws0 == 1) { // LONG_START
            @memcpy(saved_ltp[0..448], buf[512..960]);
            @memset(saved_ltp[576..1024], 0);
            vectorFmulReverse(saved_ltp[448..512], buf[960..1024], sw0[64..128], 64);
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                saved_ltp[i + 512] = buf[1023 - i] * sw0[63 - i];
            }
        } else { // LONG_STOP / ONLY_LONG
            vectorFmulReverse(saved_ltp[0..512], buf[512..1024], lw0[512..1024], 512);
            var i: usize = 0;
            while (i < 512) : (i += 1) {
                saved_ltp[i + 512] = buf[1023 - i] * lw0[511 - i];
            }
        }

        @memcpy(ch.ltp_state[0..1024], ch.ltp_state[1024..2048]);
        @memcpy(ch.ltp_state[1024..2048], ch.output[0..1024]);
        @memcpy(ch.ltp_state[2048..3072], saved_ltp);
    }

    // ---------------- 声道耦合（CCE 应用） ----------------

    /// 依赖耦合（BEFORE_TNS / BETWEEN_TNS_AND_IMDCT）：谱域相加 dest += gain*src
    fn applyDependentCoupling(self: *Aac, target: *ChannelState, cce: *Che, index: usize) void {
        _ = self;
        const ics = &cce.ch[0].ics;
        const offsets = ics.swb_offset;
        var idx: usize = 0;
        var base: usize = 0;
        var g: usize = 0;
        while (g < ics.num_window_groups) : (g += 1) {
            var sfb: usize = 0;
            while (sfb < ics.max_sfb) : (sfb += 1) {
                if (cce.ch[0].band_type[idx] != ZERO_BT) {
                    const gain = cce.coup.gain[index][idx];
                    var group: usize = 0;
                    while (group < ics.group_len[g]) : (group += 1) {
                        var k = offsets[sfb];
                        while (k < offsets[sfb + 1]) : (k += 1) {
                            target.coeffs[(base + group) * 128 + k] += gain * cce.ch[0].coeffs[(base + group) * 128 + k];
                        }
                    }
                }
                idx += 1;
            }
            base += @as(usize, ics.group_len[g]) * 128;
        }
    }

    /// 独立耦合（AFTER_IMDCT）：时域相加 dest += gain*src。
    /// 注：SBR 上采样路径（CCE+SBR 极罕见）暂按核心 1024 输出近似。
    fn applyIndependentCoupling(self: *Aac, target: *ChannelState, cce: *Che, index: usize) void {
        _ = self;
        const gain = cce.coup.gain[index][0];
        var i: usize = 0;
        while (i < 1024) : (i += 1) {
            target.output[i] += gain * cce.ch[0].output[i];
        }
    }

    /// 应用耦合：对 (type, elem_id) 目标元素，遍历所有 CCE，按 ch_select 施加对应索引增益。
    fn applyChannelCoupling(
        self: *Aac,
        che: *Che,
        ty: u8,
        elem_id: u8,
        coupling_point: u8,
        dependent: bool,
    ) void {
        var cce_i: usize = 0;
        while (cce_i < MAX_ELEM_ID) : (cce_i += 1) {
            const cce = self.che[2][cce_i] orelse continue;
            if (!cce.present) continue;
            if (cce.coup.coupling_point != coupling_point) continue;
            const coup = &cce.coup;
            var index: usize = 0;
            var c: usize = 0;
            while (c <= coup.num_coupled) : (c += 1) {
                if (coup.ty[c] == ty and coup.id_select[c] == elem_id) {
                    const cs = coup.ch_select[c];
                    if (cs != 1) {
                        if (dependent) self.applyDependentCoupling(&che.ch[0], cce, index) else self.applyIndependentCoupling(&che.ch[0], cce, index);
                        if (cs != 0) index += 1;
                    }
                    if (cs != 2) {
                        if (dependent) self.applyDependentCoupling(&che.ch[1], cce, index) else self.applyIndependentCoupling(&che.ch[1], cce, index);
                        index += 1;
                    }
                } else {
                    index += 1 + @as(usize, @intFromBool(coup.ch_select[c] == 3));
                }
            }
        }
    }

    // ---------------- 元素解码 ----------------

    fn resetChannel(che: *Che) void {
        che.ch[0].resetFrame();
        if (che.is_stereo) che.ch[1].resetFrame();
    }

    fn decodeIcs(self: *Aac, ch: *ChannelState, br: *BitReader, common_window: bool) Error!void {
        const global_gain: u32 = try br.readBits(8);
        if (!common_window) try self.decodeIcsInfo(ch, br);
        try decodeBandTypes(ch, br);
        try self.decodeScalefactors(ch, br, global_gain);
        dequantScalefactors(ch);


        var pulse: Pulse = .{};
        var pulse_present = false;
        const pulse_bit = try br.readBits(1);
        if (pulse_bit != 0) {
            if (ch.ics.window_sequence[0] == 2) {
                return error.Corrupt;
            }
            pulse_present = true;
            decodePulses(&pulse, br, ch.ics.swb_offset, ch.ics.num_swb) catch |e| {
                return e;
            };
        }
        ch.tns_present = (try br.readBits(1)) != 0;
        if (ch.tns_present) {
            decodeTns(ch, br) catch |e| {
                return e;
            };
        }
        const gain_bit = try br.readBits(1);
        if (gain_bit != 0) {
            // gain_control：SSR 专用（本解码器不支持 SSR profile）
            return error.UnsupportedFormat;
        }

        self.decodeSpectrumAndDequant(ch, br, if (pulse_present) &pulse else null) catch |e| {
            return e;
        };
    }

    fn decodeCpe(self: *Aac, che: *Che, br: *BitReader) Error!void {
        const common_window = (try br.readBits(1)) != 0;
        var ms_present: u2 = 0;
        if (common_window) {
            try self.decodeIcsInfo(&che.ch[0], br);
            const kb1 = che.ch[1].ics.use_kb_window[0];
            che.ch[1].ics = che.ch[0].ics;
            che.ch[1].ics.use_kb_window[1] = kb1;
            // 非 MAIN 且 ch1 需要预测时：紧跟 ch1 自己的 ltp.present + 字段（在 ms_present 之前）
            if (self.cfg.object_type == asc.AOT_AAC_LTP and che.ch[1].ics.predictor_present) {
                che.ch[1].ics.ltp.present = (try br.readBits(1)) != 0;
                if (che.ch[1].ics.ltp.present) try decodeLtpFields(&che.ch[1], br);
            }
            ms_present = @intCast(try br.readBits(2));
            if (ms_present == 3) return error.Corrupt;
            if (ms_present != 0) {
                che.max_sfb_ste = che.ch[0].ics.max_sfb;
                const max_idx = @as(usize, che.ch[0].ics.num_window_groups) * che.ch[0].ics.max_sfb;
                if (ms_present == 1) {
                    var idx: usize = 0;
                    while (idx < max_idx) : (idx += 1) {
                        che.ms_mask[idx] = (try br.readBits(1)) != 0;
                    }
                } else {
                    @memset(che.ms_mask[0..max_idx], true);
                }
            }
        }
        try self.decodeIcs(&che.ch[0], br, common_window);
        try self.decodeIcs(&che.ch[1], br, common_window);

        if (common_window and ms_present != 0) applyMidSideStereo(che);
        applyIntensityStereo(che, ms_present != 0);
    }

    /// CCE（coupling channel element，元素类型 2）：耦合声道。
    /// 解码耦合点/目标元素/增益；谱在 spectral_to_sample 应用到目标声道。
    fn decodeCce(self: *Aac, che: *Che, br: *BitReader) Error!void {
        const coup = &che.coup;
        coup.coupling_point = 2 * @as(u8, @intCast(try br.readBits(1)));
        coup.num_coupled = @intCast(try br.readBits(3));
        var num_gain: usize = 0;
        for (0..@as(usize, coup.num_coupled) + 1) |c| {
            num_gain += 1;
            coup.ty[c] = @intCast(try br.readBits(1)); // 1=CPE 0=SCE
            coup.id_select[c] = @intCast(try br.readBits(4));
            if (coup.ty[c] != 0) { // CPE
                coup.ch_select[c] = @intCast(try br.readBits(2));
                if (coup.ch_select[c] == 3) num_gain += 1;
            } else {
                coup.ch_select[c] = 2;
            }
        }
        const cp_extra = try br.readBits(1);
        coup.coupling_point += if (cp_extra != 0 or (coup.coupling_point >> 1) != 0) 1 else 0;

        const sign: u1 = @intCast(try br.readBits(1));
        const scale = cce_scale[try br.readBits(2)];

        // CCE 自身单声道：ICS 解码（含频谱）
        const sce = &che.ch[0];
        che.is_stereo = false;
        sce.resetFrame();
        try self.decodeIcs(sce, br, false);

        // 各目标耦合增益
        var c: usize = 0;
        while (c < num_gain) : (c += 1) {
            var idx: usize = 0;
            var cge: u1 = 1;
            var gain: i32 = 0;
            var gain_cache: f32 = 1.0;
            if (c != 0) {
                cge = if (coup.coupling_point == 3) 1 else @intCast(try br.readBits(1));
                if (cge != 0) {
                    gain = @as(i32, try self.vlc_sf.decode(br)) - 60;
                }
                gain_cache = cceGain(scale, gain);
            }
            if (coup.coupling_point == 3) { // AFTER_IMDCT：单一增益
                coup.gain[c][0] = gain_cache;
            } else {
                var g: usize = 0;
                while (g < sce.ics.num_window_groups) : (g += 1) {
                    var sfb: usize = 0;
                    while (sfb < sce.ics.max_sfb) : (sfb += 1) {
                        if (sce.band_type[idx] != ZERO_BT) {
                            if (cge == 0) {
                                const t0 = @as(i32, try self.vlc_sf.decode(br)) - 60;
                                if (t0 != 0) {
                                    var gain_acc = gain;
                                    gain_acc += t0;
                                    gain = gain_acc;
                                    if (sign != 0) {
                                        var s: i32 = 1;
                                        s -= 2 * (gain_acc & 1);
                                        gain_acc >>= 1;
                                        gain_cache = cceGain(scale, gain_acc) * @as(f32, @floatFromInt(s));
                                    }
                                }
                            }
                            coup.gain[c][idx] = gain_cache;
                        }
                        idx += 1;
                    }
                }
            }
        }
    }

    /// FIL 扩载荷：读取类型；SBR（EXT_SBR_DATA=13 / EXT_SBR_DATA_CRC=14）→ 解析。
    fn skipExtensionPayload(self: *Aac, br: *BitReader, cnt: u32) Error!void {
        if (cnt == 0) return;
        const extension_type = try br.readBits(4);
        const is_crc = extension_type == 14;
        if (extension_type == 13 or is_crc) {
            if (self.prev_elem_type == 0 or self.prev_elem_type == 1) {
                if (is_crc) _ = try br.readBits(10); // bs_sbr_crc_bits
                const sbr_cnt = if (is_crc) cnt - 1 else cnt;
                if (sbr_cnt > 0) {
                    try self.ensureSbr(); // SBR 扩展首次出现时惰性分配+初始化状态
                    const sbr = self.sbr.?;
                    const before = br.bit_pos;
                    sbr_mod.decodeExtension(sbr, br, sbr_cnt, self.prev_elem_type) catch {
                            // SBR 解析失败：降级跳过（extension_type 的 4bit 已消费，
                            // 剩余数据 sbr_cnt*8 - 4 bit；对齐 ffmpeg skip_bits_long(cnt*8-4)）
                        br.bit_pos = before;
                        try br.skipBits(sbr_cnt * 8 - 4);
                        return;
                    };
                    if (sbr.start != 0) {
                        self.sample_rate = @intCast(sbr.sample_rate); // HE-AAC：输出采样率 = SBR 采样率
                        // PS（参数立体声）：mono core → 双声道输出
                        if (sbr.ps_enabled and self.channels == 1) {
                            self.channels = 2;
                        }
                    }
                    // SBR 启用：只要有 SBR 扩展数据即启用（对齐 ffmpeg m4ac.sbr=1，
                    // 不依赖头已解析），使前导帧（start==0）也执行纯上采样 QMF 暖机
                    self.sbr_enabled = true;
                    return;
                }
            }
        }
        const remain: u32 = cnt * 8 - 4;
        try br.skipBits(remain);
    }

    // ---------------- PCE（program_config_element，chan_config=0） ----------------

    /// ---- ffmpeg PCE→AV 位置分配移植（aacdec.c assign_channels，layer0）----
    const PceRowSentinel: i16 = -1; // NONE
    const PceRowUnused: i16 = -2;
    // 每行 6 个 AV_CHAN 序号（ff_aac_channel_map[0][pos-1]）：
    // FRONT=[FC FLc FRc FL FR]  SIDE=[SL SR]  BACK=[BL BR BC]  LFE=[LFE LFE2]
    const pce_map_rows = [4][6]i16{
        .{ 2, 6, 7, 0, 1, PceRowSentinel },
        .{ PceRowUnused, 9, 10, PceRowSentinel, PceRowSentinel, PceRowSentinel },
        .{ PceRowUnused, 9, 10, 4, 5, 8 },
        .{ 3, 12, PceRowSentinel, PceRowSentinel, PceRowSentinel, PceRowSentinel },
    };
    const PcePosFront: u8 = 0;
    const PcePosSide: u8 = 1;
    const PcePosBack: u8 = 2;
    const PcePosLfe: u8 = 3;

    const PceOut = struct {
        cpe: [4 * MAX_ELEM_ID]u8 = undefined,
        tag: [4 * MAX_ELEM_ID]u8 = undefined,
        ty: [4 * MAX_ELEM_ID]u8 = undefined,
        bit: [4 * MAX_ELEM_ID]u64 = undefined,
        n: usize = 0,
    };

    /// count_paired_channels：统计一位置组可成对声道数（-1 = 结构非法）
    fn pceCountPaired(cpes: []const u1, pos: u8) i32 {
        var num: i32 = 0;
        var first_cpe = false;
        var sce_parity = false;
        for (cpes) |is_cpe| {
            if (is_cpe != 0) {
                if (sce_parity) {
                    if (pos == PcePosFront and !first_cpe) sce_parity = false else return -1;
                }
                num += 2;
                first_cpe = true;
            } else {
                num += 1;
                sce_parity = (sce_parity != (pos != PcePosLfe));
            }
        }
        if (sce_parity and pos == PcePosFront and first_cpe) return -1;
        return num;
    }

    /// assign_channels（layer0）：为一位置组元素分配 av_bits。成功 true。
    fn pceAssignGroup(
        out: *PceOut,
        cpes: []const u1,
        tags: []const u4,
        tys: []const u8,
        pos: u8,
    ) bool {
        const row = pce_map_rows[pos];
        const count = cpes.len;
        if (count == 0) return true;
        if (pos == PcePosLfe) {
            var j: usize = 0;
            for (0..count) |k| {
                if (j >= row.len or row[j] == PceRowSentinel) return false;
                out.cpe[out.n] = cpes[k];
                out.tag[out.n] = tags[k];
                out.ty[out.n] = tys[k];
                out.bit[out.n] = if (row[j] == PceRowUnused) 0 else @as(u64, 1) << @intCast(row[j]);
                out.n += 1;
                j += 1;
            }
            return true;
        }
        var nb = pceCountPaired(cpes, pos);
        if (nb < 0 or nb > 5) return false;
        var i: usize = 0;
        var jslot: usize = 0;
        if ((nb & 1) != 0) {
            if (row[0] == PceRowSentinel) return false;
            if (row[0] == PceRowUnused) return true; // UNUSED：放弃该组单声道
            out.cpe[out.n] = cpes[i];
            out.tag[out.n] = tags[i];
            out.ty[out.n] = tys[i];
            out.bit[out.n] = @as(u64, 1) << @intCast(row[0]);
            out.n += 1;
            i += 1;
            nb -= 1;
        }
        jslot = if (pos != PcePosSide and nb <= 3) @as(usize, 3) else 1;
        while (nb >= 2) : (nb -= 2) {
            if (jslot + 1 >= row.len) return false;
            if (row[jslot] == PceRowSentinel or row[jslot + 1] == PceRowSentinel) return false;
            const b1: u64 = @as(u64, 1) << @intCast(row[jslot]);
            const b2: u64 = @as(u64, 1) << @intCast(row[jslot + 1]);
            if (cpes[i] != 0) {
                out.cpe[out.n] = 1;
                out.tag[out.n] = tags[i];
                out.ty[out.n] = tys[i];
                out.bit[out.n] = b1 | b2;
                out.n += 1;
                i += 1;
            } else {
                if (i + 1 >= cpes.len) return false;
                out.cpe[out.n] = 0;
                out.tag[out.n] = tags[i];
                out.ty[out.n] = tys[i];
                out.bit[out.n] = b1;
                out.n += 1;
                out.cpe[out.n] = 0;
                out.tag[out.n] = tags[i + 1];
                out.ty[out.n] = tys[i + 1];
                out.bit[out.n] = b2;
                out.n += 1;
                i += 2;
            }
            jslot += 2;
        }
        if ((nb & 1) != 0) {
            if (row[5] == PceRowSentinel or row[5] == PceRowUnused) return false;
            out.cpe[out.n] = cpes[i];
            out.tag[out.n] = tags[i];
            out.ty[out.n] = tys[i];
            out.bit[out.n] = @as(u64, 1) << @intCast(row[5]);
            out.n += 1;
            i += 1;
            nb -= 1;
        }
        return nb == 0;
    }


    /// 解析 program_config_element（元素类型 5），构建动态声道布局。
    /// chan_config=0 时布局由 PCE 决定；PCE 一般出现在首帧，跨帧缓存。
    fn parsePce(self: *Aac, br: *BitReader) Error!void {
        _ = try br.readBits(2); // object_type
        _ = try br.readBits(4); // sampling_index
        const num_front: usize = @intCast(try br.readBits(4));
        const num_side: usize = @intCast(try br.readBits(4));
        const num_back: usize = @intCast(try br.readBits(4));
        const num_lfe: usize = @intCast(try br.readBits(2));
        const num_assoc: usize = @intCast(try br.readBits(3));
        const num_cc: usize = @intCast(try br.readBits(4));

        if ((try br.readBits(1)) != 0) _ = try br.readBits(4); // mono_mixdown_tag
        if ((try br.readBits(1)) != 0) _ = try br.readBits(4); // stereo_mixdown_tag
        if ((try br.readBits(1)) != 0) _ = try br.readBits(3); // mixdown_coeff + pseudo_surround

        if (num_front + num_side + num_back + num_lfe + num_cc > MAX_ELEM_ID * 4) return error.Corrupt;

        // 读出元素表（position → (is_cpe, tag)）
        var front: [16]struct { cpe: u1, tag: u4 } = undefined;
        var side: [16]struct { cpe: u1, tag: u4 } = undefined;
        var back: [16]struct { cpe: u1, tag: u4 } = undefined;
        var lfe: [4]struct { cpe: u1, tag: u4 } = undefined;
        var cc: [16]struct { cpe: u1, tag: u4 } = undefined;

        for (0..num_front) |k| front[k] = .{ .cpe = @intCast(try br.readBits(1)), .tag = @intCast(try br.readBits(4)) };
        for (0..num_side) |k| side[k] = .{ .cpe = @intCast(try br.readBits(1)), .tag = @intCast(try br.readBits(4)) };
        for (0..num_back) |k| back[k] = .{ .cpe = @intCast(try br.readBits(1)), .tag = @intCast(try br.readBits(4)) };
        for (0..num_lfe) |k| lfe[k] = .{ .cpe = @intCast(try br.readBits(1)), .tag = @intCast(try br.readBits(4)) };
        _ = try br.skipBits(@intCast(4 * num_assoc));
        for (0..num_cc) |k| cc[k] = .{ .cpe = @intCast(try br.readBits(1)), .tag = @intCast(try br.readBits(4)) };



        // ---- ffmpeg assign_channels/sniff_channel_order 移植：front→side→back→lfe
        // layer0 分配 av_bits，按 av_bits 稳定排序 → 输出声道序（= ffmpeg native 序）----
        const TypeCpeF: u8 = 1;
        var out = PceOut{};
        const Elem = struct { cpe: u1, tag: u4, ty: u8 };
        var fse: [16]Elem = undefined;
        for (0..num_front) |k| fse[k] = .{ .cpe = front[k].cpe, .tag = front[k].tag, .ty = if (front[k].cpe != 0) TypeCpeF else 0 };
        var sse: [16]Elem = undefined;
        for (0..num_side) |k| sse[k] = .{ .cpe = side[k].cpe, .tag = side[k].tag, .ty = if (side[k].cpe != 0) TypeCpeF else 0 };
        var bse: [16]Elem = undefined;
        for (0..num_back) |k| bse[k] = .{ .cpe = back[k].cpe, .tag = back[k].tag, .ty = if (back[k].cpe != 0) TypeCpeF else 0 };
        var lse: [4]Elem = undefined;
        for (0..num_lfe) |k| lse[k] = .{ .cpe = lfe[k].cpe, .tag = lfe[k].tag, .ty = 3 };

        {
            var cpes: [16]u1 = undefined;
            var tags: [16]u4 = undefined;
            var tys: [16]u8 = undefined;
            const groups = [_]struct { e: []const Elem, pos: u8 }{
                .{ .e = fse[0..num_front], .pos = PcePosFront },
                .{ .e = sse[0..num_side], .pos = PcePosSide },
                .{ .e = bse[0..num_back], .pos = PcePosBack },
                .{ .e = lse[0..num_lfe], .pos = PcePosLfe },
            };
            var ok = true;
            for (groups) |g| {
                for (g.e, 0..) |el, k| { cpes[k] = el.cpe; tags[k] = el.tag; tys[k] = el.ty; }
                if (!pceAssignGroup(&out, cpes[0..g.e.len], tags[0..g.e.len], tys[0..g.e.len], g.pos)) ok = false;
            }
            if (!ok or out.n == 0) return error.Corrupt;
        }

        // 稳定排序（av_bits 升序）
        var order: [4 * MAX_ELEM_ID]usize = undefined;
        for (0..out.n) |k| order[k] = k;
        var swapped = true;
        while (swapped) {
            swapped = false;
            var k: usize = 1;
            while (k < out.n) : (k += 1) {
                if (out.bit[order[k - 1]] > out.bit[order[k]]) {
                    const tmpi = order[k - 1];
                    order[k - 1] = order[k];
                    order[k] = tmpi;
                    swapped = true;
                }
            }
        }
        var n: usize = 0;
        var cur: usize = 0;
        for (0..out.n) |k| {
            const e = order[k];
            self.layout_buf[n] = .{ .ty = out.ty[e], .id = out.tag[e], .out0 = @intCast(cur), .nch = if (out.cpe[e] != 0) 2 else 1 };
            cur += if (out.cpe[e] != 0) @as(usize, 2) else 1;
            n += 1;
        }
        // cc（coupling）不是输出声道（对应 CCE），不加入布局

        self.layout_len = n;
        self.layout = self.layout_buf[0..n];
        self.channels = @intCast(cur);

        // 尾部：字节对齐 + comment 字段（首字节为长度）
        br.alignToByte();
        const comment_len: usize = @intCast(try br.readBits(8));
        try br.skipBits(@intCast(comment_len * 8));
    }

    /// 解码一个完整 raw_data_block（已定位在元素首部），
    /// 输出交错 s16 追加到 self.out_buf。
    pub fn decodeFrame(self: *Aac, br: *BitReader) Error!void {
                var audio_found = false;
        var elem_type_raw = br.readBits(3) catch return error.Corrupt;
        var guard: usize = 0;
        while (elem_type_raw != 7) { // TYPE_END
            guard += 1;
            if (guard > 64) return error.Corrupt;
            // id_syn_ele 后必跟 4 位 element_id（所有元素类型，含 FIL/DSE）
            const elem_id: u4 = @intCast(br.readBits(4) catch return error.Corrupt);
            switch (elem_type_raw) {
                0 => { // SCE
                    const che = try self.getChe(0, elem_id);
                    che.is_stereo = false;
                    che.ch[0].resetFrame();
                    che.present = true;
                    try self.decodeIcs(&che.ch[0], br, false);
                    audio_found = true;
                    self.prev_elem_type = 0;
                },
                1 => { // CPE
                    const che = try self.getChe(1, elem_id);
                    che.is_stereo = true;
                    che.ch[0].resetFrame();
                    che.ch[1].resetFrame();
                    che.present = true;
                    try self.decodeCpe(che, br);
                    audio_found = true;
                    self.prev_elem_type = 1;
                },
                3 => { // LFE（单声道元素）
                    const che = try self.getChe(3, elem_id);
                    che.is_stereo = false;
                    che.ch[0].resetFrame();
                    che.present = true;
                    try self.decodeIcs(&che.ch[0], br, false);
                    audio_found = true;
                    self.prev_elem_type = 3;
                },
                4 => { // DSE
                    const byte_align = (br.readBits(1) catch return error.Corrupt) != 0;
                    var count: u32 = br.readBits(8) catch return error.Corrupt;
                    if (count == 255) count += br.readBits(8) catch return error.Corrupt;
                    if (byte_align) br.alignToByte();
                    br.skipBits(count * 8) catch return error.Corrupt;
                },
                5 => { // PCE（program_config_element，chan_config=0 时定义布局）
                    try self.parsePce(br);
                },
                2 => { // CCE（coupling channel element，耦合声道；不直接输出）
                    const che = try self.getChe(2, elem_id);
                    che.is_stereo = false;
                    che.ch[0].resetFrame();
                    che.present = true;
                    try self.decodeCce(che, br);
                },
                6 => { // FIL：count 即 elem_id；==15 时扩展 8 位（+15-1）
                    var count: u32 = elem_id;
                    if (count == 15) count = count + (br.readBits(8) catch return error.Corrupt) - 1;
                    if (br.remainingBits() < count * 8) return error.Corrupt;
                    try self.skipExtensionPayload(br, count);
                },
                else => unreachable,
            }
            if (br.remainingBits() < 3) return error.Corrupt;
            elem_type_raw = br.readBits(3) catch return error.Corrupt;

        }

        if (!audio_found) return;

        // chan_config=0 且无 PCE（如部分 m4a 的 -aac_pce 怪癖输出）：
        // 从帧内出现的元素推导默认布局（按类型序：SCE→1ch、CPE→2ch、LFE→1ch）
        if (self.channels == 0) {
            var out: usize = 0;
            var n: usize = 0;
            for (0..MAX_ELEM_ID) |id| {
                if (self.che[0][id]) |c| {
                    if (c.present) {
                        self.layout_buf[n] = .{ .ty = 0, .id = @intCast(id), .out0 = @intCast(out), .nch = 1 };
                        out += 1;
                        n += 1;
                    }
                }
            }
            for (0..MAX_ELEM_ID) |id| {
                if (self.che[1][id]) |c| {
                    if (c.present) {
                        self.layout_buf[n] = .{ .ty = 1, .id = @intCast(id), .out0 = @intCast(out), .nch = 2 };
                        out += 2;
                        n += 1;
                    }
                }
            }
            for (0..MAX_ELEM_ID) |id| {
                if (self.che[3][id]) |c| {
                    if (c.present) {
                        self.layout_buf[n] = .{ .ty = 3, .id = @intCast(id), .out0 = @intCast(out), .nch = 1 };
                        out += 1;
                        n += 1;
                    }
                }
            }
            self.layout_len = n;
            self.layout = self.layout_buf[0..n];
            self.channels = @intCast(out);
        }

        // spectral_to_sample：按布局对每个元素做 耦合 + TNS + IMDCT + SBR + 耦合
        const CpBeforeTns: u8 = 0;
        const CpBetweenTnsImdct: u8 = 1;
        const CpAfterImdct: u8 = 3;

        // 先处理 CCE（type 2，不在布局内）：AFTER_IMDCT 点需先 IMDCT 备好耦合输出
        for (0..MAX_ELEM_ID) |cce_id| {
            const cce = self.che[2][cce_id] orelse continue;
            if (cce.present and cce.coup.coupling_point == CpAfterImdct) {
                if (cce.ch[0].tns_present) applyTns(cce.ch[0].coeffs[0..], &cce.ch[0], true);
                self.imdctAndWindowing(&cce.ch[0]);
            }
        }

        var le_i: usize = 0;
        for (self.layout) |le| {
            le_i += 1;
            const che = self.che[le.ty][le.id] orelse continue;
            if (!che.present) continue;
            const nch = che.is_stereo;
            // BEFORE_TNS 耦合（依赖：谱域相加）
            self.applyChannelCoupling(che, le.ty, le.id, CpBeforeTns, true);
            // AAC Main 预测器（predictor 在耦合后、TNS 前应用）
            // ffmpeg 对 MAIN 每帧都调 apply_prediction（decode_ics/decode_cpe 无条件）；
            // 无 predictor_present 的帧也推进预测器状态，故不能按 present 门控
            if (self.cfg.object_type == asc.AOT_AAC_MAIN) self.applyPrediction(&che.ch[0]);
            if (nch and self.cfg.object_type == asc.AOT_AAC_MAIN) self.applyPrediction(&che.ch[1]);
            // AAC LTP：apply_ltp（在耦合后、TNS 前；对齐 ffmpeg spectral_to_sample）
            if (self.cfg.object_type == asc.AOT_AAC_LTP) {
                if (che.ch[0].ics.predictor_present) {
                    if (che.ch[0].ics.ltp.present) self.applyLtp(&che.ch[0]);
                    if (nch and che.ch[1].ics.ltp.present) self.applyLtp(&che.ch[1]);
                }
            }
            if (che.ch[0].tns_present) applyTns(che.ch[0].coeffs[0..], &che.ch[0], true);
            if (nch and che.ch[1].tns_present) applyTns(che.ch[1].coeffs[0..], &che.ch[1], true);
            // BETWEEN_TNS_AND_IMDCT 耦合（依赖）
            self.applyChannelCoupling(che, le.ty, le.id, CpBetweenTnsImdct, true);
            self.imdctAndWindowing(&che.ch[0]);
            // AAC LTP：IMDCT 后立即更新该声道 ltp_state（buf_mdct 共享，须逐声道紧随）
            if (self.cfg.object_type == asc.AOT_AAC_LTP) self.updateLtp(&che.ch[0]);
            if (nch) {
                self.imdctAndWindowing(&che.ch[1]);
                if (self.cfg.object_type == asc.AOT_AAC_LTP) self.updateLtp(&che.ch[1]);
            }
            // SBR：对每个 che 的声道做高频重建（HE-AAC 上采样到 2×）
            if (self.sbr_enabled and (le.ty == 0 or le.ty == 1)) {
                if (self.sbr) |sbr| {
                    try sbr_mod.apply(sbr, le.ty, che.ch[0].output[0..1024], che.ch[1].output[0..1024], 16, &self.sbr_buf, &self.sbr_buf2);
                }
            }
            // AFTER_IMDCT 耦合（独立：时域相加）
            self.applyChannelCoupling(che, le.ty, le.id, CpAfterImdct, false);
            che.present = false;
        }
        // 清除 CCE present
        for (0..MAX_ELEM_ID) |cce_id| {
            if (self.che[2][cce_id]) |cce| cce.present = false;
        }

        // 打包 s16 交错（按布局 out0 顺序，多声道；PS 时输出 L/R 双声道）
        const n: usize = if (self.sbr_enabled) self.frame_samples * 2 else self.frame_samples;
        const ps_mode = self.sbr_enabled and self.sbr != null and self.sbr.?.ps_enabled;
        const chn: usize = if (ps_mode) 2 else self.channels;
        try self.out_buf.ensureUnusedCapacity(self.gpa, n * chn * 2);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // 按 out0 升序输出各声道（FL FR FC LFE BL BR ...）
            var out_idx: usize = 0;
            while (out_idx < chn) : (out_idx += 1) {
                var v: i16 = 0;
                if (ps_mode) {
                    // PS：mono core → L/R 立体声
                    v = if (out_idx == 0) floatToS16(self.sbr_buf[i]) else floatToS16(self.sbr_buf2[i]);
                } else {
                    // 找布局中 out0 == out_idx 的元素声道（元素从未出现 → 槽位
                    // 未分配，输出 0，等价原 open 期全量清零语义）
                    for (self.layout) |le| {
                        const che = self.che[le.ty][le.id];
                        if (self.sbr_enabled and (le.ty == 0 or le.ty == 1)) {
                            if (le.out0 == out_idx) {
                                v = floatToS16(self.sbr_buf[i]);
                                break;
                            }
                            if (le.nch == 2 and le.out0 + 1 == out_idx) {
                                v = floatToS16(self.sbr_buf2[i]);
                                break;
                            }
                        }
                        if (le.out0 == out_idx) {
                            v = if (che) |c| floatToS16(c.ch[0].output[i]) else 0;
                            break;
                        }
                        if (le.nch == 2 and le.out0 + 1 == out_idx) {
                            v = if (che) |c| floatToS16(c.ch[1].output[i]) else 0;
                            break;
                        }
                    }
                }
                const vu: u16 = @bitCast(v);
                self.out_buf.appendSliceAssumeCapacity(&.{ @truncate(vu), @truncate(vu >> 8) });
            }
        }
        self.pos_samples += n;
        self.stat_frames += 1;
    }
};

/// 声道布局元素（chan_config 映射；对齐 FFmpeg ff_aac_channel_layout_map + sniff 排序）
const LayoutElem = struct {
    /// 元素类型（0=SCE 1=CPE 3=LFE）
    ty: u8,
    /// 元素 id
    id: u8,
    /// 输出声道起始序号（按 AV_CHAN 排序：FL0 FR1 FC2 LFE3 BL4 BR5 SL6 SR7）
    out0: u8,
    /// 本元素声道数（1 或 2）
    nch: u8,
};

/// 各 chan_config 的元素序列（索引 0 未用；chan_config = 数组索引）
const chan_layouts = [_][]const LayoutElem{
    &.{}, // 0
    &.{ .{ .ty = 0, .id = 0, .out0 = 0, .nch = 1 } }, // 1: mono (single out channel)
    &.{ .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 } }, // 2: FL FR
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 } }, // 3: FC FL FR
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 0, .id = 1, .out0 = 4, .nch = 1 } }, // 4: FC FL FR BL
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 1, .id = 1, .out0 = 4, .nch = 2 } }, // 5: FC FL FR BL BR
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 1, .id = 1, .out0 = 4, .nch = 2 }, .{ .ty = 3, .id = 0, .out0 = 3, .nch = 1 } }, // 6: FC FL FR BL BR LFE
    &.{ .{ .ty = 0, .id = 0, .out0 = 4, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 1, .id = 1, .out0 = 2, .nch = 2 }, .{ .ty = 1, .id = 2, .out0 = 5, .nch = 2 }, .{ .ty = 3, .id = 0, .out0 = 3, .nch = 1 } }, // 7: FC FL FR FLC/FRC BL BR LFE (7.1 wide)
    &.{}, // 8
    &.{}, // 9
    &.{}, // 10
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 1, .id = 1, .out0 = 4, .nch = 2 }, .{ .ty = 1, .id = 2, .out0 = 6, .nch = 2 }, .{ .ty = 3, .id = 0, .out0 = 3, .nch = 1 } }, // 11: FC FL FR BL BR SL SR LFE
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 1, .id = 1, .out0 = 6, .nch = 2 }, .{ .ty = 1, .id = 2, .out0 = 4, .nch = 2 }, .{ .ty = 3, .id = 0, .out0 = 3, .nch = 1 } }, // 12: FC FL FR SL SR BL BR LFE
    &.{}, // 13
    &.{ .{ .ty = 0, .id = 0, .out0 = 2, .nch = 1 }, .{ .ty = 1, .id = 0, .out0 = 0, .nch = 2 }, .{ .ty = 1, .id = 1, .out0 = 4, .nch = 2 }, .{ .ty = 3, .id = 0, .out0 = 3, .nch = 1 }, .{ .ty = 1, .id = 2, .out0 = 6, .nch = 2 } }, // 14: FC FL FR BL BR LFE FLC/FRC
};

/// 最大声道数（7.1 = 8）
const MAX_CH = 8;

const Che = struct {
    is_stereo: bool = false,
    present: bool = false,
    ch: [2]ChannelState = .{ .{}, .{} },
    ms_mask: [MAX_GROUPS * MAX_SFB]bool = [_]bool{false} ** (MAX_GROUPS * MAX_SFB),
    max_sfb_ste: u8 = 0,
    coup: Coupling = .{},
};

/// 声道耦合（CCE）状态
const Coupling = struct {
    coupling_point: u8 = 0, // 0=BEFORE_TNS 1=BETWEEN_TNS_AND_IMDCT 3=AFTER_IMDCT
    num_coupled: u8 = 0,
    ty: [8]u8 = [_]u8{0} ** 8, // 0=SCE 1=CPE
    id_select: [8]u8 = [_]u8{0} ** 8,
    ch_select: [8]u8 = [_]u8{0} ** 8,
    gain: [8][MAX_GROUPS * MAX_SFB]f32 = [_][MAX_GROUPS * MAX_SFB]f32{[_]f32{0} ** (MAX_GROUPS * MAX_SFB)} ** 8,
};

/// cce_scale（耦合增益基数；对齐 aacdec_float.c）
const cce_scale = [_]f32{
    1.09050773266525765921,
    1.18920711500272106672,
    std.math.sqrt2,
    2,
};

/// 耦合增益：GET_GAIN(scale, gain) = scale^(-gain)
inline fn cceGain(scale: f32, gain: i32) f32 {
    return std.math.pow(f32, scale, -@as(f32, @floatFromInt(gain)));
}

const ChannelState = struct {
    ics: Ics = .{},
    band_type: [MAX_GROUPS * MAX_SFB]u8 = [_]u8{0} ** (MAX_GROUPS * MAX_SFB),
    sfo: [MAX_GROUPS * MAX_SFB]i32 = [_]i32{0} ** (MAX_GROUPS * MAX_SFB),
    sf: [MAX_GROUPS * MAX_SFB]f32 = [_]f32{0} ** (MAX_GROUPS * MAX_SFB),
    coeffs: [FRAME_LEN]f32 = [_]f32{0} ** FRAME_LEN,
    // output 需 2048：低 1024 为本帧样本，高 1024 供 LTP predTime（对齐 FFmpeg sce->output[2048]）
    output: [2 * FRAME_LEN]f32 = [_]f32{0} ** (2 * FRAME_LEN),
    saved: [FRAME_LEN]f32 = [_]f32{0} ** FRAME_LEN,
    tns_present: bool = false,
    tns_n_filt: [MAX_GROUPS]u8 = [_]u8{0} ** MAX_GROUPS,
    tns_length: [MAX_GROUPS][4]u8 = [_][4]u8{[_]u8{0} ** 4} ** MAX_GROUPS,
    tns_order: [MAX_GROUPS][4]u8 = [_][4]u8{[_]u8{0} ** 4} ** MAX_GROUPS,
    tns_direction: [MAX_GROUPS][4]bool = [_][4]bool{[_]bool{false} ** 4} ** MAX_GROUPS,
    tns_coef: [MAX_GROUPS][4][TNS_MAX_ORDER]f32 =
        [_][4][TNS_MAX_ORDER]f32{[_][TNS_MAX_ORDER]f32{[_]f32{0} ** TNS_MAX_ORDER} ** 4} ** MAX_GROUPS,
    // AAC Main 预测器状态（672 个预测器）+ LTP 长时预测状态（3072 样本）
    predictor_state: [MAX_PREDICTORS]PredictorState = [_]PredictorState{.{}} ** MAX_PREDICTORS,
    ltp_state: [3072]f32 = [_]f32{0} ** 3072,

    fn resetFrame(self: *ChannelState) void {
        @memset(&self.coeffs, 0);
        self.tns_present = false;
        // 预测器状态跨帧保留（不在此重置）
    }
};

const Ics = struct {
    window_sequence: [2]u2 = .{ 0, 0 },
    use_kb_window: [2]bool = .{ false, false },
    max_sfb: u8 = 0,
    num_swb: u8 = 0,
    num_windows: u8 = 1,
    num_window_groups: u8 = 1,
    group_len: [MAX_GROUPS]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
    swb_offset: []const u16 = &.{},
    tns_max_bands: u8 = 0,
    // AAC Main（AOT 1）预测器
    predictor_present: bool = false,
    predictor_reset_group: u8 = 0,
    predictor_initialized: bool = false,
    prediction_used: [48]bool = [_]bool{false} ** 48,
    // LTP（AOT 4）长时预测
    ltp: Ltp = .{},
};

/// 长时预测状态（LTP）
const Ltp = struct {
    present: bool = false,
    lag: u16 = 0,
    coef: f32 = 0,
    used: [40]bool = [_]bool{false} ** 40,
};

/// AAC Main 频域预测器状态（对齐 aacdec_float_prediction.h）
const PredictorState = struct {
    cor0: f32 = 0,
    cor1: f32 = 0,
    var0: f32 = 1,
    var1: f32 = 1,
    r0: f32 = 0,
    r1: f32 = 0,
    k1: f32 = 0,
    x_est: f32 = 0,
};

const MAX_PREDICTORS: usize = 672;
const MAX_LTP_LONG_SFB: usize = 40;

/// ff_aac_pred_sfb_max[13]（各采样率索引的预测 sfb 上限）
const pred_sfb_max = [13]u8{ 33, 33, 38, 40, 40, 40, 41, 41, 37, 37, 37, 34, 34 };

/// ff_ltp_coef[8]（LTP 预测系数）
const ltp_coef = [8]f32{
    0.570829,
    0.696616,
    0.813004,
    0.911304,
    0.984900,
    1.067894,
    1.194601,
    1.369533,
};

// ---- AAC Main 预测器（aacdec_float_prediction.h）----

inline fn flt16Round(pf: f32) f32 {
    const i: u32 = @as(u32, @bitCast(pf)) +% 0x00008000 & 0xFFFF0000;
    return @bitCast(i);
}
inline fn flt16Even(pf: f32) f32 {
    // C: (i + 0x7FFF + (i & 0x10000U >> 16)) & 0xFFFF0000U
    // 优先级：& 低于 >>，故 (i & 0x10000U >> 16) == (i & 1)，须显式括号避免把整个和右移
    const b: u32 = @as(u32, @bitCast(pf));
    const r: u32 = (b +% 0x00007FFF +% (b & 0x00000001)) & 0xFFFF0000;
    return @bitCast(r);
}
inline fn flt16Trunc(pf: f32) f32 {
    const i: u32 = @as(u32, @bitCast(pf)) & 0xFFFF0000;
    return @bitCast(i);
}

fn predict(ps: *PredictorState, coef: *f32, output_enable: bool) void {
    const a: f32 = 0.953125;
    const alpha: f32 = 0.90625;
    const r0 = ps.r0;
    const r1 = ps.r1;
    const cor0 = ps.cor0;
    const cor1 = ps.cor1;
    const var0 = ps.var0;
    const var1 = ps.var1;
    const k1: f32 = if (var0 > 1) cor0 * flt16Even(a / var0) else 0;
    const k2: f32 = if (var1 > 1) cor1 * flt16Even(a / var1) else 0;
    const pv: f32 = flt16Round(k1 * r0 + k2 * r1);
    if (output_enable) coef.* += pv;
    const e0 = coef.*;
    const e1 = e0 - k1 * r0;
    ps.cor1 = flt16Trunc(alpha * cor1 + r1 * e1);
    ps.var1 = flt16Trunc(alpha * var1 + 0.5 * (r1 * r1 + e1 * e1));
    ps.cor0 = flt16Trunc(alpha * cor0 + r0 * e0);
    ps.var0 = flt16Trunc(alpha * var0 + 0.5 * (r0 * r0 + e0 * e0));
    ps.r1 = flt16Trunc(a * (r0 - k1 * e0));
    ps.r0 = flt16Trunc(a * e0);
}

fn resetPredictState(ps: *PredictorState) void {
    ps.r0 = 0;
    ps.r1 = 0;
    ps.cor0 = 0;
    ps.cor1 = 0;
    ps.var0 = 1;
    ps.var1 = 1;
}

fn lcgRandom(prev: u32) i32 {
    const v: u32 = prev *% 1664525 +% 1013904223;
    return @bitCast(v);
}

extern "c" fn lrintf(x: f32) c_long;

inline fn floatToS16(v: f32) i16 {
    // 对齐 FFmpeg swresample：av_clip_int16(lrintf(x*32768))（lrintf = 最近偶数舍入）
    const r: c_long = lrintf(v * 32768.0);
    return @intCast(std.math.clamp(r, -32768, 32767));
}

/// chan_config 声道总数（求和布局元素 nch）
fn chanLayoutChannels(chan_config: u4) u8 {
    var total: u8 = 0;
    for (chan_layouts[chan_config]) |e| total += e.nch;
    return total;
}


fn samplingIndexForRate(rate: u32) ?usize {
    for (t.sample_rates, 0..) |sr, i| {
        if (sr == rate) return i;
    }
    return null;
}

// ---------------- 测试（Level-2 内存布局：元素槽位/SBR 独立堆分配） ----------------

const testing = std.testing;

/// 测试位写入器（MSB-first，appendBits 语义同 m4a.zig TestBits）
const TestBw = struct {
    bytes: std.ArrayList(u8) = .empty,
    nbits: usize = 0,

    fn deinit(self: *TestBw) void {
        self.bytes.deinit(testing.allocator);
    }

    fn put(self: *TestBw, v: u64, n: usize) !void {
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const bit: u8 = if (n - 1 - k < 64) @intCast((v >> @intCast(n - 1 - k)) & 1) else 0;
            if (self.nbits % 8 == 0) try self.bytes.append(testing.allocator, 0);
            if (bit != 0) self.bytes.items[self.nbits / 8] |= @as(u8, 1) << @intCast(7 - self.nbits % 8);
            self.nbits += 1;
        }
    }

    /// 字节对齐并交出缓冲
    fn toFrame(self: *TestBw) ![]u8 {
        if (self.nbits % 8 != 0) try self.put(0, 8 - self.nbits % 8);
        return self.bytes.toOwnedSlice(testing.allocator);
    }
};

/// 追加一个全零谱的通道帧元素（ICS：max_sfb=0，无 section/sf/spectrum 数据）
fn putZeroIcs(w: *TestBw, common_window: bool) !void {
    try w.put(0, 8); // global_gain
    if (!common_window) {
        // ics_info：reserved(1) ws=ONLY_LONG(2) kb(1) max_sfb=0(6) predictor_present(1)
        try w.put(0, 11);
    }
    // section/scalefactor：max_sfb=0 → 无位
    try w.put(0, 1); // pulse_present
    try w.put(0, 1); // tns_present
    try w.put(0, 1); // gain_control
}

/// 单声道零谱帧：元素类型 ty（0=SCE 3=LFE）、tag
fn zeroSceFrame(ty: u8, tag: u4) ![]u8 {
    var w = TestBw{};
    errdefer w.deinit();
    try w.put(ty, 3);
    try w.put(tag, 4);
    try putZeroIcs(&w, false);
    try w.put(7, 3); // END
    return w.toFrame();
}

/// 立体声零谱 CPE 帧（common_window=1，ms_present=0），tag
fn zeroCpeFrame(tag: u4) ![]u8 {
    var w = TestBw{};
    errdefer w.deinit();
    try w.put(1, 3);
    try w.put(tag, 4);
    try w.put(1, 1); // common_window
    try w.put(0, 11); // ics_info（ch0）
    try w.put(0, 2); // ms_present
    try putZeroIcs(&w, true); // ch0
    try putZeroIcs(&w, true); // ch1
    try w.put(7, 3);
    return w.toFrame();
}

fn lcCfg(chan_config: u4) asc.M4ACfg {
    return .{
        .object_type = asc.AOT_AAC_LC,
        .sample_rate = 48000,
        .sampling_index = 3,
        .chan_config = chan_config,
        .sbr = -1,
        .ps = -1,
    };
}

/// 用指定帧解码一个 raw_data_block
fn decodeFrameBytes(aac: *Aac, frame: []const u8) Error!void {
    var br = BitReader.init(frame);
    try aac.decodeFrame(&br);
}

/// 测试用释放：out_buf 归容器所有（initCommon 重入不释放它），测试里代行容器职责
fn testDeinit(aac: *Aac, a: std.mem.Allocator) void {
    aac.out_buf.deinit(a);
    aac.deinit();
}

test "AAC Level-2: 结构本体不再内嵌重型网格（< 96KB）" {
    // 旧布局：64 槽 × ~126KB ChannelState 网格 + 内嵌 SBR ≈ 8.3MB；
    // Level-2 后仅余共享工作区（mdct/temp/vlc/sbr 输出缓冲）
    if (@import("builtin").mode != .ReleaseFast) {
        std.debug.print("Aac={d} Che={d} Sbr={d} ChannelState={d}\n", .{
            @sizeOf(Aac), @sizeOf(Che), @sizeOf(sbr_mod.Sbr), @sizeOf(ChannelState),
        });
    }
    try testing.expect(@sizeOf(Aac) < 96 * 1024);
}

test "AAC Level-2: 稀疏元素——首用堆分配、未出现元素零分配" {
    const a = testing.allocator;
    var aac: Aac = .{};
    defer testDeinit(&aac, a);
    try aac.initCommon(a, lcCfg(1)); // mono：布局 = SCE id0

    const f0 = try zeroSceFrame(0, 0);
    defer a.free(f0);
    try decodeFrameBytes(&aac, f0);
    try testing.expect(aac.che[0][0] != null);
    for (1..MAX_ELEM_ID) |id| try testing.expect(aac.che[0][id] == null);
    try testing.expect(aac.che[1][0] == null);
    try testing.expect(aac.che[2][0] == null);
    try testing.expect(aac.che[3][0] == null);
    try testing.expect(aac.sbr == null); // LC 无 SBR 扩展 → 不分配

    // 稀疏元素 id5 首次出现（后续帧）：独立分配，其余槽位仍不触碰
    const f5 = try zeroSceFrame(0, 5);
    defer a.free(f5);
    try decodeFrameBytes(&aac, f5);
    try testing.expect(aac.che[0][5] != null);
    for (1..MAX_ELEM_ID) |id| {
        if (id != 5) try testing.expect(aac.che[0][id] == null);
    }
    try testing.expectEqual(@as(u64, 2), aac.stat_frames);
}

test "AAC Level-2: 多元素帧（SCE+CPE+LFE）→ 布局回推 + 全槽位分配" {
    const a = testing.allocator;
    var aac: Aac = .{};
    defer testDeinit(&aac, a);
    try aac.initCommon(a, lcCfg(0)); // chan_config=0：布局由帧内元素回推

    // 单帧串三个元素：SCE id0 + CPE id0 + LFE id0
    var w = TestBw{};
    defer w.deinit();
    try w.put(0, 3);
    try w.put(0, 4);
    try putZeroIcs(&w, false);
    try w.put(1, 3);
    try w.put(0, 4);
    try w.put(1, 1); // common_window
    try w.put(0, 11);
    try w.put(0, 2);
    try putZeroIcs(&w, true);
    try putZeroIcs(&w, true);
    try w.put(3, 3);
    try w.put(0, 4);
    try putZeroIcs(&w, false);
    try w.put(7, 3);
    const frame = try w.toFrame();
    defer a.free(frame);
    try decodeFrameBytes(&aac, frame);

    try testing.expect(aac.che[0][0] != null);
    try testing.expect(aac.che[1][0] != null);
    try testing.expect(aac.che[3][0] != null);
    try testing.expect(aac.che[2][0] == null); // 无 CCE → 不分配
    // 布局回推：SCE(1) + CPE(2) + LFE(1) = 4 声道
    try testing.expectEqual(@as(u8, 4), aac.channels);
    try testing.expectEqual(@as(usize, 3), aac.layout.len);
    // 全零谱 → 输出 1024 样本 × 4 声道全零 s16
    try testing.expectEqual(@as(usize, 1024 * 4 * 2), aac.out_buf.items.len);
    for (aac.out_buf.items) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "AAC Level-2: CCE 首用分配 + 耦合目标应用不越界" {
    const a = testing.allocator;
    var aac: Aac = .{};
    defer testDeinit(&aac, a);
    try aac.initCommon(a, lcCfg(1)); // mono：布局 = SCE id0

    // 单帧两元素：SCE id0（耦合目标）+ CCE id0（指向 SCE id0）
    var w = TestBw{};
    defer w.deinit();
    try w.put(0, 3); // SCE
    try w.put(0, 4);
    try putZeroIcs(&w, false);
    try w.put(2, 3); // CCE
    try w.put(0, 4);
    try w.put(0, 1); // ind_sw_cce_flag → coupling_point = 0
    try w.put(0, 3); // num_coupled = 0 → 1 个增益条目
    try w.put(0, 1); // cc_target: ty = 0（SCE）
    try w.put(0, 4); // cc_target: id_select = 0
    try w.put(0, 1); // cce_scale_flag（cp_extra）→ coupling_point = 0
    try w.put(0, 1); // sign
    try w.put(0, 2); // cce_scale 索引
    try putZeroIcs(&w, false); // CCE 自身单声道 ICS
    try w.put(7, 3); // END
    const frame = try w.toFrame();
    defer a.free(frame);
    try decodeFrameBytes(&aac, frame);

    try testing.expect(aac.che[0][0] != null);
    try testing.expect(aac.che[2][0] != null); // CCE 槽位按需分配
    try testing.expectEqual(@as(u8, 1), aac.channels);
    try testing.expectEqual(@as(usize, 1024 * 1 * 2), aac.out_buf.items.len);
    for (aac.out_buf.items) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "AAC Level-2: 立体声 CPE 双声道输出 + 跨帧复用不重复分配" {
    const a = testing.allocator;
    var aac: Aac = .{};
    defer testDeinit(&aac, a);
    try aac.initCommon(a, lcCfg(2)); // stereo：布局 = CPE id0

    const f = try zeroCpeFrame(0);
    defer a.free(f);
    try decodeFrameBytes(&aac, f);
    const c0 = aac.che[1][0].?;
    try decodeFrameBytes(&aac, f);
    try testing.expect(aac.che[1][0].? == c0); // 第二帧复用同一堆槽位
    try testing.expectEqual(@as(usize, 2 * 1024 * 2 * 2), aac.out_buf.items.len);
    for (aac.out_buf.items) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "AAC Level-2: initCommon 重入释放旧槽位；deinit 全量回收" {
    const a = testing.allocator;
    var aac: Aac = .{};
    defer testDeinit(&aac, a);
    try aac.initCommon(a, lcCfg(1));

    const f = try zeroSceFrame(0, 0);
    defer a.free(f);
    try decodeFrameBytes(&aac, f);
    try testing.expect(aac.che[0][0] != null);

    aac.out_buf.deinit(a); // 会话 1 输出缓冲（重入前由容器自释；initCommon 不拥有 out_buf）
    try aac.initCommon(a, lcCfg(1)); // 配置变更重入：旧槽位释放、状态归零
    try testing.expect(aac.che[0][0] == null);
    try testing.expectEqual(@as(u64, 0), aac.stat_frames);

    try decodeFrameBytes(&aac, f); // 重建后可再次按需分配
    try testing.expect(aac.che[0][0] != null);
}

test "AAC Level-2: 槽位分配 OOM → error.OutOfMemory，状态不劣化" {
    const a = testing.allocator;
    var aac: Aac = .{};
    defer testDeinit(&aac, a);
    try aac.initCommon(a, lcCfg(1));

    const f = try zeroSceFrame(0, 0);
    defer a.free(f);
    var fail = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var aac2: Aac = .{};
    defer testDeinit(&aac2, a);
    try aac2.initCommon(fail.allocator(), lcCfg(1));
    try testing.expectError(error.OutOfMemory, decodeFrameBytes(&aac2, f));
    try testing.expect(aac2.che[0][0] == null); // 分配失败不留半初始化槽位
}

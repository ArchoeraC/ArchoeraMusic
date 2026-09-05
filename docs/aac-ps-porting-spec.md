# AAC 参数立体声（PS）FFmpeg 参考实现移植规格

> 研究对象（FFmpeg libavcodec，仅 float 路径 `USE_FIXED=0`）：
> - `aacps.c`（`aacps_float.c` 展开）
> - `aacps_common.c`
> - `aacpsdata.c`
> - `aacpsdsp_template.c` / `aacpsdsp.h`
> - `aacps_tablegen.h` / `aacps_tablegen.c` / `aacps_tablegen_template.c`
> - 依赖：`aac_defines.h`（浮点宏）、`get_bits.h`、`vlc.h/vlc.c`
>
> 目的：为 Zig 移植提供逐函数语义依据。本文档不写 Zig 代码。

---

## 0. 命名对应关系（重要）

| 其他实现中的名字 | FFmpeg 中的对应 | 说明 |
|---|---|---|
| `f_20_11_8` | `f20_0_8`（由 `g0_Q8` 生成） | 20 带宽模式第 0 个 QMF 子带的 8 抽头复数原型滤波器 |
| `f_34_0_12` / `f_34_1_8` / `f_34_2_4` | 同名 | 34 带宽模式的 12/8/4 抽头原型滤波器 |
| `hann_128_96` / `hann_64_96` | **不存在** | 本 FFmpeg 版本混合分析不使用 Hann 窗；滤波器直接由原型滤波器解析生成（见 §7.4）。若你的目标代码来自其他参考实现（如 VLC aac_ps），需按 §7.4 公式重新生成，或用表中数据 |
| `ha_*`（混合方式 A 表） | `HA[46][8][4]` | 混合方式 A（baseline）查表 |
| `hb_*`（混合方式 B 表） | `HB[46][8][4]` | 混合方式 B 查表 |
| `q_*`（全通滤波器分数延迟表） | `Q_fract_allpass[2][50][3][2]` | 全通分数延迟（每子带每链路） |
| `phi_fract` | `phi_fract[2][50][2]` | 全通整体分数延迟旋转 |
| `ipdopd_par_dequant` | 无独立表 | ipd/opd 为 0..7 的相位索引，直接查 `ipdopd_cos[]/ipdopd_sin[]`（§4.3） |
| `bs_enable_ha` | 无显式位 | HA/HB 的选择由 `PS_BASELINE \|\| icc_mode < 3` 推导（§5.3） |
| `bs_hybrid_mode` | 无显式位 | 混合方式由 `is34bands`（20 带 vs 34 带）决定（§8） |

`PS_BASELINE` 在本版本中恒为 `0`（`aacps.h` 第 41 行），因此所有 `!PS_BASELINE` 条件恒真。移植时可保留该宏以便对齐参考实现，也可以直接剥离。

---

## 1. 常量

```c
// aacps.h
#define PS_MAX_NUM_ENV 5        // 最大包络数（不含伪造包络时为 4，+1 伪造）
#define PS_MAX_NR_IIDICC 34     // iid/icc 参数最多 34 个（34 带模式）
#define PS_MAX_NR_IPDOPD 17     // ipd/opd 参数最多 17 个
#define PS_MAX_SSB 91           // 子子带（subsubband）最大数（34 带模式）
#define PS_MAX_AP_BANDS 50      // 全通带最大数
#define PS_QMF_TIME_SLOTS 32    // QMF 时隙数
#define PS_MAX_DELAY 14         // decorrelation 延迟缓冲长度
#define PS_AP_LINKS 3           // 全通链路数
#define PS_MAX_AP_DELAY 5       // 全通内部延迟
#define numQMFSlots 32          // == PS_QMF_TIME_SLOTS

// aacps.c 中
#define DECAY_SLOPE Q30(0.05f)  // 全通衰减斜率（float 下即 0.05f）
static const int NR_PAR_BANDS[]     = { 20, 34 };  // 参数带数（20带/34带）
static const int NR_IPDOPD_BANDS[]  = { 11, 17 };  // 使用 ipd/opd 的参数带数
static const int NR_BANDS[]         = { 71, 91 };  // 子子带总数
static const int DECAY_CUTOFF[]     = { 10, 32 };  // 全通衰减起始子子带
static const int NR_ALLPASS_BANDS[] = { 30, 50 };  // 全通带数
static const int SHORT_DELAY_BAND[] = { 42, 62 };  // 短延迟（1 时隙）起始带
```

`Q30/Q31` 在 float 路径下是恒等函数（`aac_defines.h` 110-111 行）。

---

## 2. 结构体定义

### 2.1 `PSCommonContext`（aacps.h 47-69 行）

```c
typedef struct PSCommonContext {
    int    start;                    // 本帧是否成功解析（置 1 后 ff_ps_apply 才执行）
    int    enable_iid;               // 本帧是否含 IID 参数
    int    iid_quant;                // 0=粗量化(|val|<=7)，1=细量化(|val|<=15)
    int    nr_iid_par;               // IID 参数带数（10/20/34）
    int    nr_ipdopd_par;            // IPD/OPD 参数带数（5/11/17）
    int    enable_icc;               // 本帧是否含 ICC 参数
    int    icc_mode;                 // 0..5，ICC 模式（决定 nr_icc_par，以及 HA/HB 选择）
    int    nr_icc_par;               // ICC 参数带数（10/20/34）
    int    enable_ext;               // 是否含扩展（ipd/opd）数据
    int    frame_class;              // 0=固定包络边界，1=可变边界
    int    num_env_old;              // 上一帧包络数（读帧前保存）
    int    num_env;                  // 本帧包络数（解析后可能被“伪造包络”逻辑 +1）
    int    enable_ipdopd;            // 本帧是否启用 IPD/OPD
    int    border_position[PS_MAX_NUM_ENV+1];  // 包络边界时隙号，[0]恒为 -1
    int8_t iid_par[PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]; // IID 量化索引（帧间/带间差分解码后的绝对值）
    int8_t icc_par[PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]; // ICC 量化索引（0..7）
    /* ipd/opd 用 iid/icc 相同的数组宽度，便于共用 remap 函数 */
    int8_t ipd_par[PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]; // IPD 量化索引（0..7）
    int8_t opd_par[PS_MAX_NUM_ENV][PS_MAX_NR_IIDICC]; // OPD 量化索引（0..7）
    int    is34bands;                // 本帧是否 34 带模式
    int    is34bands_old;            // 上一帧是否 34 带模式
} PSCommonContext;
```

`PS_MAX_NUM_ENV=5`：位流最多 4 个包络，第 5 个槽被“伪造包络”逻辑使用（`num_env++`）。

### 2.2 `PSContext`（aacps.h 71-89 行）

```c
typedef struct PSContext {
    PSCommonContext common;

    DECLARE_ALIGNED(16, INTFLOAT, in_buf)[5][44][2];   // 混合分析输入环形缓冲
        // 5 个 QMF 子带 × 44 时隙（6 历史 + 32 当前 + 6 未来）× [re,im]
    DECLARE_ALIGNED(16, INTFLOAT, delay)[PS_MAX_SSB][PS_QMF_TIME_SLOTS + PS_MAX_DELAY][2];
        // 去相关延迟线，[91][46][2]，每帧移位 32
    DECLARE_ALIGNED(16, INTFLOAT, ap_delay)[PS_MAX_AP_BANDS][PS_AP_LINKS][PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY][2];
        // 全通链路延迟，[50][3][37][2]
    DECLARE_ALIGNED(16, INTFLOAT, peak_decay_nrg)[34];          // 峰值衰减能量（每参数带）
    DECLARE_ALIGNED(16, INTFLOAT, power_smooth)[34];            // 平滑功率
    DECLARE_ALIGNED(16, INTFLOAT, peak_decay_diff_smooth)[34];  // 峰值与功率差平滑
    DECLARE_ALIGNED(16, INTFLOAT, H11)[2][PS_MAX_NUM_ENV+1][PS_MAX_NR_IIDICC]; // [实/虚][包络+1][参数带]
    DECLARE_ALIGNED(16, INTFLOAT, H12)[2][PS_MAX_NUM_ENV+1][PS_MAX_NR_IIDICC];
    DECLARE_ALIGNED(16, INTFLOAT, H21)[2][PS_MAX_NUM_ENV+1][PS_MAX_NR_IIDICC];
    DECLARE_ALIGNED(16, INTFLOAT, H22)[2][PS_MAX_NUM_ENV+1][PS_MAX_NR_IIDICC];
        // H 矩阵实部存 [0][...]，虚部存 [1][...]；[0] 槽存上一帧末状态（供包络间线性插值）
    DECLARE_ALIGNED(16, INTFLOAT, Lbuf)[91][32][2];             // 混合分析输出 L（子子带×时隙）
    DECLARE_ALIGNED(16, INTFLOAT, Rbuf)[91][32][2];             // 去相关输出 R
    int8_t opd_hist[PS_MAX_NR_IIDICC];  // opd 相位平滑历史（每参数带，base-8 编码最近两个相位）
    int8_t ipd_hist[PS_MAX_NR_IIDICC];  // ipd 相位平滑历史
    PSDSPContext dsp;                   // DSP 函数表
} PSContext;
```

`INTFLOAT`（float 路径）= `float`。

### 2.3 `PSDSPContext`（aacpsdsp.h 32-52 行）

```c
typedef struct PSDSPContext {
    void (*add_squares)(INTFLOAT *restrict dst, const INTFLOAT (*src)[2], int n);
    void (*mul_pair_single)(INTFLOAT (*restrict dst)[2], INTFLOAT (*src0)[2], INTFLOAT *src1, int n);
    void (*hybrid_analysis)(INTFLOAT (*restrict out)[2], INTFLOAT (*in)[2],
                            const INTFLOAT (*filter)[8][2], ptrdiff_t stride, int n);
    void (*hybrid_analysis_ileave)(INTFLOAT (*restrict out)[32][2], INTFLOAT L[2][38][64], int i, int len);
    void (*hybrid_synthesis_deint)(INTFLOAT out[2][38][64], INTFLOAT (*restrict in)[32][2], int i, int len);
    void (*decorrelate)(INTFLOAT (*out)[2], INTFLOAT (*delay)[2],
                        INTFLOAT (*ap_delay)[PS_QMF_TIME_SLOTS+PS_MAX_AP_DELAY][2],
                        const INTFLOAT phi_fract[2], const INTFLOAT (*Q_fract)[2],
                        const INTFLOAT *transient_gain, INTFLOAT g_decay_slope, int len);
    void (*stereo_interpolate[2])(INTFLOAT (*l)[2], INTFLOAT (*r)[2],
                                  INTFLOAT h[2][4], INTFLOAT h_step[2][4], int len);
    // [0] = 无 ipd/opd 版本，[1] = ipd/opd 版本
} PSDSPContext;
```

初始化：`ff_psdsp_init(&ps->dsp)`（float 版全部指向上述 `_c` 函数，SIMD 覆盖可忽略）。

---

## 3. 位流解析：`ff_ps_read_data`

调用上下文（`aacsbr_template.c:976`）：

```c
*num_bits_left -= ff_ps_read_data(ac->avctx, gb, &sbr->ps.common, *num_bits_left);
```

`bits_left` = SBR 扩展中剩余比特数。函数在**拷贝**的 `GetBitContext` 上解析；成功则把消费的位数推进宿主 gb 并返回消费位数，失败则跳过 `bits_left` 位、清零所有参数、返回 `bits_left`，且 `ps->start = 0`（本帧不执行 PS 合成）。

### 3.1 `READ_PAR_DATA` 宏（aacps_common.c 63-105 行）

三种参数（iid / icc / ipdopd）共用同一宏展开。语义：

```c
#define READ_PAR_DATA(PAR, MASK, ERR_CONDITION, NB_BITS, MAX_DEPTH) \
static int read_##PAR##_data(void *logctx, GetBitContext *gb, PSCommonContext *ps, \
                    int8_t (*PAR)[PS_MAX_NR_IIDICC], int table_idx, int e, int dt) \
{ \
    int b, num = ps->nr_##PAR##_par; \
    const VLCElem *vlc_table = vlc_ps[table_idx]; \
    if (dt) {                                   /* 时间差编码 */ \
        int e_prev = e ? e - 1 : ps->num_env_old - 1; \
        e_prev = FFMAX(e_prev, 0); \
        for (b = 0; b < num; b++) { \
            int val = PAR[e_prev][b] + get_vlc2(gb, vlc_table, NB_BITS, MAX_DEPTH); \
            if (MASK) val &= MASK; \
            PAR[e][b] = val; \
            if (ERR_CONDITION) goto err; \
        } \
    } else {                                    /* 频率差编码 */ \
        int val = 0; \
        for (b = 0; b < num; b++) { \
            val += get_vlc2(gb, vlc_table, NB_BITS, MAX_DEPTH); \
            if (MASK) val &= MASK; \
            PAR[e][b] = val; \
            if (ERR_CONDITION) goto err; \
        } \
    } \
    return 0; \
err: return AVERROR_INVALIDDATA; \
}
```

展开后的三个实例：

```c
READ_PAR_DATA(iid,   0, FFABS(ps->iid_par[e][b]) > 7 + 8 * ps->iid_quant, 9, 3)
//   无 mask；错误条件：|val| > 7（粗）或 15（细）；get_vlc2(9 位表, max_depth 3)

READ_PAR_DATA(icc,   0, ps->icc_par[e][b] > 7U, 9, 2)
//   无 mask；错误条件：val > 7U（无符号比较 → 负值也判非法），故 icc ∈ [0,7]
//   get_vlc2(9 位表, max_depth 2)

READ_PAR_DATA(ipdopd, 0x07, 0, 5, 1)
//   mask = 0x07（val &= 7，即 mod 8）；无错误条件；get_vlc2(5 位表, max_depth 1)
```

**dt 语义**：`dt=1` 时本包络参数 = 前一个包络（`e-1`；若 `e=0` 则取上一帧的 `num_env_old-1`，下限 0）加差；`dt=0` 时沿参数带方向累加（`val` 从 0 起逐带累加）。

`vlc_ps[table_idx]` 索引枚举（aacps_common.c 41-52 行）：

```c
enum { huff_iid_df1, huff_iid_dt1, huff_iid_df0, huff_iid_dt0,
       huff_icc_df, huff_icc_dt, huff_ipd_df, huff_ipd_dt, huff_opd_df, huff_opd_dt };
static const int huff_iid[] = { huff_iid_df0, huff_iid_df1, huff_iid_dt0, huff_iid_dt1 };
// 选择表：huff_iid[2*dt + iid_quant]：dt=0粗→df0(idx2)，dt=0细→df1(idx0)，
//        dt=1粗→dt0(idx3)，dt=1细→dt1(idx1)
```

### 3.2 `ps_read_extension_data`（aacps_common.c 111-131 行）

```c
static int ps_read_extension_data(GetBitContext *gb, PSCommonContext *ps, int ps_extension_id)
{
    int e;
    int count = get_bits_count(gb);

    if (ps_extension_id)      // 仅接受 id==0；其余直接返回，不消费任何位（返回 0）
        return 0;

    ps->enable_ipdopd = get_bits1(gb);          // enable_ipdopd 位
    if (ps->enable_ipdopd) {
        for (e = 0; e < ps->num_env; e++) {
            int dt = get_bits1(gb);                             // 每个包络一个 dt 标志
            read_ipdopd_data(NULL, gb, ps, ps->ipd_par, dt ? huff_ipd_dt : huff_ipd_df, e, dt);
            dt = get_bits1(gb);
            read_ipdopd_data(NULL, gb, ps, ps->opd_par, dt ? huff_opd_dt : huff_opd_df, e, dt);
        }
    }
    skip_bits1(gb);          // reserved_ps（保留位）
    return get_bits_count(gb) - count;   // 返回本函数消费的位数
}
```

注意：ipd/opd 的 dt 是**每个包络分别**读取的（`enable_iid/enable_icc` 也类似）。

### 3.3 `ff_ps_read_data` 主流程（aacps_common.c 133-289 行）

按位流顺序：

```
1. header = get_bits1(gb);                        // enable_ps_header
2. if (header) {
     enable_iid     = get_bits1(gb);
     if (enable_iid) {
        iid_mode     = get_bits(gb, 3);            // 0..7，>5 → 错误
        nr_iid_par   = nr_iidicc_par_tab[iid_mode];   // {10,20,34,10,20,34}
        iid_quant    = iid_mode > 2;               // 模式 0-2 粗，3-5 细
        nr_ipdopd_par= nr_iidopd_par_tab[iid_mode];   // {5,11,17,5,11,17}
     }
     enable_icc     = get_bits1(gb);
     if (enable_icc) {
        icc_mode     = get_bits(gb, 3);            // 0..7，>5 → 错误
        nr_icc_par   = nr_iidicc_par_tab[icc_mode];
     }
     enable_ext     = get_bits1(gb);
   }
3. frame_class  = get_bits1(gb);
   num_env_old  = num_env;
   num_env      = num_env_tab[frame_class][get_bits(gb, 2)];
     // num_env_tab[0]={0,1,2,4}，num_env_tab[1]={1,2,3,4}
4. border_position[0] = -1;
   if (frame_class) {                              // FIXED=false，逐包络读边界
        for (e=1..num_env) border_position[e] = get_bits(gb, 5);  // 5 位
        检查单调不减，否则错误；
   } else {                                        // FIXED=true，均匀划分
        for (e=1..num_env) border_position[e] = (e * 32 >> ff_log2_tab[num_env]) - 1;
        // num_env=1 → [31]; 2 → [15,31]; 4 → [7,15,23,31]
   }
5. if (enable_iid) 每个包络：dt=get_bits1；read_iid_data(表=huff_iid[2*dt+iid_quant])
   else memset(iid_par, 0)
6. if (enable_icc) 每个包络：dt=get_bits1；read_icc_data(表=dt?huff_icc_dt:huff_icc_df)
   else memset(icc_par, 0)
7. if (enable_ext) {
       cnt  = get_bits(gb, 4); if (cnt==15) cnt += get_bits(gb, 8);
       cnt *= 8;                                   // 字节数 → 位数
       while (cnt > 7) {
           ps_extension_id = get_bits(gb, 2);
           cnt -= 2 + ps_read_extension_data(gb, ps, ps_extension_id); // 循环直到 cnt<=7
       }
       if (cnt < 0) goto err;                      // 扩展溢出
       skip_bits(gb, cnt);                         // 跳过剩余填充位
   }
8. enable_ipdopd &= !PS_BASELINE;                  // baseline 强制关闭（此处恒真）
9. // 伪造包络（Fix up envelopes）
   if (!num_env || border_position[num_env] < 31) {
       source = num_env ? num_env-1 : num_env_old-1;
       if (source >= 0 && source != num_env)
           分别 memcpy iid_par/icc_par/ipd_par/opd_par 的 [num_env] ← [source]
       if (enable_iid) 校验第 num_env 个包络 |val| <= 7+8*iid_quant
       if (enable_icc) 校验第 num_env 个包络 0<=val<=7
       num_env++;
       border_position[num_env] = 31;              // 补到帧尾
   }
10. is34bands_old = is34bands;
    if (!PS_BASELINE && (enable_iid || enable_icc))
        is34bands = (enable_iid && nr_iid_par==34) || (enable_icc && nr_icc_par==34);
11. if (!enable_ipdopd) memset(ipd_par,0) 与 memset(opd_par,0)
12. if (header) start = 1;
13. bits_consumed = get_bits_count(gb) - bit_count_start;
    if (bits_consumed <= bits_left) { skip_bits_long(gb_host, bits_consumed); return bits_consumed; }
    // 否则落入 err：
err: start=0; skip_bits_long(gb_host, bits_left);
     memset 全部 iid/icc/ipd/opd;  return bits_left;
```

补充表：

```c
static const int8_t num_env_tab[2][4] = { { 0, 1, 2, 4 }, { 1, 2, 3, 4 } };
static const int8_t nr_iidicc_par_tab[] = { 10, 20, 34, 10, 20, 34 };
static const int8_t nr_iidopd_par_tab[]  = {  5, 11, 17,  5, 11, 17 };
```

`ff_log2_tab[i]` = `log2(i)`（i 为 2 的幂），即 `num_env` 为 1/2/4 时右移 0/1/2 位。

### 3.4 VLC 表构建（`ff_ps_init_common`，aacps_common.c 291-306 行）

```c
av_cold void ff_ps_init_common(void) {
    // 预分配 VLCElem 池（大小按最大构建结果估算，可移植时直接按需分配）
    static VLCElem vlc_buf[...]; VLCInitState state = ...;
    const uint8_t (*tab)[2] = aacps_huff_tabs;    // {sym, len} 对
    for (int i = 0; i < 10; i++) {
        vlc_ps[i] = ff_vlc_init_tables_from_lengths(&state,
                       i <= 5 ? 9 : 5,            // nb_bits：iid/icc 用 9，ipd/opd 用 5
                       huff_sizes[i],             // 码表条目数 {61,61,29,29,15,15,8,8,8,8}
                       &tab[0][1], 2,             // 长度字段，stride 2 字节
                       &tab[0][0], 2, 1,          // 符号字段，stride 2 字节，1 字节宽
                       huff_offset[i], 0);        // 符号偏移 {-30,-30,-14,-14,-7,-7,0,0,0,0}
        tab += huff_sizes[i];
    }
}
```

`ff_vlc_init_from_lengths`（vlc.c 306-351 行）算法（移植时可直接复刻，约 40 行）：

```
code = 0
按给定顺序遍历每条码（{symbol, len}）：
    buf[j].symbol = symbol + offset
    buf[j].code   = code
    buf[j].bits   = len
    code += 1U << (32 - len)          // 规范哈夫曼（canonical）码分配
    校验：len 与 code 低位对齐，否则非法
```

即：码值按表内顺序累加分配（表必须满足规范码约束，aacpsdata.c 的数据直接满足）。随后 `build_table`（vlc.c 138-227 行）把码放入二级查找表：

```
对每条码（按 code 排序）：
  若 len <= nb_bits：把 2^(nb_bits-len) 个表项填 {symbol, len}（同一前缀的所有填充项必须一致）
  否则：主表该前缀填 {sym=子表索引, len=-(剩余位数)}，递归构建子表（子表位宽 = 剩余位，上限 nb_bits）
未填充项填 {sym=-1, len=0}
```

### 3.5 `get_vlc2` 解码算法（get_bits.h 645-658 + 573-600）

```
读取 gb 当前位流头部 bits 位作为主表索引 idx（MSB 优先）
code = table[idx].sym; n = table[idx].len
if (max_depth>1 且 n < 0)：               // 负 len = 子表
    skip bits 位；再读 -n 位；
    idx = (新读的位) + code（code 作为子表基址）
    code = table[idx].sym; n = table[idx].len
    if (max_depth>2 且 n < 0)：再下钻一级
skip n 位（真实码长）
返回 code
```

- iid：`get_vlc2(gb, 表, 9, 3)`（最长码 20 位 → 9+9+2 三级）
- icc：`get_vlc2(gb, 表, 9, 2)`（最长 14 位 → 二级）
- ipd/opd：`get_vlc2(gb, 表, 5, 1)`（最长 5 位 → 单级）

### 3.6 Huffman 数据表（aacpsdata.c）

```c
static const uint8_t huff_sizes[] = { 61, 61, 29, 29, 15, 15, 8, 8, 8, 8 };
static const int8_t huff_offset[] = { -30, -30, -14, -14, -7, -7, 0, 0, 0, 0 };
// aacps_huff_tabs[][2]：每条 {symbol, code_length}，顺序对应 10 张表：
//   iid_df1(61), iid_dt1(61), iid_df0(29), iid_dt0(29),
//   icc_df(15), icc_dt(15), ipd_df(8), ipd_dt(8), opd_df(8), opd_dt(8)
```

符号+偏移后的取值范围：iid 粗 ∈ [-14,14]（校验限 [-7,7]）、细 ∈ [-30,30]（校验限 [-15,15]）；icc ∈ [-7,7]（校验限 [0,7]）；ipd/opd ∈ [0,7]。

---

## 4. 参数去量化

### 4.1 IID 去量化

量化索引 → 线性强度比 c 直接由 HA/HB 表行号编码，无独立一步查表。`c = iid_par_dequant[iid_idx]`：

```c
static const float iid_par_dequant[] = {
    // iid_par_dequant_default（粗量化，索引 0..14 = 编码值+7）
    0.05623413251903, 0.12589254117942, 0.19952623149689, 0.31622776601684,
    0.44668359215096, 0.63095734448019, 0.79432823472428, 1,
    1.25892541179417, 1.58489319246111, 2.23872113856834, 3.16227766016838,
    5.01187233627272, 7.94328234724282, 17.7827941003892,
    // iid_par_dequant_fine（细量化，索引 15..45 = 编码值+30）
    0.00316227766017, 0.00562341325190, 0.01,             0.01778279410039,
    0.03162277660168, 0.05623413251903, 0.07943282347243, 0.11220184543020,
    0.15848931924611, 0.22387211385683, 0.31622776601684, 0.39810717055350,
    0.50118723362727, 0.63095734448019, 0.79432823472428, 1,
    1.25892541179417, 1.58489319246111, 1.99526231496888, 2.51188643150958,
    3.16227766016838, 4.46683592150963, 6.30957344480193, 8.91250938133745,
    12.5892541179417, 17.7827941003892, 31.6227766016838, 56.2341325190349,
    100,              177.827941003892, 316.227766016837,
};
```

（每 1dB 步进的强度比，`c = 10^(iid_db/20)`。）

### 4.2 ICC 去量化

无独立表，直接融入 HA/HB 生成：

```c
static const float icc_invq[]     = { 1, 0.937, 0.84118, 0.60092, 0.36764, 0, -0.589, -1 };
static const float acos_icc_invq[]= { 0, 0.35685527, 0.57133466, 0.92614472, 1.1943263,
                                      M_PI/2, 2.2006171, M_PI };
```

即 ICC 量化值 0..7 去量化成相关系数，再映射为角度 `acos_icc_invq[icc]`（0..π）供 HA/HB 生成。

### 4.3 IPD / OPD 去量化

量化索引 0..7 直接对应相位角，复数形式查表：

```c
static const float ipdopd_sin[] = { 0, M_SQRT1_2, 1,  M_SQRT1_2,  0, -M_SQRT1_2, -1, -M_SQRT1_2 };
static const float ipdopd_cos[] = { 1, M_SQRT1_2, 0, -M_SQRT1_2, -1, -M_SQRT1_2,  0,  M_SQRT1_2 };
// 对应相位 {0, π/4, π/2, 3π/4, π, 5π/4, 3π/2, 7π/4}
```

这些 cos/sin 用于 `pd_re_smooth`/`pd_im_smooth` 生成（§7.3）。**没有**像其他实现那样的 `ipdopd_par_dequant` 幅度表。

### 4.4 参数带重映射（remap34 / remap20）

位流参数带数（10/20/34）可能与混合模式实际带数（20/34）不同，需映射。`full=1` 表示含全部带（iid/icc），`full=0` 只含前部（ipd/opd，只用 11/17 带）。

```c
// 总入口
remap34(&ptr, par, num_par, num_env, full):
    num_par==20||11 → 每包络 map_idx_20_to_34
    num_par==10||5  → 每包络 map_idx_10_to_34
    否则（已 34 带）→ ptr = par（直接引用）
remap20(&ptr, par, num_par, num_env, full):
    num_par==34||17 → map_idx_34_to_20
    num_par==10||5  → map_idx_10_to_20
    否则（已 20 带）→ ptr = par
```

四个映射函数的查表式赋值（见 aacps.c 201-360 行，均为整型索引重排；`map_val_*` 是 H 系数值版本的插值合并，供带宽切换时使用）：

- `map_idx_10_to_20`：`full` 时 `b=9` 从高往低 `par_mapped[2b+1]=par_mapped[2b]=par[b]`；非 full 时 `b=4` 且 `par_mapped[10]=0`（0..10 保留）。
- `map_idx_34_to_20`：按表 8.46 加权合并，例如 `[0]=(2p0+p1)/3`、`[1]=(p1+2p2)/3`、`[4]=(p6+p7)/2`、`[8]=(p12+p13)/2`、`[18]=(p28+p29+p30+p31)/4`、`[19]=(p32+p33)/2` 等（`full=0` 时只算 0..10）。
- `map_idx_10_to_34`：展开（`par_mapped[0]=par_mapped[1]=par_mapped[2]=par[0]`、`[3..6]=par[1]`、`[7..10]=par[2]`…；`full=1` 时把 `par[4..9]` 铺到 `[12..33]`）。
- `map_idx_20_to_34`：`par_mapped[0]=par[0]`、`[1]=(par[0]+par[1])/2`、`[4]=(par[2]+par[3])/2`、`[10..15]` 等一对多复制，`full=1` 时补 `[17..33]`。

带宽切换时对 H 系数做值映射：

```c
map_val_20_to_34(par):   par[33]=par[19], par[32]=par[19], par[31]=par[18]×4, ...
                        par[1]=AAC_HALF_SUM(par[0],par[1]), par[4]=AAC_HALF_SUM(par[2],par[3])
map_val_34_to_20(par):   par[0]=(2p0+p1)*0.33333333f, par[1]=(p1+2p2)*0.33333333f,
                        par[2]=(2p3+p4)*0.33333333f, par[3]=(p4+2p5)*0.33333333f,
                        par[4..17]=AAC_HALF_SUM(...), par[18]=(p28+p29+p30+p31)*0.25f,
                        par[19]=AAC_HALF_SUM(p32,p33)
// AAC_HALF_SUM(x,y) = (x+y)*0.5f（float 路径）
```

---

## 5. `ff_ps_apply` 整体流程（aacps.c 719-738 行）

```c
int ff_ps_apply(PSContext *ps, INTFLOAT L[2][38][64], INTFLOAT R[2][38][64], int top)
{
    INTFLOAT (*Lbuf)[32][2] = ps->Lbuf;
    INTFLOAT (*Rbuf)[32][2] = ps->Rbuf;
    const int len = 32;               // 处理 32 个时隙
    int is34 = ps->common.is34bands;

    top += NR_BANDS[is34] - 64;       // top 是 SBR 使用的最高 QMF 子带+1；重映射到子子带坐标
    memset(ps->delay+top, 0, (NR_BANDS[is34] - top)*sizeof(ps->delay[0]));
    if (top < NR_ALLPASS_BANDS[is34])
        memset(ps->ap_delay + top, 0, (NR_ALLPASS_BANDS[is34] - top)*sizeof(ps->ap_delay[0]));
        // 高于 SBR 顶带的子子带没有能量，清零延迟线

    hybrid_analysis(&ps->dsp, Lbuf, ps->in_buf, L, is34, len);   // L → Lbuf（混合分析）
    decorrelation(ps, Rbuf, Lbuf, is34);                          // Lbuf → Rbuf（去相关）
    stereo_processing(ps, Lbuf, Rbuf, is34);                      // 立体声处理（H 矩阵插值混合）
    hybrid_synthesis(&ps->dsp, L, Lbuf, is34, len);               // Lbuf → L（综合回 QMF 域）
    hybrid_synthesis(&ps->dsp, R, Rbuf, is34, len);               // Rbuf → R
    return 0;
}
```

输入输出 `L[2][38][64]`：38 = 6 重叠 + 32 当前；64 = QMF 子带。`L[0]`=实部时隙×子带，`L[1]`=虚部。SBR 解码把 mono 谱放到 `L`，PS 输出左右两路到 `L`/`R`（`aacsbr_template.c:1761-1767`：仅当 `ps.common.start` 时调用，否则 `R` 直接拷贝 `L`）。

### 5.1 `hybrid_analysis`（aacps.c 115-143 行）

```c
static void hybrid_analysis(PSDSPContext *dsp, INTFLOAT out[91][32][2],
                            INTFLOAT in[5][44][2], INTFLOAT L[2][38][64],
                            int is34, int len)
{
    // 1) 把前 5 个 QMF 子带填入 in_buf 的时隙 6..43
    for (i = 0; i < 5; i++)
        for (j = 0; j < 38; j++) { in[i][j+6][0] = L[0][j][i]; in[i][j+6][1] = L[1][j][i]; }

    if (is34) {                                  // 34 带：子带 0..4 拆成 32 个子子带
        hybrid4_8_12_cx(dsp, in[0], out,    f34_0_12, 12, len);  // out[0..11]
        hybrid4_8_12_cx(dsp, in[1], out+12, f34_1_8,   8, len);  // out[12..19]
        hybrid4_8_12_cx(dsp, in[2], out+20, f34_2_4,   4, len);  // out[20..23]
        hybrid4_8_12_cx(dsp, in[3], out+24, f34_2_4,   4, len);  // out[24..27]
        hybrid4_8_12_cx(dsp, in[4], out+28, f34_2_4,   4, len);  // out[28..31]
        dsp->hybrid_analysis_ileave(out + 27, L, 5, len);        // QMF 带5..63 → out[32..90]
    } else {                                     // 20 带：子带 0..2 拆成 10 个子子带
        hybrid6_cx(dsp, in[0], out, f20_0_8, len);               // out[0..5]
        hybrid2_re(in[1], out+6, g1_Q2, len, 1);                 // out[6..7]
        hybrid2_re(in[2], out+8, g1_Q2, len, 0);                 // out[8..9]
        dsp->hybrid_analysis_ileave(out + 7, L, 3, len);         // QMF 带3..63 → out[10..70]
    }
    // 2) 滑动 in_buf：把时隙 32..37 移到 0..5（供下帧滤波窗口）
    for (i = 0; i < 5; i++) memcpy(in[i], in[i]+32, 6 * sizeof(in[i][0]));
}
```

辅助函数：

```c
// 一个子带拆 6 个子子带（复滤波器，8 输出合并成 6）
static void hybrid6_cx(PSDSPContext *dsp, INTFLOAT (*in)[2], INTFLOAT (*out)[32][2],
                       const INTFLOAT (*filter)[8][2], int len)
{
    INTFLOAT temp[8][2];
    for (i = 0; i < len; i++, in++) {
        dsp->hybrid_analysis(temp, in, filter, 1, 8);      // 8 个临时输出
        out[0][i] = temp[6];  out[1][i] = temp[7];
        out[2][i] = temp[0];  out[3][i] = temp[1];
        out[4][i] = temp[2] + temp[5];                     // 相邻输出两两相加
        out[5][i] = temp[3] + temp[4];
    }
}

// 一个子带拆 4/8/12 个子子带（stride=32 使写索引落在 out[k][n]）
static void hybrid4_8_12_cx(PSDSPContext *dsp, INTFLOAT (*in)[2], INTFLOAT (*out)[32][2],
                            const INTFLOAT (*filter)[8][2], int N, int len)
{
    for (i = 0; i < len; i++, in++)
        dsp->hybrid_analysis(out[0] + i, in, filter, 32, N);
}
// 说明：hybrid_analysis 内部写 out[i*stride]；base=out[0]+i、stride=32 →
//   (out[0]+i)[j*32] = out[0][i+32*j] = out[j][i]（平面索引别名），即 out[子子带][时隙]

// 一个子带拆 2 个子子带（实滤波器，奇抽头，对称对相加）
static void hybrid2_re(INTFLOAT (*in)[2], INTFLOAT (*out)[32][2],
                       const INTFLOAT filter[7], int len, int reverse)
{
    for (i = 0; i < len; i++, in++) {
        re_in = filter[6] * in[6][0];   im_in = filter[6] * in[6][1];   // 中心抽头
        re_op = 0; im_op = 0;
        for (j = 0; j < 6; j += 2) {                                    // 抽头 1,3,5
            re_op += filter[j+1] * (in[j+1][0] + in[12-j-1][0]);
            im_op += filter[j+1] * (in[j+1][1] + in[12-j-1][1]);
        }
        out[ reverse][i] = re_in + re_op;   out[!reverse][i] = re_in - re_op;  // 同相/反相
    }
}
```

### 5.2 `decorrelation`（aacps.c 399-517 行）

```c
static void decorrelation(PSContext *ps, INTFLOAT (*out)[32][2],
                          const INTFLOAT (*s)[32][2], int is34)
{
    LOCAL_ALIGNED_16(INTFLOAT, power, [34][32]);            // 每参数带每时隙能量
    LOCAL_ALIGNED_16(INTFLOAT, transient_gain, [34][32]);   // 瞬态增益
    const int8_t *k_to_i = is34 ? ff_k_to_i_34 : ff_k_to_i_20;
    int n0 = 0, nL = 32;
    const float peak_decay_factor = 0.76592833836465f;

    memset(power, 0, sizeof);                              // 只清零 [i] 的 32 槽？

    // 带宽模式切换时重置全部状态
    if (is34 != ps->common.is34bands_old)
        memset(peak_decay_nrg/power_smooth/peak_decay_diff_smooth/delay/ap_delay, 0);

    // 1) 功率累加：每个子子带 k 的能量归并到参数带 i=k_to_i[k]
    for (k = 0; k < NR_BANDS[is34]; k++) {
        int i = k_to_i[k];
        ps->dsp.add_squares(power[i], s[k], nL - n0);      // power[i][n] += |s[k][n]|²
    }

    // 2) 瞬态检测（每参数带 i，每时隙 n）：
    for (i = 0; i < NR_PAR_BANDS[is34]; i++) {
        for (n = n0; n < nL; n++) {
            decayed_peak = 0.76592833836465 * peak_decay_nrg[i];
            peak_decay_nrg[i] = FFMAX(decayed_peak, power[i][n]);
            power_smooth[i] += 0.25f * (power[i][n] - power_smooth[i]);
            peak_decay_diff_smooth[i] += 0.25f * (peak_decay_nrg[i] - power[i][n] - peak_decay_diff_smooth[i]);
            denom = 1.5f * peak_decay_diff_smooth[i];
            transient_gain[i][n] = (denom > power_smooth[i]) ? power_smooth[i] / denom : 1.0f;
        }
    }

    // 3) 去相关（三种区域）
    //    全通区 NR_ALLPASS_BANDS 个带：
    for (k = 0; k < NR_ALLPASS_BANDS[is34]; k++) {
        int b = k_to_i[k];
        g_decay_slope = av_clipf(1.f - 0.05f * (k - DECAY_CUTOFF[is34]), 0.f, 1.f);
        // 延迟线移位：
        memcpy(delay[k], delay[k]+32, 14*sizeof);           // delay[k][0..13] = delay[k][32..45]
        memcpy(delay[k]+14, s[k], 32*sizeof);               // delay[k][14..45] = s[k][0..31]
        for (m = 0; m < 3; m++)
            memcpy(ap_delay[k][m], ap_delay[k][m]+32, 5*sizeof); // ap_delay[m][0..4] = [m][32..36]
        ps->dsp.decorrelate(out[k], delay[k]+14-2, ap_delay[k],
                            phi_fract[is34][k], Q_fract_allpass[is34][k],
                            transient_gain[b], g_decay_slope, nL - n0);
    }
    //    短延迟区 SHORT_DELAY_BAND 前的带：净延迟 14 时隙
    for (; k < SHORT_DELAY_BAND[is34]; k++) {
        int i = k_to_i[k];
        memcpy(delay[k], delay[k]+32, 14*sizeof);
        memcpy(delay[k]+14, s[k], 32*sizeof);
        ps->dsp.mul_pair_single(out[k], delay[k]+14-14, transient_gain[i], nL - n0);
    }
    //    最高频带：净延迟 1 时隙
    for (; k < NR_BANDS[is34]; k++) {
        int i = k_to_i[k];
        memcpy(delay[k], delay[k]+32, 14*sizeof);
        memcpy(delay[k]+14, s[k], 32*sizeof);
        ps->dsp.mul_pair_single(out[k], delay[k]+14-1, transient_gain[i], nL - n0);
    }
}
```

延迟线语义：移位后 `delay[k][14..45] = 本帧 s[k][0..31]`，`delay[k][0..13] = 上帧尾`。
- 全通区读 `delay[k][12..43]`（相对本帧起点偏 2 时隙 = 公式中的 `z^-2`）。
- “延迟 14”区读 `delay[k][0..31]`：序列覆盖绝对时间 [-14, 13]，即输出 slot n = 输入 time n-14。
- “延迟 1”区读 `delay[k][13..44]`：输出 slot n = 输入 time n-1。

参考公式（注释）：

```
                  PS_AP_LINKS - 1
                        -----
                         | |  Q_fract_allpass[k][m]*z^-link_delay[m] - a[m]*g_decay_slope[k]
H[k][z] = z^-2 * phi_fract[k] * | | -------------------------------------------------------------
                         | | 1 - a[m]*g_decay_slope[k]*Q_fract_allpass[k][m]*z^-link_delay[m]
                        m = 0
d[k][z] (out) = transient_gain_mapped[k][z] * H[k][z] * s[k][z]
```

### 5.3 `stereo_processing`（aacps.c 557-717 行）

```c
static void stereo_processing(PSContext *ps, INTFLOAT (*l)[32][2], INTFLOAT (*r)[32][2], int is34)
{
    PSCommonContext *ps2 = &ps->common;
    INTFLOAT (*H11)[PS_MAX_NUM_ENV+1][PS_MAX_NR_IIDICC] = ps->H11;  // [实虚][包络][参数带]
    int8_t *opd_hist = ps->opd_hist, *ipd_hist = ps->ipd_hist;
    int8_t iid_mapped_buf[5][34], icc_mapped_buf[5][34], ipd_mapped_buf[5][34], opd_mapped_buf[5][34];
    int8_t (*iid_mapped)[34] = iid_mapped_buf;   // 重映射后的参数（可能指向 ps->iid_par 本身）
    int8_t (*icc_mapped)[34] = icc_mapped_buf;
    int8_t (*ipd_mapped)[34] = ipd_mapped_buf;
    int8_t (*opd_mapped)[34] = opd_mapped_buf;
    const int8_t *k_to_i = is34 ? ff_k_to_i_34 : ff_k_to_i_20;
    // H 查表：混合方式 A (HA) 或 B (HB)
    TABLE_CONST INTFLOAT (*H_LUT)[8][4] = (PS_BASELINE || ps2->icc_mode < 3) ? HA : HB;

    // 0) 上一帧末包络的 H 系数拷贝到 [e=0] 槽（包络间插值起点）
    if (ps2->num_env_old) {
        memcpy(H11[0][0], H11[0][ps2->num_env_old], sizeof(H11[0][0]));
        ... // H11/H12/H21/H22 的 [0] 和 [1] 层各拷一份
    }

    // 1) 参数带重映射到当前混合带数；带宽切换时对历史 H 系数做值映射并复位 ipd/opd 历史
    if (is34) {
        remap34(&iid_mapped, ps2->iid_par, ps2->nr_iid_par, ps2->num_env, 1);
        remap34(&icc_mapped, ps2->icc_par, ps2->nr_icc_par, ps2->num_env, 1);
        if (ps2->enable_ipdopd) {
            remap34(&ipd_mapped, ps2->ipd_par, ps2->nr_ipdopd_par, ps2->num_env, 0);
            remap34(&opd_mapped, ps2->opd_par, ps2->nr_ipdopd_par, ps2->num_env, 0);
        }
        if (!ps2->is34bands_old) {          // 从 20 带切到 34 带
            map_val_20_to_34(H11[0][0]); ... (H11..H22 的 0 层)
            ipdopd_reset(ipd_hist, opd_hist);
        }
    } else {
        remap20(&iid_mapped, ps2->iid_par, ps2->nr_iid_par, ps2->num_env, 1);
        remap20(&icc_mapped, ps2->icc_par, ps2->nr_icc_par, ps2->num_env, 1);
        if (ps2->enable_ipdopd) { ... }
        if (ps2->is34bands_old) {           // 从 34 带切到 20 带
            map_val_34_to_20(H11[0][0]); ...
            ipdopd_reset(ipd_hist, opd_hist);
        }
    }

    // 2) 每包络 e、每参数带 b：从 H_LUT 查 h11..h22（复系数），可选做 ipd/opd 相位旋转
    for (e = 0; e < ps2->num_env; e++) {
        for (b = 0; b < NR_PAR_BANDS[is34]; b++) {
            h11 = H_LUT[iid_mapped[e][b] + 7 + 23*ps2->iid_quant][icc_mapped[e][b]][0];
            h12 = ... [1];  h21 = ... [2];  h22 = ... [3];
            //   行索引 = iid 编码值 + 7（粗）或 + 30（细）；列 = icc 值 0..7

            if (!PS_BASELINE && ps2->enable_ipdopd && b < NR_IPDOPD_BANDS[is34]) {
                // 相位平滑 + 旋转（spec 说仅 enable_ipdopd 时执行，但参考解码器似乎常开）
                opd_idx = opd_hist[b] * 8 + opd_mapped[e][b];    // 0..511（最近 3 个相位编码）
                ipd_idx = ipd_hist[b] * 8 + ipd_mapped[e][b];
                opd_re = pd_re_smooth[opd_idx]; opd_im = pd_im_smooth[opd_idx];
                ipd_re = pd_re_smooth[ipd_idx]; ipd_im = pd_im_smooth[ipd_idx];
                opd_hist[b] = opd_idx & 0x3F;                     // 保留最近 2 个相位
                ipd_hist[b] = ipd_idx & 0x3F;
                ipd_adj_re = opd_re*ipd_re + opd_im*ipd_im;       // 复数乘法 opd * ipd
                ipd_adj_im = opd_im*ipd_re - opd_re*ipd_im;
                h11i = h11*opd_im;   h11 = h11*opd_re;            // 实部乘 opd，虚部……
                h12i = h12*ipd_adj_im; h12 = h12*ipd_adj_re;
                h21i = h21*opd_im;   h21 = h21*opd_re;
                h22i = h22*ipd_adj_im; h22 = h22*ipd_adj_re;
                H11[1][e+1][b] = h11i;  H12[1][e+1][b] = h12i;    // [1] = 虚部层
                H21[1][e+1][b] = h21i;  H22[1][e+1][b] = h22i;
            }
            H11[0][e+1][b] = h11;  H12[0][e+1][b] = h12;          // [0] = 实部层
            H21[0][e+1][b] = h21;  H22[0][e+1][b] = h22;
        }

        // 3) 每子子带 k：包络边界间线性插值 H 并应用
        for (k = 0; k < NR_BANDS[is34]; k++) {
            INTFLOAT h[2][4], h_step[2][4];
            int start = ps2->border_position[e];      // 本包络起（槽号）
            int stop  = ps2->border_position[e+1];    // 本包络止
            INTFLOAT width = 1.f / ((stop - start) ? (stop - start) : 1);  // 插值步长
            b = k_to_i[k];                            // 子子带 k → 参数带 b
            h[0][0] = H11[0][e][b];  h[0][1] = H12[0][e][b];   // 起点 = 上包络末系数
            h[0][2] = H21[0][e][b];  h[0][3] = H22[0][e][b];
            if (!PS_BASELINE && ps2->enable_ipdopd) {
                // 特定子子带区段相位取负（k=9..13 in 34带；k=0..1 in 20带）
                if ((is34 && k <= 13 && k >= 9) || (!is34 && k <= 1)) {
                    h[1][0] = -H11[1][e][b]; h[1][1] = -H12[1][e][b];
                    h[1][2] = -H21[1][e][b]; h[1][3] = -H22[1][e][b];
                } else {
                    h[1][0] = H11[1][e][b]; ...
                }
            }
            // 终点系数与起点的差 × width 得每时隙插值步长
            h_step[0][0] = (H11[0][e+1][b] - h[0][0]) * width;  ...
            if (!PS_BASELINE && ps2->enable_ipdopd) { h_step[1][*] = (H11[1][e+1][b] - h[1][*]) * width; }
            if (stop - start)
                ps->dsp.stereo_interpolate[!PS_BASELINE && ps2->enable_ipdopd](
                    l[k] + 1 + start, r[k] + 1 + start, h, h_step, stop - start);
        }
    }
}
```

插值区段槽号 = `[border[e]+1, border[e+1]]`，共 `stop-start` 个时隙；slot 0 由上一帧末包络覆盖（`H[0]` 槽保证连续）。

### 5.4 `hybrid_synthesis`（aacps.c 145-184 行）

```c
static void hybrid_synthesis(PSDSPContext *dsp, INTFLOAT out[2][38][64],
                             INTFLOAT in[91][32][2], int is34, int len)
{
    if (is34) {                       // 34 带综合
        for (n = 0; n < len; n++) {
            memset(out[0][n], 0, 5*sizeof);  memset(out[1][n], 0, 5*sizeof);  // 前 5 个 QMF 子带清零
            for (i = 0; i < 12; i++) { out[0][n][0] += in[ i][n][0]; out[1][n][0] += in[ i][n][1]; }
            for (i = 0; i <  8; i++) { out[0][n][1] += in[12+i][n][0]; out[1][n][1] += in[12+i][n][1]; }
            for (i = 0; i <  4; i++) {
                out[0][n][2] += in[20+i][n][0]; out[1][n][2] += in[20+i][n][1];
                out[0][n][3] += in[24+i][n][0]; out[1][n][3] += in[24+i][n][1];
                out[0][n][4] += in[28+i][n][0]; out[1][n][4] += in[28+i][n][1];
            }
        }
        dsp->hybrid_synthesis_deint(out, in + 27, 5, len);   // 子子带 32..90 → QMF 带 5..63
    } else {                          // 20 带综合
        for (n = 0; n < len; n++) {
            out[0][n][0] = in[0][n][0] + in[1][n][0] + in[2][n][0] + in[3][n][0] + in[4][n][0] + in[5][n][0];
            out[1][n][0] = 同上取 [1]；
            out[0][n][1] = in[6][n][0] + in[7][n][0];  out[1][n][1] = ...;
            out[0][n][2] = in[8][n][0] + in[9][n][0];  out[1][n][2] = ...;
        }
        dsp->hybrid_synthesis_deint(out, in + 7, 3, len);    // 子子带 10..70 → QMF 带 3..63
    }
}
```

即综合 = 分析的逆：同 QMF 子带的多个子子带求和，未拆分的高频子带直接透传。

---

## 6. DSP 函数逐条（aacpsdsp_template.c）

以下所有 `AAC_MUL*/AAC_MADD*/AAC_MSUB*` 在 float 路径下退化为普通乘加（见 §9）。`UINTFLOAT` = `float`。

### 6.1 `ps_add_squares_c`

```c
static void ps_add_squares_c(INTFLOAT *restrict dst, const INTFLOAT (*src)[2], int n)
{
    for (int i = 0; i < n; i++)
        dst[i] += src[i][0]*src[i][0] + src[i][1]*src[i][1];   // 累加复能量
}
```

### 6.2 `ps_mul_pair_single_c`

```c
static void ps_mul_pair_single_c(INTFLOAT (*restrict dst)[2], INTFLOAT (*src0)[2],
                                 INTFLOAT *src1, int n)
{
    for (int i = 0; i < n; i++) {
        dst[i][0] = src0[i][0] * src1[i];   // 复数 × 实数（标量增益）
        dst[i][1] = src0[i][1] * src1[i];
    }
}
```

### 6.3 `ps_hybrid_analysis_c`

13 抽头对称复滤波器（利用对称性减少乘法）：

```c
static void ps_hybrid_analysis_c(INTFLOAT (*restrict out)[2], INTFLOAT (*in)[2],
                                 const INTFLOAT (*filter)[8][2], ptrdiff_t stride, int n)
{
    INTFLOAT inre0[6], inre1[6], inim0[6], inim1[6];   // 对称组合
    for (int j = 0; j < 6; j++) {                     // 13 抽头：中心 1 + 6 对
        inre0[j] = in[j][0] + in[12 - j][0];          // 实部同相和
        inre1[j] = in[j][1] - in[12 - j][1];          // 实部反相（虚部差）
        inim0[j] = in[j][1] + in[12 - j][1];          // 虚部同相和
        inim1[j] = in[j][0] - in[12 - j][0];          // 虚部反相（实部差）
    }
    for (int i = 0; i < n; i++) {
        sum_re = filter[i][6][0] * in[6][0];          // 中心抽头（filter[6] 实部）
        sum_im = filter[i][6][0] * in[6][1];
        for (int j = 0; j < 6; j++) {
            sum_re += filter[i][j][0]*inre0[j] - filter[i][j][1]*inre1[j];
            sum_im += filter[i][j][0]*inim0[j] + filter[i][j][1]*inim1[j];
        }
        out[i*stride][0] = sum_re;                    // float：直接写
        out[i*stride][1] = sum_im;
    }
}
```

`filter[i][j][0]=prototype[n]·cosθ`，`filter[i][j][1]=-prototype[n]·sinθ`（θ=2π(q+0.5)(n-6)/bands，n=j）。每个输出带 i 一组复数滤波器系数。

### 6.4 `ps_hybrid_analysis_ileave_c`

```c
static void ps_hybrid_analysis_ileave_c(INTFLOAT (*restrict out)[32][2],
                                        INTFLOAT L[2][38][64], int i, int len)
{
    for (; i < 64; i++)                        // QMF 子带 i 起
        for (int j = 0; j < len; j++) {        // 时隙 j
            out[i][j][0] = L[0][j][i];         // 实部：时隙×子带转置写入
            out[i][j][1] = L[1][j][i];
        }
}
```

注意调用时基址 `out+7`（20 带）或 `out+27`（34 带），起始 i=3 或 5，从而填到 out[10..70] / out[32..90]。

### 6.5 `ps_hybrid_synthesis_deint_c`

```c
static void ps_hybrid_synthesis_deint_c(INTFLOAT out[2][38][64],
                                        INTFLOAT (*restrict in)[32][2], int i, int len)
{
    for (; i < 64; i++)
        for (int n = 0; n < len; n++) {
            out[0][n][i] = in[i][n][0];       // ileave 的逆：子子带 → QMF 带
            out[1][n][i] = in[i][n][1];
        }
}
```

### 6.6 `ps_decorrelate_c`（三级全通链）

```c
static void ps_decorrelate_c(INTFLOAT (*out)[2], INTFLOAT (*delay)[2],
                             INTFLOAT (*ap_delay)[PS_QMF_TIME_SLOTS+PS_MAX_AP_DELAY][2],
                             const INTFLOAT phi_fract[2], const INTFLOAT (*Q_fract)[2],
                             const INTFLOAT *transient_gain, INTFLOAT g_decay_slope, int len)
{
    static const INTFLOAT a[] = { 0.65143905753106f, 0.56471812200776f, 0.48954165955695f };
    INTFLOAT ag[PS_AP_LINKS];
    for (m = 0; m < 3; m++) ag[m] = a[m] * g_decay_slope;   // 每链路增益

    for (n = 0; n < len; n++) {
        // 整体分数延迟 phi_fract 旋转（乘复数 phi_fract[k]）
        in_re = delay[n][0]*phi_fract[0] - delay[n][1]*phi_fract[1];
        in_im = delay[n][0]*phi_fract[1] + delay[n][1]*phi_fract[0];
        for (m = 0; m < PS_AP_LINKS; m++) {
            a_re = ag[m] * in_re;  a_im = ag[m] * in_im;         // 反馈项
            link_delay_re = ap_delay[m][n + 2 - m][0];           // 该链路历史输出（链间错位延迟）
            link_delay_im = ap_delay[m][n + 2 - m][1];
            frac_re = Q_fract[m][0];  frac_im = Q_fract[m][1];   // 分数延迟旋转
            apd_re = in_re;  apd_im = in_im;                     // 暂存本链路输入
            // 一级全通：in_new = link_delay * Q_fract - a*in
            in_re = link_delay_re*frac_re - link_delay_im*frac_im - a_re;
            in_im = link_delay_re*frac_im + link_delay_im*frac_re - a_im;
            // 写回延迟：ap_delay[m][n+5] = in + ag*in_new（直接 I 型全通）
            ap_delay[m][n+5][0] = apd_re + ag[m]*in_re;
            ap_delay[m][n+5][1] = apd_im + ag[m]*in_im;
        }
        // 瞬态增益缩放
        out[n][0] = transient_gain[n] * in_re;
        out[n][1] = transient_gain[n] * in_im;
    }
}
```

链路读取错位：m=0 读 `ap_delay[0][n+2]`，m=1 读 `[n+1]`，m=2 读 `[n]`（对应链路延迟 2/1/0 采样 + 分数延迟 0.43/0.75/0.347）。

### 6.7 `ps_stereo_interpolate_c`（无 ipd/opd）

```c
static void ps_stereo_interpolate_c(INTFLOAT (*l)[2], INTFLOAT (*r)[2],
                                    INTFLOAT h[2][4], INTFLOAT h_step[2][4], int len)
{
    h0..h3 = h[0][0..3]; hs0..hs3 = h_step[0][0..3];     // 只处理实部层
    for (n = 0; n < len; n++) {
        l_re = l[n][0]; l_im = l[n][1]; r_re = r[n][0]; r_im = r[n][1];
        h0 += hs0; h1 += hs1; h2 += hs2; h3 += hs3;      // 逐时隙线性插值
        l[n][0] = h0*l_re + h2*r_re;                     // l = h11*s + h21*d
        l[n][1] = h0*l_im + h2*r_im;
        r[n][0] = h1*l_re + h3*r_re;                     // r = h12*s + h22*d
        r[n][1] = h1*l_im + h3*r_im;
    }
}
```

### 6.8 `ps_stereo_interpolate_ipdopd_c`

与 6.7 相同但使用实部+虚部两层系数（8 个插值系数），把 s 与 d 的虚部交叉相乘：

```c
    h00=h[0][0], h01=h[0][1], h02=h[0][2], h03=h[0][3];   // 实部层 h[0]
    h10=h[1][0], h11=h[1][1], h12=h[1][2], h13=h[1][3];   // 虚部层 h[1]
    ... 对应 hs 步长 ...
    for (n = 0; n < len; n++) {
        h00+=hs00; ... h13+=hs13;
        l[n][0] =  h00*l_re + h02*r_re - h10*l_im - h12*r_im;
        l[n][1] =  h00*l_im + h02*r_im + h10*l_re + h12*r_re;
        r[n][0] =  h01*l_re + h03*r_re - h11*l_im - h13*r_im;
        r[n][1] =  h01*l_im + h03*r_im + h11*l_re + h13*r_re;
    }
```

---

## 7. 表清单与生成公式

### 7.1 `aacpsdata.c`（静态，非生成）

| 表 | 类型/尺寸 | 内容 |
|---|---|---|
| `huff_sizes[10]` | uint8[10] | {61,61,29,29,15,15,8,8,8,8} |
| `aacps_huff_tabs[][2]` | uint8[242][2] | 10 张 Huffman 表 {symbol, code_length}（顺序见 §3.6） |
| `huff_offset[10]` | int8[10] | {-30,-30,-14,-14,-7,-7,0,0,0,0} |
| `ff_k_to_i_20[71]` | int8[71] | 子子带 k → 参数带 i（20 带，表 8.48） |
| `ff_k_to_i_34[91]` | int8[91] | 子子带 k → 参数带 i（34 带，表 8.49） |

`ff_k_to_i_*` 数值直接照抄（见 aacpsdata.c 100-113 行）。

### 7.2 位流参数表（aacps_common.c，静态）

`num_env_tab`、`nr_iidicc_par_tab`、`nr_iidopd_par_tab`（见 §3.3）。

### 7.3 `ps_tableinit()` 生成的浮点表（aacps_tablegen.h 85-214 行）

非 `CONFIG_HARDCODED_TABLES` 模式下由 `ff_ps_init()` 调 `ps_tableinit()` 在运行时计算；`aacps_tables.h` 为预生成硬编码版本（本仓库未提供，需自行生成）。生成步骤：

**A. `pd_re_smooth` / `pd_im_smooth`[512]**：相位平滑表

```c
ipdopd_cos[] = {1, √2/2, 0, -√2/2, -1, -√2/2, 0, √2/2};
ipdopd_sin[] = {0, √2/2, 1, √2/2,  0, -√2/2, -1, -√2/2};
for (pd0,pd1,pd2 in 0..7) {
    re_smooth = 0.25*cos[pd0] + 0.5*cos[pd1] + cos[pd2];   // 加权（最近者权最大）
    im_smooth = 0.25*sin[pd0] + 0.5*sin[pd1] + sin[pd2];
    pd_mag = 1 / hypot(im_smooth, re_smooth);               // 归一化到单位圆
    pd_re_smooth[pd0*64+pd1*8+pd2] = re_smooth * pd_mag;
    pd_im_smooth[pd0*64+pd1*8+pd2] = im_smooth * pd_mag;
}
```

**B. `HA`/`HB`[46][8][4]**：混合矩阵查表。行 = iid 索引 j（`iid_mapped+7+23*iid_quant`，0..45），列 = icc 值（0..7），元素 = [h11,h12,h21,h22]：

```c
// 混合方式 A（PS_BASELINE || icc_mode<3）
for (iid = 0; iid < 46; iid++) {
    c  = iid_par_dequant[iid];                  // 线性强度比
    c1 = M_SQRT2 / sqrt(1 + c*c);
    c2 = c * c1;
    for (icc = 0; icc < 8; icc++) {
        alpha = 0.5 * acos_icc_invq[icc];
        beta  = alpha * (c1 - c2) * M_SQRT1_2;
        HA[iid][icc][0] = c2 * cos(beta + alpha);
        HA[iid][icc][1] = c1 * cos(beta - alpha);
        HA[iid][icc][2] = c2 * sin(beta + alpha);
        HA[iid][icc][3] = c1 * sin(beta - alpha);
    }
}
// 混合方式 B（icc_mode>=3）
for (iid = 0; iid < 46; iid++) {
    c = iid_par_dequant[iid];  c1/c2 同上；
    for (icc = 0; icc < 8; icc++) {
        rho   = FFMAX(icc_invq[icc], 0.05f);
        alpha = 0.5 * atan2f(2*c*rho, c*c - 1);
        mu    = c + 1/c;  mu = sqrt(1 + (4*rho*rho - 4)/(mu*mu));
        gamma = atanf(sqrt((1-mu)/(1+mu)));
        if (alpha < 0) alpha += M_PI/2;
        alpha_c=cos(alpha); alpha_s=sin(alpha); gamma_c=cos(gamma); gamma_s=sin(gamma);
        HB[iid][icc][0] =  M_SQRT2 * alpha_c * gamma_c;
        HB[iid][icc][1] =  M_SQRT2 * alpha_s * gamma_c;
        HB[iid][icc][2] = -M_SQRT2 * alpha_s * gamma_s;
        HB[iid][icc][3] =  M_SQRT2 * alpha_c * gamma_s;
    }
}
```

依赖表：`iid_par_dequant[46]`（§4.1）、`icc_invq[8]`、`acos_icc_invq[8]`（§4.2）。

**C. 混合分析滤波器** `f20_0_8[8][8][2]`、`f34_0_12[12][8][2]`、`f34_1_8[8][8][2]`、`f34_2_4[4][8][2]`：

```c
// 原型滤波器（低频原型，含中心抽头 7 个）
g0_Q8  = {0.00746082949812f, 0.02270420949825f, 0.04546865930473f, 0.07266113929591f,
          0.09885108575264f, 0.11793710567217f, 0.125f};
g0_Q12 = {0.04081179924692f, 0.03812810994926f, 0.05144908135699f, 0.06399831151592f,
          0.07428313801106f, 0.08100347892914f, 0.08333333333333f};
g1_Q8  = {0.01565675600122f, 0.03752716391991f, 0.05417891378782f, 0.08417044116767f,
          0.10307344158036f, 0.12222452249753f, 0.125f};
g2_Q4  = {-0.05908211155639f, -0.04871498374946f, 0.0f, 0.07778723915851f,
           0.16486303567403f, 0.23279856662996f, 0.25f};

make_filters_from_proto(filter, proto, bands):     // bands = 8/12/8/4
    for (q = 0; q < bands; q++)
        for (n = 0; n < 7; n++) {
            theta = 2 * M_PI * (q + 0.5) * (n - 6) / bands;
            filter[q][n][0] = proto[n] *  cos(theta);
            filter[q][n][1] = proto[n] * -sin(theta);
        }
```

另有 `g1_Q2`（aacps.c 37-40 行，用于 `hybrid2_re`，2 拆 1，抽头 1,3,5）：

```c
static const INTFLOAT g1_Q2[] = { 0.0f, 0.01899487526049f, 0.0f, -0.07293139167538f,
                                  0.0f, 0.30596630545168f, 0.5f };
```

**D. 去相关表**：

```c
fractional_delay_links[] = { 0.43f, 0.75f, 0.347f };   // 每链路分数延迟（时隙）
fractional_delay_gain    = 0.39f;

for (k = 0; k < NR_ALLPASS_BANDS20; k++) {             // 20 带：30 个全通带
    f_center = (k < 10) ? f_center_20[k]*0.125f : k - 6.5f;
    for (m = 0; m < 3; m++) {
        theta = -M_PI * fractional_delay_links[m] * f_center;
        Q_fract_allpass[0][k][m] = {cos(theta), sin(theta)};
    }
    theta = -M_PI * fractional_delay_gain * f_center;
    phi_fract[0][k] = {cos(theta), sin(theta)};
}
for (k = 0; k < NR_ALLPASS_BANDS34; k++) {             // 34 带：50 个全通带
    f_center = (k < 32) ? f_center_34[k]/24.0f : k - 26.5f;
    ...同上，写入 [1][k]...
}
// f_center_20 = {-3,-1,1,3,5,7,10,14,18,22}
// f_center_34 = {2,6,10,14,18,22,26,30,34,-10,-6,-2,51,57,15,21,27,33,39,45,54,66,78,42,
//                102,66,78,90,102,114,126,90}
```

`Q_fract_allpass[2][50][3][2]`（2 带宽 × 50 带 × 3 链路 × [re,im]）、`phi_fract[2][50][2]`。

### 7.4 关于 `hann_128_96` 等

本 FFmpeg 版本**不使用** Hann 窗与 `hann_128_96`/`hann_64_96`，混合滤波器完全由 §7.3-C 的原型滤波器公式生成。若移植目标是等价于 FFmpeg 的参考行为，无需引入 Hann 表；若目标代码源自 VLC/faad 等其他实现并依赖这些表，则应以其为准并对照本文档 §5.1 的混合结构确认接口语义。

---

## 8. 混合方式（`bs_hybrid_mode`）说明

FFmpeg 的 PS 不读取 `bs_hybrid_mode` 位。混合（hybrid）滤波器的结构由 `is34bands` 决定（§3.3 第 10 步推导）：

| 模式 | 触发 | 子带拆分 | 子子带数 | QMF 透传 |
|---|---|---|---|---|
| 20 带 | `nr_iid_par≠34 且 nr_icc_par≠34` | 带0→6（f20_0_8）、带1→2、带2→2（g1_Q2） | 10 | 带3..63 → 子子带10..70，共 71 |
| 34 带 | `nr_iid_par==34 或 nr_icc_par==34` | 带0→12、带1→8、带2→4、带3→4、带4→4 | 32 | 带5..63 → 子子带32..90，共 91 |

混合矩阵的“混合方式 A/B”选择 = `(PS_BASELINE || icc_mode < 3) ? HA : HB`（§5.3 第 0 步），对应 ISO 参考中的 HA/HB 表选择。

---

## 9. 浮点宏等价（aac_defines.h，USE_FIXED=0）

```c
typedef float INTFLOAT, UINTFLOAT, INT64FLOAT;
Q30(x) == Q31(x) == (float)(x)                 // 恒等
AAC_MUL16(x,y) = x*y      AAC_MUL26(x,y) = x*y      AAC_MUL30(x,y) = x*y   AAC_MUL31(x,y) = x*y
AAC_MADD28(x,y,a,b) = x*y + a*b                AAC_MADD30(x,y,a,b) = x*y + a*b
AAC_MADD30_V8(x,y,a,b,c,d,e,f) = x*y + a*b + c*d + e*f
AAC_MSUB30(x,y,a,b) = x*y - a*b
AAC_MSUB30_V8(x,y,a,b,c,d,e,f) = x*y + a*b - c*d - e*f
AAC_MSUB31_V3(x,y,z) = (x - y) * z
AAC_HALF_SUM(x,y) = (x + y) * 0.5f
AAC_RENAME(x) = x         // float 路径不加后缀
```

`DECLARE_ALIGNED(16, T, name)` 仅要求 16 字节对齐（Zig 用 `align(16)`）。`LOCAL_ALIGNED_16` 同义。

---

## 10. 调用上下文与生命周期

```c
// 初始化：每解码器一次
ff_ps_init_common();          // 构建 10 张 VLC 表（全局）
ff_ps_init();                 // ps_tableinit()：构建全部浮点表（全局）
// PSContext 初始化：ff_ps_ctx_init(&ps->common 所属的 ps) → ff_psdsp_init(&ps->dsp)

// 每帧：SBR 解析扩展时
ff_ps_read_data(avctx, gb, &sbr->ps.common, bits_left);   // 解析参数（§3）

// 每帧：QMF 域合成时（仅在 ps.common.start==1 时）
ff_ps_apply(&sbr->ps, sbr->X[0], sbr->X[1], sbr->kx[1] + sbr->m[1]);
//   X[0]=左（原 mono），X[1]=右（被填充）；top = SBR 最高子带+1
//   若 !start：R 直接拷贝 L（aacsbr_template.c:1764）
```

---

## 11. 移植注意点（Zig 建议要点）

1. **表构建**：`aacps_tables.h` 在本仓库未生成，需在 Zig 端实现 `ps_tableinit()` 的四个生成块（§7.3），或由构建脚本先跑 `aacps_tablegen`。注意所有表用 `const` 只读即可（float 路径 `TABLE_CONST` 空展开）。
2. **VLC**：最省事是复刻 `ff_vlc_init_from_lengths` + `build_table`（约 60 行），把 `aacps_huff_tabs` 原样搬为 Zig 常量；解码用 §3.5 的三级查找。注意表数据为 {u8 symbol, u8 len} 交错存储，stride 2。
3. **位读取**：MSB-first（`get_bits`/`get_bits1` 语义：从 buffer 按位前进，`get_bits(n)` 读 `n` 位无符号）。`ff_ps_read_data` 在副本上解析、成功后推进宿主上下文——Zig 可用一个封装 BitReader。
4. **平面内存与别名**：`hybrid4_8_12_cx` 依赖 `out[0][i+32*j]` 的平面别名把结果写到 `out[j][i]`。Zig 中直接写 `out[j][i]` 即可，无需别名技巧。
5. **状态跨帧**：`delay`/`ap_delay`/`peak_decay_*`/`H*[0]` 槽/`opd_hist`/`ipd_hist`/`in_buf`（混合分析输入环形缓冲）都必须跨帧保留；带宽模式切换（is34bands 变化）时按 §5.2/§5.3 复位相关状态。
6. **边界条件**：`ff_ps_read_data` 的 `bits_left` 约束（消费超限→整帧失败）、`enable_ext` 的 `cnt` 循环（`cnt-=2+...`，`cnt<0` 报错）、伪造包络逻辑（§3.3 第 9 步）都要照搬。
7. **浮点精度**：float 路径无移位/舍入，直接 IEEE 乘法；`1/(stop-start)`、`1/hypot`、`sqrtf/atan2f/cosf` 等按 C 语义即可，无需位精确匹配（与参考解码器位级一致要求时除外）。
8. **H_LUT 行索引**：`iid_mapped + 7 + 23*iid_quant`，粗=0..14、细=15..45，恒落在 [0,46)。ICC 列 0..7。
9. **`start` 标志**：解析成功且 `header==1` 才置 1；应用端（ff_ps_apply）仅在 `start` 时执行，否则 R=L 拷贝。
```

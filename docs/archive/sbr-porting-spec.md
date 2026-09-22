# FFmpeg AAC SBR（频谱带复制）Zig 移植规格文档

> 研究对象：`libavcodec/aacsbr_template.c`（非 USAC 路径）、`libavcodec/aacsbr.c`（`make_bands`/`exp2fi` 确认）、`libavcodec/sbrdsp_template.c`、`libavcodec/sbrdsp.c`、`libavcodec/aacsbrdata.h`、`libavcodec/sbr.h`、`libavcodec/aacsbr.h`、`libavcodec/aac/aacdec_tab.c`（SBR VLC 表）
>
> 浮点路径（`USE_FIXED 0`）为移植基线。本文档每个函数给出 C 关键片段 + 逐行语义。

---

## 0. 总览：SBR 解码流水线与数据流

```
比特流解码（每帧一次）
  ff_aac_sbr_decode_extension()
    ├─ read_sbr_header()            —— 头解析，检测 spectrum 参数变化 → sbr->reset
    ├─ sbr_reset()                  —— 若 reset：
    │    ├─ sbr_make_f_master()     —— 主频带表 f_master / k[0..2] / n_master
    │    └─ sbr_make_f_derived()    —— f_tablelow/high/noise/lim + patch 构造 + n_q
    └─ read_sbr_data()
         ├─ read_sbr_single_channel_element()
         │    ├─ read_sbr_grid()        —— 时间边界 t_env / t_q / bs_freq_res
         │    ├─ read_sbr_dtdf()        —— 差分编码标志 bs_df_env / bs_df_noise
         │    ├─ read_sbr_invf()        —— 逆滤波模式 bs_invf_mode
         │    ├─ read_sbr_envelope()    —— 包络去量化因子 env_facs_q
         │    └─ read_sbr_noise()       —— 噪声因子 noise_facs_q
         └─ read_sbr_channel_pair_element()  —— 同上，含 bs_coupling 分支

每帧 PCM 处理（ff_aac_sbr_apply）
  ① sbr_qmf_analysis()      —— 时域 L/R → 32 子带复数 QMF 系数 W（2× 过采样）
  ② sbr_lf_gen()            —— W → X_low（低带，40 时间样本）
  ③ sbr_hf_inverse_filter() —— X_low → alpha0/alpha1（逆滤波系数，仅 start 帧）
  ④ sbr_chirp()             —— bw_array 平滑（仅 start 帧）
  ⑤ sbr_hf_gen()            —— X_low + alpha + bw → X_high（高频生成）
  ⑥ sbr_mapping()           —— env/noise 因子映射到子带 e_origmapped/q_mapped/s_mapped
  ⑦ sbr_env_estimate()      —— 从 X_high 估计 e_curr
  ⑧ sbr_gain_calc()         —— gain/q_m/s_m 计算与限幅
  ⑨ sbr_hf_assemble()       —— X_high + gain/noise → Y（含正弦、噪声注入）
  ⑩ sbr_x_gen()             —— X_low/Y0/Y1 → X（重建子带信号，38 时间样本）
  ⑪ sbr_qmf_synthesis()     —— X → 时域输出 L/R（可选 2× 下采样）

状态跨帧传递的字段（Zig 需原样保留）：
  - sbr->kx[0]=kx[1]、m[0]=m[1]（ff_aac_sbr_apply 开头 push/pop，见 kx_and_m_pushed）
  - ch_data->bs_freq_res[0] ← 上帧 bs_freq_res[bs_num_env]
  - ch_data->t_env_num_env_old = 上帧 t_env[bs_num_env]
  - ch_data->e_a[0] ← 上帧 e_a[1] 与 num_env 的比较
  - env_facs_q[0] / noise_facs_q[0] ← 上帧末行（read_sbr_envelope/noise 末尾 memcpy）
  - bs_invf_mode[1] ← bs_invf_mode[0]（read_sbr_invf 开头）
  - s_indexmapped[0] ← s_indexmapped[bs_num_env]（sbr_mapping 末尾）
  - analysis/synthesis 环形缓冲（x[1312]、v[2304] + offset）、Ypos 双缓冲
```

---

## 1. 类型与数据结构（Zig 需移植）

来源 `aac_defines.h` / `sbr.h`。浮点路径下：

| C 宏 | 浮点定义 |
|---|---|
| `INTFLOAT` | `float` |
| `AAC_FLOAT` | `float` |
| `AAC_SIGNE` | `unsigned` |
| `Q31(x)` / `Q23(x)` | `(float)(x)`（仅定点用） |

```c
typedef struct SpectrumParameters {
    uint8_t bs_start_freq;    // 4bit
    uint8_t bs_stop_freq;     // 4bit
    uint8_t bs_xover_band;    // 3bit（非 USAC）
    uint8_t bs_freq_scale;    // 2bit
    uint8_t bs_alter_scale;   // 1bit
    uint8_t bs_noise_bands;   // 2bit
} SpectrumParameters;         // 该结构体整体 memcmp 判定 reset

typedef struct SBRData {                       // 每通道
    unsigned  bs_frame_class;                  // FIXFIX/FIXVAR/VARFIX/VARVAR
    unsigned  bs_add_harmonic_flag;
    unsigned  bs_num_env;                      // 包络数 (1..5)
    uint8_t   bs_freq_res[9];                  // [0]=上帧末，[1..num_env]=本帧
    unsigned  bs_num_noise;                    // 噪声层数 (1..2)
    uint8_t   bs_df_env[9];                    // 每包络的差分标志
    uint8_t   bs_df_noise[2];                  // 每噪声层差分标志
    uint8_t   bs_invf_mode[2][5];              // [0]=本帧，[1]=上帧，n_q 项
    uint8_t   bs_add_harmonic[48];             // n[1] 项
    unsigned  bs_amp_res;
    // —— 状态 ——
    float     synthesis_filterbank_samples[2304]; // SBR_SYNTHESIS_BUF_SIZE=(1280-128)*2
    float     analysis_filterbank_samples [1312];
    int       synthesis_filterbank_samples_offset;
    int       e_a[2];                          // l_APrev, l_A
    float     bw_array[5];                     // chirp 因子，n_q 项
    float     W[2][32][32][2];                 // QMF 分析输出（复数），双缓冲
    int       Ypos;                            // 当前帧写入的 Y 缓冲索引 0/1
    float     Y[2][38][64][2];                 // hf_assemble 输出（复数）
    float     g_temp[42][48];                  // 增益平滑历史
    float     q_temp[42][48];                  // 噪声平滑历史
    uint8_t   s_indexmapped[9][48];            // 正弦出现标记（映射后）
    uint8_t   env_facs_q[9][48];               // 包络量化因子（去量化前）
    float     env_facs[9][48];                 // 包络因子（去量化后）
    uint8_t   noise_facs_q[3][5];              // 噪声量化因子
    float     noise_facs[3][5];
    uint8_t   t_env[9];                        // 包络时间边界 [0..num_env]
    uint8_t   t_env_num_env_old;               // 上帧末边界
    uint8_t   t_q[3];                          // 噪声时间边界 [0..num_noise]
    unsigned  f_indexnoise;                    // 噪声表游标（& 0x1ff）
    unsigned  f_indexsine;                     // 正弦符号游标（& 3）
} SBRData;

struct SpectralBandReplication {
    int    sample_rate;                        // SBR 采样率 = 2×AAC 采样率
    int    start;                              // 是否收到有效 SBR 头
    int    ready_for_dequant;
    int    id_aac;                             // TYPE_SCE/CPE/CCE
    int    reset;
    SpectrumParameters spectrum_params;
    int    bs_amp_res_header;
    unsigned bs_limiter_bands;                 // 2bit
    unsigned bs_limiter_gains;                 // 2bit
    unsigned bs_interpol_freq;                 // 1bit
    unsigned bs_smoothing_mode;                // 1bit
    unsigned bs_coupling;
    unsigned k[5];                             // k0,k1,k2（QMF 子带号）
    unsigned kx[2];                            // kx[1]=SBR 起始子带，kx[0]=上帧值
    unsigned m[2];                             // m[1]=SBR 子带数，m[0]=上帧值
    unsigned kx_and_m_pushed;
    unsigned n_master;
    SBRData  data[2];
    unsigned n[2];                             // n[0]=low 分辨率频带数，n[1]=high
    unsigned n_q;                              // 噪声频带数 (1..5)
    unsigned n_lim;                            // 限幅频带数
    uint16_t f_master[49];
    uint16_t f_tablelow[25];
    uint16_t f_tablehigh[49];
    uint16_t f_tablenoise[6];
    uint16_t f_tablelim[30];
    unsigned num_patches;                      // patch 数 (<=5，特殊流可 6)
    uint8_t  patch_num_subbands[6];
    uint8_t  patch_start_subband[6];
    float    X_low[32][40][2];                 // 低带输入到 HF 生成器
    float    X_high[64][40][2];                // HF 生成器输出
    float    X[2][2][38][64];                  // 重建子带（[ch][real/imag][time][band]）
    float    alpha0[64][2];                    // 逆滤波系数（复数）
    float    alpha1[64][2];
    float    e_origmapped[8][48];
    float    q_mapped[8][48];
    uint8_t  s_mapped[8][48];
    float    e_curr[8][48];                    // 估计包络
    float    q_m[8][48];
    float    s_m[8][48];
    float    gain[8][48];
    float    qmf_filter_scratch[5][64];        // QMF 分析/合成共用暂存（z 或 mdct_buf）
    // 以下由 Zig 直接实现替代，无需 AVTXContext：
    // AVTXContext *mdct_ana; av_tx_fn mdct_ana_fn;   // 分析 MDCT（inv=1, len=64, scale=-2*32768）
    // AVTXContext *mdct;     av_tx_fn mdct_fn;       // 合成 MDCT（inv=1, len=64, scale=1/(64*32768)）
    // SBRDSPContext dsp;  AACSBRContext c;           // 函数指针表，Zig 直接调用实现
};
```

---

## 2. 常量与宏

### 2.1 数学常量（`aacsbr.h` / `sbr.h`）

```c
#define ENVELOPE_ADJUSTMENT_OFFSET 2   // 帧时间轴 0 映射到 X 数组的索引 2（HF 生成滤波有 2 抽头延迟）
#define NOISE_FLOOR_OFFSET 6           // 噪声去量化偏移：noise_facs = 2^(6 - q)
#define SBR_SYNTHESIS_BUF_SIZE ((1280-128)*2)   // 2304
```

### 2.2 枚举（`aacsbr.h`）

```c
enum {  // bs_frame_class（2bit）
    FIXFIX = 0, FIXVAR = 1, VARFIX = 2, VARVAR = 3,
};
enum { EXTENSION_ID_PS = 2 };
enum {  // ff_aac_sbr_vlc[] 索引顺序（对应 aacdec_tab.c 的 sbr_huffman_tab 表序）
    T_HUFFMAN_ENV_1_5DB, F_HUFFMAN_ENV_1_5DB,
    T_HUFFMAN_ENV_BAL_1_5DB, F_HUFFMAN_ENV_BAL_1_5DB,
    T_HUFFMAN_ENV_3_0DB, F_HUFFMAN_ENV_3_0DB,
    T_HUFFMAN_ENV_BAL_3_0DB, F_HUFFMAN_ENV_BAL_3_0DB,
    T_HUFFMAN_NOISE_3_0DB, T_HUFFMAN_NOISE_BAL_3_0DB,
};
```
`TYPE_SCE/TYPE_CPE/TYPE_CCE` 见 `aac.h`：`SCE=0, CPE=1, CCE=2`。

### 2.3 `sbr_offset[6][16]`（`aacsbrdata.h`，int8_t）

按 SBR 采样率选行：
- 行 0: fs_sbr=16000 → `{-8,-7,-6,-5,-4,-3,-2,-1, 0, 1, 2, 3, 4, 5, 6, 7}`
- 行 1: 22050 → `{-5,-4,-3,-2,-1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13}`
- 行 2: 24000 → `{-5,-3,-2,-1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16}`
- 行 3: 32000 → `{-6,-4,-2,-1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16}`
- 行 4: 44100/48000/64000 → `{-4,-2,-1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16, 20}`
- 行 5: 88200/96000/128000/176400/192000 → `{-2,-1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16, 20, 24}`

索引 = `bs_start_freq`（4bit）。

### 2.4 QMF 窗口表（`aacsbrdata.h`）

- `sbr_qmf_window_ds[320]`：分析 QMF 与下采样合成 QMF 用。共 5×64 个系数。
- `sbr_qmf_window_us[640]`：全速率合成 QMF 用。共 10×64 个系数，关于 #320 对称，仅 384/512 两处符号取反（-Q31(0.3611589903) 处）。注意 us 表的 0.3611589903 处为 `-Q31(...)`，而 ds 表第 128..191 段的对应位置同为负。

数值必须以浮点原样移植（`Q31(x) → (float)(x)`，可直接把 C 表的十进制常数转为 `f32` 数组；或用 `@bitCast` 保存原始位型）。

### 2.5 噪声表 `ff_sbr_noise_table[520][2]`（`sbrdsp_template.c`）

- 前 512 项为 {实, 虚} 的 Q31 伪随机序列；末尾重复前 8 项（仅供 SIMD 过读，C 实现不访问）。
- 索引范围 `0..511`，实际使用 `index & 0x1ff`。
- 浮点路径 `Q31(x) → (float)(x)`。Zig 可直接拷出 520 对 `f32`。

### 2.6 SBR 去量化：**本版 FFmpeg 无 `vtab` 表**

> 说明：老版 FFmpeg / ISO 参考软件曾用查找表做包络去量化（即 "vtab"），但**当前参考树中不存在 vtab**。去量化完全由 `exp2fi()` 内联函数 + 2 元素 `exp2_tab` 完成，见 §3.2。移植时无需移植 vtab。

### 2.7 SBR Huffman VLC 表（`aac/aacdec_tab.c`）

- `sbr_huffman_tab[][2]`：10 张表，每项 `{symbol, length}`（码字按自然二进制序）。
- 表尺寸 `sbr_huffman_nb_codes[10] = {121, 121, 49, 49, 63, 63, 25, 25, 63, 25}`。
- 偏移 `sbr_vlc_offsets[10] = {-60, -60, -24, -24, -31, -31, -12, -12, -31, -12}`：解码值需加偏移。
- 解码深度 9（`ff_vlc_init_tables_from_lengths(..., 9, ...)`）。
- 表序（与 §2.2 枚举一致）：t/f_env_1_5dB → t/f_env_bal_1_5dB → t/f_env_3_0dB → t/f_env_bal_3_0dB → t_noise_3_0dB → t_noise_bal_3_0dB。

Zig 移植建议：将这 10 张表构建为静态 Huffman 解码表（9bit 直接查表法），或按长度排序的二叉树。码值范围（含偏移后）：env_3_0dB 表 `-31..+31`，env_1_5dB 表 `-60..+60`，bal 表 `-12..+12`。

### 2.8 其他小常量表（散布于代码中）

```c
// aacsbr.c sbr_dequant
static const double exp2_tab[2] = {1, M_SQRT2};      // = {1.0, 1.41421356}，用于 0.5dB 步进

// aacsbr.c sbr_chirp
static const float bw_tab[] = { 0.0f, 0.75f, 0.9f, 0.98f };

// aacsbr.c sbr_gain_calc
static const float limgain[4] = { 0.70795f, 1.0f, 1.41254f, 10000000000.0f }; // -3/0/+3dB, off

// aacsbr.c sbr_hf_assemble
static const float h_smooth[5] = { 0.33333333333333, 0.30150283239582,
                                   0.21816949906249, 0.11516383427084,
                                   0.03183050093751 };

// aacsbr_template.c sbr_make_f_tablelim
static const float bands_warped[3] = { 1.32715174233856803909f,   // 2^(0.49/1.2)
                                       1.18509277094158210129f,   // 2^(0.49/2)
                                       1.11987160404675912501f }; // 2^(0.49/3)

// aacsbr_template.c read_sbr_grid
static const int8_t ceil_log2[] = { 0, 1, 2, 2, 3, 3 };  // 索引=bs_num_env，读出 bs_pointer 的位数
```

---

## 3. aacsbr.c 的确认函数

### 3.1 `make_bands`（辅助：对数等分频带）

```c
static void make_bands(int16_t* bands, int start, int stop, int num_bands)
{
    int k, previous, present;
    float base, prod;
    base = powf((float)stop / start, 1.0f / num_bands);   // 每带几何比
    prod = start;   previous = start;
    for (k = 0; k < num_bands-1; k++) {
        prod *= base;                                      // 几何递增
        present  = lrintf(prod);                           // 最近整数（四舍五入）
        bands[k] = present - previous;                     // 存"增量"而非边界
        previous = present;
    }
    bands[num_bands-1] = stop - previous;                  // 最后一带兜底
}
```
语义：把 `[start, stop]` 按 `num_bands` 个几何等分的子带，输出各子带宽度（QMF 子带数）。`lrintf` = 四舍五入到最近整数（Zig：`@round`）。

### 3.2 `exp2fi`（整数指数 2^x，IEEE 位操作）

```c
static av_always_inline float exp2fi(int x) {
    if (-126 <= x && x <= 128)                       // 常规范围
        return av_int2float((x+127) << 23);          // 直接构造 float 指数位：2^x = (x+127)<<23 的位模式
    else if (x > 128)
        return INFINITY;
    else if (x > -150)                               // 次正规数
        return av_int2float(1 << (x+149));
    else
        return 0;
}
```
`av_int2float(u32)` = `@bitCast` 为 `f32`。`exp2fi(x)` 精确返回 `2.0^x`。SBR 全部去量化均用它，是移植关键函数之一。

### 3.3 `sbr_dequant`（用户已研读，此处只给结论 + exp2 映射公式）

- 非耦合（SCE 或 CPE 非耦合）：
  - 包络：`env_facs = exp2fi(q + 6)`（bs_amp_res=1，3dB 步进）；`exp2fi((q>>1)+6) * exp2_tab[q&1]`（bs_amp_res=0，1.5dB 步进，即 `2^(q/2+6)`）
  - 噪声：`noise_facs = exp2fi(NOISE_FLOOR_OFFSET - q) = 2^(6-q)`
- 耦合（CPE + bs_coupling）：双通道按 pan 公式分解，见 `aacsbr.c:86-147`。
- **无 vtab**。若希望用查表替代 `exp2fi`，其等价公式为 `value = 2^((q + offset)/2)`，可建 `[0..127]` 的 f32 表，但指数范围大（`2^(q+6)`，q∈0..127 → 2^6..2^133），查表需用 log 索引（qindex = 2×log2），故 FFmpeg 直接选 `exp2fi`。

---

## 4. 比特流读取函数（`aacsbr_template.c`）

比特流工具：`get_bits(gb,n)` 读 n bit；`get_bits1(gb)` 读 1 bit；`skip_bits`。Zig 侧需实现对应的 MSB-first 读位器。

### 4.1 `read_sbr_header`（非 USAC 部分）

```c
sbr->start = 1;  sbr->ready_for_dequant = 0;  sbr->usac = 0;
memcpy(&old_spectrum_params, &sbr->spectrum_params, ...);   // 保存旧参数
bs_amp_res_header          = get_bits1(gb);                 // 帧级 amp 分辨率
spectrum_params.bs_start_freq  = get_bits(gb, 4);
spectrum_params.bs_stop_freq   = get_bits(gb, 4);
spectrum_params.bs_xover_band  = get_bits(gb, 3);
skip_bits(gb, 2);                                            // bs_reserved
bs_header_extra_1 = get_bits1(gb);
bs_header_extra_2 = get_bits1(gb);
if (bs_header_extra_1) {
    bs_freq_scale  = get_bits(gb, 2);
    bs_alter_scale = get_bits1(gb);
    bs_noise_bands = get_bits(gb, 2);
} else { bs_freq_scale = 2; bs_alter_scale = 1; bs_noise_bands = 2; }  // 默认
if (memcmp(&old, &cur, sizeof(SpectrumParameters))) sbr->reset = 1;     // 变化→reset
if (bs_header_extra_2) {
    bs_limiter_bands = get_bits(gb, 2);
    bs_limiter_gains = get_bits(gb, 2);
    bs_interpol_freq = get_bits1(gb);
    bs_smoothing_mode= get_bits1(gb);
} else { bs_limiter_bands = 2; bs_limiter_gains = 2; bs_interpol_freq = 1; bs_smoothing_mode = 1; }
if (bs_limiter_bands != old && !sbr->reset) sbr_make_f_tablelim(sbr);   // 仅重算限幅表
```

### 4.2 `read_sbr_grid`（核心：时间边界生成）

输入：`numTimeSlots`（AAC 帧 16，960 帧 15）。`abs_bord_trail` 初始 = `numTimeSlots`。

**预置（使用上帧状态）：**
```c
ch_data->bs_freq_res[0] = ch_data->bs_freq_res[ch_data->bs_num_env]; // 上帧末频率分辨率
ch_data->bs_amp_res = sbr->bs_amp_res_header;
ch_data->t_env_num_env_old = ch_data->t_env[bs_num_env_old];         // 上帧末边界
```

**switch (bs_frame_class = get_bits(gb,2))：**

**① FIXFIX：**
```c
bs_num_env = 1 << get_bits(gb, 2);                    // {1,2,4,8}；非 USAC 且 >5 报错
ch_data->bs_num_env = bs_num_env;
num_rel_lead = bs_num_env - 1;
if (bs_num_env == 1) bs_amp_res = 0;                  // 单包络强制 1.5dB 分辨率
t_env[0] = 0;  t_env[bs_num_env] = abs_bord_trail;    // =16 (或15)
abs_bord_trail = (abs_bord_trail + (bs_num_env >> 1)) / bs_num_env;  // 等分步长（带 0.5 舍入）
for (i = 0; i < num_rel_lead; i++) t_env[i+1] = t_env[i] + abs_bord_trail; // 均匀网格
bs_freq_res[1] = get_bits1(gb);                       // 唯一 FREQ_RES，其余复制
for (i = 1; i < bs_num_env; i++) bs_freq_res[i+1] = bs_freq_res[1];
// 例(num=16)：num=4 → 步长(16+2)/4=4 → t_env={0,4,8,12,16}
```

**② FIXVAR（头固定、尾可变）：**
```c
abs_bord_trail += get_bits(gb, 2);                    // 16..19
num_rel_trail   = get_bits(gb, 2);
bs_num_env      = num_rel_trail + 1;                  // 1..4
t_env[0] = 0;  t_env[bs_num_env] = abs_bord_trail;
for (i = 0; i < num_rel_trail; i++)
    t_env[bs_num_env-1-i] = t_env[bs_num_env-i] - 2*get_bits(gb,2) - 2;  // 从尾向前，步长 2,4,6,8
bs_pointer = get_bits(gb, ceil_log2[bs_num_env]);
for (i = 0; i < bs_num_env; i++)
    bs_freq_res[bs_num_env - i] = get_bits1(gb);      // 注意：逆序填（从末包络到首）
```
**③ VARFIX（头可变、尾固定）：**
```c
t_env[0] = get_bits(gb, 2);                           // 0..3
num_rel_lead = get_bits(gb, 2);
bs_num_env   = num_rel_lead + 1;
t_env[bs_num_env] = abs_bord_trail;                   // = numTimeSlots
for (i = 0; i < num_rel_lead; i++)
    t_env[i+1] = t_env[i] + 2*get_bits(gb,2) + 2;     // 从首向后，步长 2,4,6,8
bs_pointer = get_bits(gb, ceil_log2[bs_num_env]);
get_bits1_vector(gb, bs_freq_res + 1, bs_num_env);    // 正序填 [1..num_env]
```
**④ VARVAR：**
```c
t_env[0] = get_bits(gb, 2);
abs_bord_trail += get_bits(gb, 2);
num_rel_lead  = get_bits(gb, 2);
num_rel_trail = get_bits(gb, 2);
bs_num_env    = num_rel_lead + num_rel_trail + 1;     // ≤5，否则报错
t_env[bs_num_env] = abs_bord_trail;
for (i = 0; i < num_rel_lead; i++)  t_env[i+1] = t_env[i] + 2*get_bits(gb,2) + 2; // 首→尾
for (i = 0; i < num_rel_trail; i++) t_env[bs_num_env-1-i] = t_env[bs_num_env-i] - 2*get_bits(gb,2) - 2; // 尾→首
bs_pointer = get_bits(gb, ceil_log2[bs_num_env]);
get_bits1_vector(gb, bs_freq_res + 1, bs_num_env);
```

**公共后处理：**
```c
ch_data->bs_frame_class = bs_frame_class;
// 校验：t_env 严格单调增；bs_pointer <= bs_num_env+1
bs_num_noise = (bs_num_env > 1) + 1;                  // 1 或 2
t_q[0] = t_env[0];  t_q[bs_num_noise] = t_env[bs_num_env];
if (bs_num_noise > 1) {                               // 求中间噪声边界 t_q[1]
    if (bs_frame_class == FIXFIX)      idx = bs_num_env >> 1;
    else if (bs_frame_class & 1)       idx = bs_num_env - FFMAX(bs_pointer-1, 1);  // FIXVAR/VARVAR
    else {                                             // VARFIX
        if (!bs_pointer) idx = 1;
        else if (bs_pointer == 1) idx = bs_num_env - 1;
        else idx = bs_pointer - 1;
    }
    t_q[1] = t_env[idx];
}
// l_APrev / l_A（用于 gain_calc 的 delta 模式）
e_a[0] = -(e_a[1] != bs_num_env_old);                 // 上帧 l_A 与本帧 num_env 比较，-1 或 0
e_a[1] = -1;                                          // 默认"无相邻包络"
if ((bs_frame_class & 1) && bs_pointer)               // FIXVAR/VARVAR 且 pointer≠0
    e_a[1] = bs_num_env + 1 - bs_pointer;
else if (bs_frame_class == 2 && bs_pointer > 1)       // VARFIX 且 pointer>1
    e_a[1] = bs_pointer - 1;
```
> `e_a` 语义：`e_a[0]` = 上一帧的 l_A 映射（delta 抑制的标志），`e_a[1]` = 本帧 l_A。值为 `-1` 表示该侧包络不参与平滑/允许 boost；≥0 时作为包络索引。`-1` 与 `>=0` 的区分在 `hf_assemble`/`gain_calc` 里以 `e != e_a[...]` 判断。

### 4.3 `copy_sbr_grid`（CPE 耦合时 ch1 复制 ch0）

只复制比特流读入字段，状态字段重新推导：
```c
dst->bs_freq_res[0]    = dst->bs_freq_res[dst->bs_num_env];
dst->t_env_num_env_old = dst->t_env[dst->bs_num_env];
dst->e_a[0]            = -(dst->e_a[1] != dst->bs_num_env);
memcpy(dst->bs_freq_res+1, src->bs_freq_res+1, ...);
memcpy(dst->t_env, src->t_env, ...);
memcpy(dst->t_q,   src->t_q,   ...);
dst->bs_num_env = src->bs_num_env;  dst->bs_amp_res = src->bs_amp_res;
dst->bs_num_noise = src->bs_num_noise;  dst->bs_frame_class = src->bs_frame_class;
dst->e_a[1] = src->e_a[1];
```

### 4.4 `read_sbr_dtdf`

非 USAC 路径：
```c
get_bits1_vector(gb, bs_df_env,   bs_num_env);    // 每个包络 1 bit
get_bits1_vector(gb, bs_df_noise, bs_num_noise);  // 每噪声层 1 bit
```
`bs_df_*` = 1 表示"时间差分"，0 表示"频率差分"。

### 4.5 `read_sbr_invf`

```c
memcpy(bs_invf_mode[1], bs_invf_mode[0], 5);       // 上帧逆滤波模式
for (i = 0; i < n_q; i++)
    bs_invf_mode[0][i] = get_bits(gb, 2);          // {0,1,2,3}
```
逆滤波模式值：0=none, 1=low, 2=medium, 3=high（影响 chirp 的 bw 与逆滤波）。

### 4.6 `read_sbr_envelope`（包络量化因子解码）

**参数选择：**
```c
delta = (ch == 1 && bs_coupling == 1) + 1;         // 耦合时 ch1 的码值需乘 2
odd   = n[1] & 1;
// 表/位宽选择（Huffman 表 + 起始值位宽 bits）：
//   耦合 ch1：bs_amp_res ? (5, T/F_ENV_BAL_3_0DB) : (6, T/F_ENV_BAL_1_5DB)
//   否则    ：bs_amp_res ? (6, T/F_ENV_3_0DB)     : (7, T/F_ENV_1_5DB)
```

**主循环（对每个包络 i = 0..bs_num_env-1）：**

`bs_df_env[i]==1`（时间差分，用 t_huff 每带独立解码）：
```c
if (bs_freq_res[i+1] == bs_freq_res[i])            // 频率分辨率未变：直接对应带
    for j in 0..n[fr]-1:
        env_facs_q[i+1][j] = env_facs_q[i][j] + delta * get_vlc(t_huff);
else if (bs_freq_res[i+1] == 1)                    // 低→高（n 变大，上采样映射）
    for j in 0..n[high]-1:
        k = (j + odd) >> 1;                        // 找 k 使 f_tablelow[k]<=f_tablehigh[j]<f_tablelow[k+1]
        env_facs_q[i+1][j] = env_facs_q[i][k] + delta * get_vlc(t_huff);
else                                               // 高→低（下采样映射）
    for j in 0..n[low]-1:
        k = j ? 2*j - odd : 0;                     // 找 k 使 f_tablehigh[k]==f_tablelow[j]
        env_facs_q[i+1][j] = env_facs_q[i][k] + delta * get_vlc(t_huff);
// 每步校验 0..127
```
`bs_df_env[i]==0`（频率差分，用 f_huff 沿频率累计）：
```c
env_facs_q[i+1][0] = delta * get_bits(gb, bits);   // bs_env_start_value
for j in 1..n[fr]-1:
    env_facs_q[i+1][j] = env_facs_q[i+1][j-1] + delta * get_vlc(f_huff);
// 校验 0..127
```

**末尾：** `memcpy(env_facs_q[0], env_facs_q[bs_num_env], ...)` 供下帧差分。

> `get_vlc(t_huff)` 解码值已含 vtab 偏移（sbr_vlc_offsets），即可为负。`delta` 使耦合 ch1 的量化步进加倍。

### 4.7 `read_sbr_noise`（噪声因子解码）

结构同包络，但：
```c
// 表：耦合ch1 → T_NOISE_BAL_3_0DB / F_ENV_BAL_3_0DB；否则 → T_NOISE_3_0DB / F_ENV_3_0DB
// 时间差分(t_huff)：每噪声层 i，每带 j<n_q：noise_facs_q[i+1][j] = noise_facs_q[i][j] + delta*t_huff
// 频率差分(f_huff)：noise_facs_q[i+1][0] = delta*get_bits(gb,5); j>=1: 累计 f_huff
// 校验范围 0..30
// 末尾：memcpy(noise_facs_q[0], noise_facs_q[bs_num_noise], ...)
```
注意噪声用 `bs_num_noise`（1 或 2）层，`n_q` 个频带。

### 4.8 `read_sbr_extension`

```c
switch (bs_extension_id) {
case EXTENSION_ID_PS:   // =2
    if (!ps) { skip_bits_long(gb, num_bits_left); num_bits_left = 0; }
    else {
        num_bits_left -= ff_ps_read_data(...);    // 参数立体声（另模块，可先占位）
        profile = AV_PROFILE_AAC_HE_V2;
    }
    break;
default:                // 保留扩展：通常直接跳过填充位
    skip_bits_long(gb, num_bits_left); num_bits_left = 0;
}
```
PS（参数立体声）为独立子系统，若仅移植 SBR 单声道/纯 SBR，可跳过（置 0 比特即可）。

### 4.9 `read_sbr_single_channel_element`

```c
if (get_bits1(gb)) skip_bits(gb, 4);              // bs_data_extra / bs_reserved
read_sbr_grid(...data[0]...);
read_sbr_dtdf(...data[0]...);
read_sbr_invf(...data[0]...);
read_sbr_envelope(...data[0], ch=0);
read_sbr_noise  (...data[0], ch=0);
bs_add_harmonic_flag = get_bits1(gb);
if (flag) get_bits1_vector(gb, bs_add_harmonic, n[1]);
```

### 4.10 `read_sbr_channel_pair_element`

```c
if (get_bits1(gb)) skip_bits(gb, 8);              // bs_data_extra
if ((bs_coupling = get_bits1(gb))) {
    read_sbr_grid(data[0]);  copy_sbr_grid(data[1], data[0]);  // ch1 完全复制 ch0
    read_sbr_dtdf(data[0]);  read_sbr_dtdf(data[1]);
    read_sbr_invf(data[0]);
    // ch1 的 invf：先移上一帧，再整体复制 ch0
    memcpy(data[1].bs_invf_mode[1], data[1].bs_invf_mode[0], 5);
    memcpy(data[1].bs_invf_mode[0], data[0].bs_invf_mode[0], 5);
    read_sbr_envelope(data[0], 0); read_sbr_noise(data[0], 0);
    read_sbr_envelope(data[1], 1); read_sbr_noise(data[1], 1);   // ch=1 → delta=2，bal 表
} else {                                             // 非耦合：两通道独立
    read_sbr_grid(data[0]);  read_sbr_grid(data[1]);
    read_sbr_dtdf ×2;  read_sbr_invf ×2;
    read_sbr_envelope(data[0],0); read_sbr_envelope(data[1],1);
    read_sbr_noise(data[0],0);    read_sbr_noise(data[1],1);
}
// 两通道各自的 bs_add_harmonic
```

### 4.11 `read_sbr_data`

```c
sbr->id_aac = id_aac;  sbr->ready_for_dequant = 1;
switch (id_aac) {
case SCE/CCE: read_sbr_single_channel_element(...)  // 失败→sbr_turnoff
case CPE:     read_sbr_channel_pair_element(...)
default:      错误→sbr_turnoff
}
// bs_extended_data（可含 PS）
if (get_bits1(gb)) {
    num_bits_left = get_bits(gb,4);                // bs_extension_size
    if (num_bits_left == 15) num_bits_left += get_bits(gb,8);  // bs_esc_count
    num_bits_left <<= 3;
    while (num_bits_left > 7) {
        num_bits_left -= 2;
        read_sbr_extension(gb, get_bits(gb,2), &num_bits_left);  // bs_extension_id
    }
    if (num_bits_left < 0) 错误;
    if (num_bits_left > 0) skip_bits(gb, num_bits_left);
}
```

### 4.12 `sbr_reset` 与 `sbr_make_f_master`（reset 路径上下文）

```c
static void sbr_reset(AACDecContext *ac, SpectralBandReplication *sbr) {
    err = sbr_make_f_master(ac, sbr, &sbr->spectrum_params);   // §4.13
    if (err >= 0) err = sbr_make_f_derived(ac, sbr);           // §6.1
    if (err < 0) sbr_turnoff(sbr);                             // 纯上采样模式兜底
}
```

**`sbr_make_f_master`（用户未点名但 reset 必经，概述）：**
1. 按 `sample_rate` 选 `sbr_offset` 行（§2.3）。
2. `temp = 3000/4000/5000`（fs<32k / <64k / else）。
3. `start_min = (temp<<7 + fs/2)/fs`；`stop_min = (temp<<8 + fs/2)/fs`。
4. `k[0] = start_min + sbr_offset[bs_start_freq]`。
5. `k[2]`：`bs_stop_freq<14` → `stop_min + Σ sorted(make_bands(stop_dk, stop_min, 64, 13))[0..stop_freq)`；`==14` → `2*k[0]`；`==15` → `3*k[0]`；裁剪到 64。
6. `k[2]-k[0]` 不得超过 `max_qmf_subbands`（fs≤32k:48 / 44.1k:35 / ≥48k:32）。
7. `bs_freq_scale==0`：`dk = bs_alter_scale+1`；`n_master = ((k2-k0 + (dk&2)) >> dk) << 1`；`f_master[k]=dk` 再修正头尾，累加为边界。
8. 否则：`half_bands = 7 - bs_freq_scale`；两段式（`two_regions = 49*k2 > 110*k0`）：
   - `k[1] = two_regions ? 2*k[0] : k[2]`
   - `num_bands_0 = lrintf(half_bands * log2f(k1/k0)) * 2`；`make_bands(vk0+1, k0, k1, num_bands_0)` + qsort + 累加。
   - `two_regions` 时：`num_bands_1 = lrintf(half_bands * invwarp * log2f(k2/k1)) * 2`，`invwarp = bs_alter_scale ? 0.76923077 : 1.0`；`make_bands(vk1+1,...)`；若 `min(vk1) < max(vk0)` 则两端子带收缩 `change = FFMIN(vdk0_max-vk1[1], (vk1[last]-vk1[1])>>1)`（vk1[1]+=change, vk1[last]-=change）再 qsort 累加。
   - `n_master = num_bands_0 (+ num_bands_1)`，合并进 `f_master`。
9. 校验 `n_master>0` 且 `bs_xover_band < n_master`。

### 4.13 `sbr_turnoff`（纯上采样模式）

```c
sbr->start = 0; sbr->usac = 0; sbr->ready_for_dequant = 0;
sbr->kx[1] = 32;      // 规范笔误：kx' 初始化为 32
sbr->m[1]  = 0;
sbr->data[0].e_a[1] = sbr->data[1].e_a[1] = -1;
memset(&sbr->spectrum_params, -1, sizeof(...));
```

---

## 5. 频带表生成

### 5.1 `sbr_make_f_derived`

```c
n[1] = n_master - bs_xover_band;                 // high 分辨率频带数
n[0] = (n[1] + 1) >> 1;                          // low 分辨率频带数（向上取半）
memcpy(f_tablehigh, &f_master[bs_xover_band], (n[1]+1));  // 高分辨率边界表
m[1]  = f_tablehigh[n[1]] - f_tablehigh[0];      // SBR 子带数
kx[1] = f_tablehigh[0];                          // SBR 起始子带
// 校验 kx[1]+m[1] <= 64；kx[1] <= 32
f_tablelow[0] = f_tablehigh[0];
temp = n[1] & 1;
for (k = 1; k <= n[0]; k++)
    f_tablelow[k] = f_tablehigh[2*k - temp];     // 低分辨率 = 高分辨率隔点采样（对齐奇偶）
// 噪声带数：
n_q = FFMAX(1, lrintf(bs_noise_bands * log2f(k[2] / (float)kx[1])));  // 0<=bs_noise_bands<=3
if (n_q > 5) { n_q = 1; 返回错误; }
// 噪声边界表：按比例取 f_tablelow 的子集
f_tablenoise[0] = f_tablelow[0];
temp = 0;
for (k = 1; k <= n_q; k++) {
    temp += (n[0] - temp) / (n_q + 1 - k);       // 增量式（保证 f_tablenoise[k] 单调且均匀）
    f_tablenoise[k] = f_tablelow[temp];
}
sbr_hf_calc_npatches(...);                       // §5.2（错误→整体失败）
sbr_make_f_tablelim(...);                        // §5.3
data[0].f_indexnoise = data[1].f_indexnoise = 0;
```

### 5.2 `sbr_hf_calc_npatches`（patch 构造）

```c
msb = k[0];                                      // master start band
usb = kx[1];                                     // 当前"未覆盖"起始子带
goal_sb = ((1000<<11) + (sample_rate>>1)) / sample_rate;   // ≈ 1kHz 对应的 QMF 子带号（fs 相关）
num_patches = 0;
if (goal_sb < kx[1] + m[1])  { for (k=0; f_master[k] < goal_sb; k++); }
else                          k = n_master;
do {
    // 找 i=k 往下扫描满足 sb > (k[0]-1+msb-odd) 的最大边界
    for (i = k; i == k || sb > (k[0] - 1 + msb - odd); i--) {
        sb  = f_master[i];
        odd = (sb + k[0]) & 1;                   // 奇偶对齐（保证 subband 偶对称）
    }
    if (num_patches > 5) 错误;                    // 规范限 5；实际容 6
    patch_num_subbands [num_patches] = FFMAX(sb - usb, 0);
    patch_start_subband[num_patches] = k[0] - odd - patch_num_subbands[num_patches];
    if (patch_num_subbands[num_patches] > 0) {
        usb = sb;  msb = sb;  num_patches++;
    } else msb = kx[1];
    if (f_master[k] - sb < 3) k = n_master;      // 与目标差 <3 则直接跳到 master 末尾
} while (sb != kx[1] + m[1]);
if (num_patches > 1 && patch_num_subbands[num_patches-1] < 3)
    num_patches--;                                // 末 patch <3 子带则去掉
```
语义：把 `[kx[1], kx[1]+m[1]]` 高频区用 `f_master` 的边界切成若干 patch，每个 patch 的源低带位置 = `patch_start_subband`，宽度 = `patch_num_subbands`。HF 生成时 `X_low[patch_start_subband[j]+x]` 复制滤波到 `X_high[kx[1]+Σwidth]`。`odd` 保证源/目标子带奇偶一致（QMF 混叠对齐）。

### 5.3 `sbr_make_f_tablelim`（限幅频带表）

```c
if (bs_limiter_bands > 0) {
    lim_bands_per_octave_warped = bands_warped[bs_limiter_bands-1];  // §2.8
    patch_borders[0] = kx[1];
    for (k=1; k<=num_patches; k++) patch_borders[k] = patch_borders[k-1] + patch_num_subbands[k-1];
    memcpy(f_tablelim, f_tablelow, (n[0]+1));     // 先放入 low 表
    if (num_patches > 1)
        memcpy(f_tablelim + n[0]+1, patch_borders+1, (num_patches-1));  // 再放入 patch 边界
    qsort(f_tablelim, num_patches + n[0], int16); // 升序合并排序
    n_lim = n[0] + num_patches - 1;
    in = f_tablelim+1; out = f_tablelim;
    while (out < f_tablelim + n_lim) {
        if (*in >= *out * lim_bands_per_octave_warped) *++out = *in++;   // 拉开足够宽→保留
        else if (*in == *out || !in_table(patch_borders, num_patches, *in)) { in++; n_lim--; }  // 非 patch 边界→删
        else if (!in_table(patch_borders, num_patches, *out)) { *out = *in++; n_lim--; }
        else *++out = *in++;                       // 两者都是 patch 边界→都保留
    }
} else {                                          // bs_limiter_bands==0：只 2 个边界
    f_tablelim[0] = f_tablelow[0];
    f_tablelim[1] = f_tablelow[n[0]];
    n_lim = 1;
}
```
语义：限幅器按"每倍频程至少 N 个频带"聚合并去冗余，`n_lim` 为最终限幅带数。

---

## 6. QMF 分析/合成（重点）

### 6.1 MDCT 初始化与缩放（`ff_aac_sbr_ctx_alloc_init`）

```c
// 分析 MDCT：inv=1（逆向方向），len=64，scale = -2.0*32768
av_tx_init(&sbr->mdct_ana, &sbr->mdct_ana_fn, AV_TX_FLOAT_MDCT, 1, 64, &(-2.0f*32768.0f), 0);
// 合成 MDCT：inv=1，len=64，scale = 1.0/(64*32768)
av_tx_init(&sbr->mdct,     &sbr->mdct_fn,     AV_TX_FLOAT_MDCT, 1, 64, &(1.0f/(64*32768.0f)), 0);
```
av_tx MDCT 约定：`len`=帧长，窗口=2×len。**逆变换（inv=1）不带 FULL 标志时为"半长"**：输入 64 个系数 → 输出 64 个样本（配合重叠相加）。Zig 自实现 64 点 MDCT 时须满足该输入/输出尺寸与缩放约定：
- 分析：输入 64（来自 pre_shuffle），输出 64，缩放 ×(-2·32768)。
- 合成：输入 64，输出 64，缩放 ×(1/(64·32768))。

### 6.2 `sbr_qmf_analysis`（时域 → 32 子带复数）

```c
nb = numTimeSlots * 64;                       // 1024（16 slot）或 960（15 slot）
memcpy(x, x+nb, (320-32));                    // x[0..288) ← x[nb..nb+288)：右移 288 样本历史（x 缓冲 ≥1312）
memcpy(x+288, in, nb);                        // x[288..288+nb) ← 当前帧时域样本（L 或 R）
for (i = 0; i < numTimeSlots*2; i++) {        // 32（或30）次，每次产出 32 个复数子带样本
    dsp->vector_fmul_reverse(z, sbr_qmf_window_ds, x, 320);
        // z[k] = sbr_qmf_window_ds[k] * x[320-1-k]  （k=0..319）——倒序加窗
    sbrdsp->sum64x5(z);                       // z[k] = Σ_{s=0..4} z[k+64*s]（k=0..63）多相求和
    sbrdsp->qmf_pre_shuffle(z);               // 64 实值 → z[64..128) 的"解析信号"（Hilbert 化，详见 §7.4）
    mdct_fn(mdct_ana, z, z + 64, sizeof(float));
        // 逆向 MDCT：输入 z[64..128)（64），输出 z[0..64)（64），缩放 ×(-2*32768)
    sbrdsp->qmf_post_shuffle(W[buf_idx][i], z); // 64 个 MDCT 系数 → 32 个复数子带样本（详见 §7.5）
    x += 32;                                  // 每步消费 32 个时域样本
}
```
产物：`W[buf_idx][i][k][0/1]`，`i∈0..31`（时间槽），`k∈0..31`（子带），复数（实/虚）。

> 数学本质：这是 2× 过采样 32 带复分析滤波器组。`sum64x5` 是 320 抽头原型滤波器按 64 周期折叠，pre/post shuffle 完成复调制（实-解析变换）。

### 6.3 `sbr_qmf_synthesis`（子带复数 → 时域，可下采样）

```c
sbr_qmf_window = div ? sbr_qmf_window_ds : sbr_qmf_window_us;  // div=1 下采样，div=0 全速率
step = 128 >> div;
for (i = 0; i < numTimeSlots*2; i++) {
    if (*v_off < step) {                      // 环形缓冲回绕
        saved_samples = (1280-128) >> div;    // 1152（div=0）/ 576（div=1）
        memcpy(&v0[SBR_SYNTHESIS_BUF_SIZE-saved_samples], v0, saved_samples);
        *v_off = SBR_SYNTHESIS_BUF_SIZE - saved_samples - step;
    } else *v_off -= step;
    v = v0 + *v_off;                          // 本步输出位置
    if (div) {                                 // 下采样路径
        for (n = 0; n < 32; n++) {
            X[0][i][   n] = -X[0][i][n];       // 实部取反
            X[0][i][32+n] =  X[1][i][31-n];    // 虚部逆序拼到高半
        }
        mdct_fn(mdct, mdct_buf[0], X[0][i], sizeof(float));   // 1 个 64→64 逆向 MDCT
        sbrdsp->qmf_deint_neg(v, mdct_buf[0]);                 // 64 输出（§7.7）
    } else {                                   // 全速率路径
        sbrdsp->neg_odd_64(X[1][i]);           // 虚部奇序取负（§7.3）
        mdct_fn(mdct, mdct_buf[0], X[0][i], ...);  // 实部 64→64
        mdct_fn(mdct, mdct_buf[1], X[1][i], ...);  // 虚部 64→64
        sbrdsp->qmf_deint_bfly(v, mdct_buf[1], mdct_buf[0]);   // 128 输出（§7.2）
    }
    // 多相综合加窗：out[i] = Σ_j v[off_j + i] * window[off_j + i]，j 取 10 段
    vector_fmul    (out, v,                 window,              64>>div);
    vector_fmul_add(out, v+(192>>div), window+( 64>>div), out,  64>>div);
    vector_fmul_add(out, v+(256>>div), window+(128>>div), out,  64>>div);
    vector_fmul_add(out, v+(448>>div), window+(192>>div), out,  64>>div);
    vector_fmul_add(out, v+(512>>div), window+(256>>div), out,  64>>div);
    vector_fmul_add(out, v+(704>>div), window+(320>>div), out,  64>>div);
    vector_fmul_add(out, v+(768>>div), window+(384>>div), out,  64>>div);
    vector_fmul_add(out, v+(960>>div), window+(448>>div), out,  64>>div);
    vector_fmul_add(out, v+(1024>>div),window+(512>>div), out,  64>>div);
    vector_fmul_add(out, v+(1216>>div),window+(576>>div), out,  64>>div);
    out += 64 >> div;
}
```
- `v` 缓冲大小 2304 = SBR_SYNTHESIS_BUF_SIZE；`v_off` 初始 = `2304 - 1152 = 1152`（ctx_alloc 时设置）。
- 全速率：每步产 64 输出样本 ×32 步 = 2048（= 2×1024，SBR 上采样 2×）。下采样：每步 32 ×32 = 1024（原始速率）。
- `vector_fmul(a,b,c,n)`：`a[i]=b[i]*c[i]`；`vector_fmul_add(a,b,c,d,n)`：`a[i]=b[i]*c[i]+d[i]`。
- 窗口段偏移（div=0）：0,192,256,448,512,704,768,960,1024,1216；window_us 共 640=10×64。

### 6.4 `sbr_qmf_analysis` 与 `sbr_qmf_synthesis` 中的 DSP 调用顺序总结

| 阶段 | 顺序 |
|---|---|
| 分析 | `vector_fmul_reverse`（加窗）→ `sum64x5` → `qmf_pre_shuffle` → MDCT(逆) → `qmf_post_shuffle` |
| 合成(div=1) | 实部取反+虚部倒序拼合 → MDCT(逆) → `qmf_deint_neg` → 10×`vector_fmul_add` |
| 合成(div=0) | `neg_odd_64`(虚部) → 2×MDCT(逆) → `qmf_deint_bfly` → 10×`vector_fmul_add` |

---

## 7. sbrdsp 全部函数（`sbrdsp.c` + `sbrdsp_template.c`，浮点路径）

### 7.1 `sbr_sum64x5`（`template`）
```c
for (k = 0; k < 64; k++)
    z[k] = z[k] + z[k+64] + z[k+128] + z[k+192] + z[k+256];   // 5 段折叠
```

### 7.2 `sbr_qmf_deint_bfly`（`template`，合成全速率）
```c
for (i = 0; i < 64; i++) {
    v[i]      = src0[i] - src1[63-i];   // src0=实部 MDCT 输出，src1=虚部 MDCT 输出
    v[127-i]  = src0[i] + src1[63-i];   // 128 样本蝴蝶组合（复→实重建）
}
```

### 7.3 `sbr_neg_odd_64`（`sbrdsp.c`）
```c
for (i = 1; i < 64; i += 4) {
    x[i]   *= -1;    // 对 i=1,5,9,...取反
    x[i+2] *= -1;    // 对 i=3,7,11,...取反
}
```
即：奇下标全部取负（i 为奇数时 i 与 i+2 都是奇数）。C 用 `^0x80000000` 实现（等价 ×-1，但位操作对 ±0 也取反；Zig 用 `@bitCast` 翻转符号位可严格对齐）。

### 7.4 `sbr_qmf_pre_shuffle`（`sbrdsp.c`，分析：64→128 解析预混序）
```c
z[64] =  z[0];
z[65] =  z[1];
for (k = 1; k < 31; k += 2) {
    z[64+2k+0] = -z[64-k];
    z[64+2k+1] =  z[k+1];
    z[64+2k+2] = -z[63-k];
    z[64+2k+3] =  z[k+2];
}
z[64+62] = -z[33];   // 即 64+2*31+0 = 126
z[64+63] =  z[32];   // 64+2*31+1 = 127
```
输入 z[0..64)（sum64x5 输出），输出 z[64..128)（MDCT 输入）。`-x` 即符号位取反。

### 7.5 `sbr_qmf_post_shuffle`（`sbrdsp.c`，分析：64→32 复数）
```c
for (k = 0; k < 32; k += 2) {
    W[2k+0] = ( -z[63-k],  z[k] );
    W[2k+1] = ( -z[62-k],  z[k+1] );
}
```
把 MDCT 输出的 64 实值重组为 32 个 `{虚部, 实部}` 对（W 布局为 `[32][2]`，第二维 `[0]=虚？实？`）。注：C 中 `Wi[2k+0].i = zi[63-k].i ^ sign` 是"先负后取"——与数学定义一致即可，重点是**索引映射必须精确**。

### 7.6 `sbr_qmf_deint_neg`（`sbrdsp.c`，合成下采样）
```c
for (i = 0; i < 32; i++) {
    v[i]     =  src[63 - 2*i];        // 偶序
    v[63-i]  = -src[63 - 2*i - 1];    // 奇序取反
}
```

### 7.7 `sbr_sum_square`（`sbrdsp.c`，能量估计）
```c
for (i = 0; i < n; i += 2) {
    sum0 += x[i][0]*x[i][0] + x[i+1][0]*x[i+1][0];   // 实部平方和
    sum1 += x[i][1]*x[i][1] + x[i+1][1]*x[i+1][1];   // 虚部平方和
}
return sum0 + sum1;                                   // 复数模方和
```
输入 `float (*x)[2]`，n 通常为 `iub-ilb`（偶数）。Zig 注意：`n` 必须为偶数（调用处保证）。

### 7.8 `sbr_autocorrelate`（`sbrdsp.c`，逆滤波系数估计）
```c
// 输入 x[40][2]（一个低带子带的时间序列，复数），输出 phi[3][2][2]
real_sum2 = x[0][0]*x[2][0] + x[0][1]*x[2][1];       // lag2 实部（含 x0）
imag_sum2 = x[0][0]*x[2][1] - x[0][1]*x[2][0];       // lag2 虚部（含 x0）
for (i = 1; i < 38; i++) {
    real_sum0 += x[i][0]*x[i][0] + x[i][1]*x[i][1];          // lag0 能量（x1..x37）
    real_sum1 += x[i][0]*x[i+1][0] + x[i][1]*x[i+1][1];      // lag1 实部
    imag_sum1 += x[i][0]*x[i+1][1] - x[i][1]*x[i+1][0];      // lag1 虚部
    real_sum2 += x[i][0]*x[i+2][0] + x[i][1]*x[i+2][1];      // lag2 实部
    imag_sum2 += x[i][0]*x[i+2][1] - x[i][1]*x[i+2][0];      // lag2 虚部
}
phi[0][1][0] = real_sum2;
phi[0][1][1] = imag_sum2;
phi[2][1][0] = real_sum0 + x[0][0]*x[0][0] + x[0][1]*x[0][1];   // lag0，覆盖 0..37
phi[1][0][0] = real_sum0 + x[38][0]*x[38][0] + x[38][1]*x[38][1]; // lag0，覆盖 1..38
phi[1][1][0] = real_sum1 + x[0][0]*x[1][0] + x[0][1]*x[1][1];    // lag1，覆盖 0..37
phi[1][1][1] = imag_sum1 + x[0][0]*x[1][1] - x[0][1]*x[1][0];
phi[0][0][0] = real_sum1 + x[38][0]*x[39][0] + x[38][1]*x[39][1]; // lag1，覆盖 1..38
phi[0][0][1] = imag_sum1 + x[38][0]*x[39][1] - x[38][1]*x[39][0];
```
布局说明：`phi[lag][b][c]` 中 `lag=2-lag_index`（即 phi[2][..]=lag0, phi[1][..]=lag1, phi[0][..]=lag2）；`[..][1]` 为含 x[0] 的版本，`[..][0]` 为含 x[38]/x[39] 的版本。`sbr_hf_inverse_filter` 用 `phi[2][1][0]`、`phi[1][0][0]`、`phi[1][1]`、`phi[0][0]`、`phi[0][1]`（详见用户已研读的 aacsbr.c §3）。

### 7.9 `sbr_hf_gen`（`sbrdsp.c`，核心：高频子带生成）
```c
alpha[0] = alpha1[0] * bw * bw;    // 二阶项
alpha[1] = alpha1[1] * bw * bw;
alpha[2] = alpha0[0] * bw;         // 一阶项
alpha[3] = alpha0[1] * bw;
for (i = start; i < end; i++) {    // start/end = 2*t_env[0] / 2*t_env[num_env]（X 数组下标）
    X_high[i][0] = X_low[i-2][0]*alpha[0] - X_low[i-2][1]*alpha[1]
                 + X_low[i-1][0]*alpha[2] - X_low[i-1][1]*alpha[3]
                 + X_low[i][0];
    X_high[i][1] = X_low[i-2][1]*alpha[0] + X_low[i-2][0]*alpha[1]
                 + X_low[i-1][1]*alpha[2] + X_low[i-1][0]*alpha[3]
                 + X_low[i][1];
}
```
即复 2 阶 FIR：`X_high[i] = X_low[i] + (alpha0*bw)·X_low[i-1] + (alpha1*bw²)·X_low[i-2]`（复数乘加）。

### 7.10 `sbr_hf_g_filt`（`sbrdsp.c`，增益滤波）
```c
for (m = 0; m < m_max; m++) {
    Y[m][0] = X_high[m][ixh][0] * g_filt[m];   // 时间切片 ixh 的增益应用
    Y[m][1] = X_high[m][ixh][1] * g_filt[m];
}
```
`ixh = i + ENVELOPE_ADJUSTMENT_OFFSET`（i 为当前 slot 的 2×t 索引）。

### 7.11 `sbr_hf_apply_noise` 与 4 个变体（`sbrdsp.c` + `template`）
```c
// 通用实现：
for (m = 0; m < m_max; m++) {
    y0 = Y[m][0];  y1 = Y[m][1];
    noise = (noise + 1) & 0x1ff;                    // 每带推进噪声表游标
    if (s_m[m]) {                                    // 该带存在正弦 → 注入正弦分量
        y0 += s_m[m] * phi_sign0;
        y1 += s_m[m] * phi_sign1;
    } else {                                         // 否则注入噪声
        y0 += q_filt[m] * ff_sbr_noise_table[noise][0];
        y1 += q_filt[m] * ff_sbr_noise_table[noise][1];
    }
    Y[m][0] = y0;  Y[m][1] = y1;
    phi_sign1 = -phi_sign1;                          // 虚部符号逐带翻转（仅变体 1/3 相关）
}
// 4 个变体由调用方按 indexsine 选择：
//   [0] phi=(+1,  0)
//   [1] phi=( 0,  +s)，s = 1 - 2*(kx&1)
//   [2] phi=(-1,  0)
//   [3] phi=( 0,  -s)，s = 1 - 2*(kx&1)
```
正弦相位由 `indexsine = (indexsine+1)&3` 每 slot 递增，`kx` 奇偶决定虚部符号基线。

---

## 8. 信号处理函数（`aacsbr_template.c`）

### 8.1 `sbr_lf_gen`（低带提取）
```c
t_HFGen = 8;  i_f = numTimeSlots*2;      // 32 (或30)
memset(X_low, 0, 32 * sizeof(X_low[0])); // 只清 k 维的前 32 个"行指针"？→ 实际清 X_low[0..31]
for (k = 0; k < kx[1]; k++)              // 当前帧：子带 0..kx[1]-1
    for (i = t_HFGen; i < i_f + t_HFGen; i++)   // 时间 8..39（X_low 40 宽）
        X_low[k][i][0/1] = W[buf_idx][i - t_HFGen][k][0/1];   // ← W[buf][i-8][k]
buf_idx ^= 1;                            // 切到上帧缓冲
for (k = 0; k < kx[0]; k++)              // 上帧：子带 0..kx[0]-1（上帧 kx'）
    for (i = 0; i < t_HFGen; i++)        // 时间 0..7
        X_low[k][i][0/1] = W[buf_idx][i + i_f - t_HFGen][k][0/1]; // ← W[prev][i+24][k]
```
产出：`X_low[k][t]`，k∈0..31，t∈0..39；t=0..7 来自上帧（时间 `i+i_f-8` = 24+i），t=8..39 来自本帧（时间 `i-8` = 0..31）。即 X_low 时间轴 = 上帧后 8 slot + 本帧 32 slot。

### 8.2 `sbr_hf_gen`（高频生成调度）
```c
g = 0;  k = kx[1];
for (j = 0; j < num_patches; j++)
    for (x = 0; x < patch_num_subbands[j]; x++, k++) {
        p = patch_start_subband[j] + x;          // 源低带
        while (g <= n_q && k >= f_tablenoise[g]) g++;   // 找 k 所在噪声带索引
        g--;
        if (g < 0) 错误;
        dsp.hf_gen(X_high[k] + 2,               // 目标高带，+ENVELOPE_ADJUSTMENT_OFFSET
                   X_low[p]  + 2,               // 源低带（时间轴偏移 2）
                   alpha0[p], alpha1[p],        // 该源子带的逆滤波系数
                   bw_array[g],                 // 该噪声带的 chirp 因子
                   2 * t_env[0], 2 * t_env[bs_num_env]);   // 帧时间范围
    }
if (k < m[1] + kx[1])
    memset(X_high + k, 0, (m[1] + kx[1] - k) * sizeof(*X_high));  // 未覆盖的高带清零
```
注意：`X_high[k]`/`X_low[p]` 是 `[40][2]` 的数组，`+2` 是数组首地址偏移到时间索引 2（ENVELOPE_ADJUSTMENT_OFFSET）。`hf_gen` 输出时间范围 `[2*t_env[0], 2*t_env[num_env]]`。

### 8.3 `sbr_x_gen`（重建子带组装）
```c
i_f    = numTimeSlots*2;                          // 32
i_Temp = FFMAX(2 * data[ch].t_env_num_env_old - i_f, 0);   // 上帧末边界对应时间
memset(X, 0, 2 * sizeof(*X));                     // 清 X[0], X[1] 两片 [38][64]
for (k = 0; k < kx[0]; k++)                       // 低带（用上帧 kx'）
    for (i = 0; i < i_Temp; i++)
        X[0][i][k] = X_low[k][i + 2][0];  X[1][i][k] = X_low[k][i + 2][1];
for (; k < kx[0] + m[0]; k++)                     // 上帧高频区用上帧 Y0
    for (i = 0; i < i_Temp; i++)
        X[0][i][k] = Y0[i + i_f][k][0];  X[1][i][k] = Y0[i + i_f][k][1];
for (k = 0; k < kx[1]; k++)                       // 本帧低带
    for (i = i_Temp; i < 38; i++)
        X[0][i][k] = X_low[k][i + 2][0];  X[1][i][k] = X_low[k][i + 2][1];
for (; k < kx[1] + m[1]; k++)                     // 本帧高频区用本帧 Y1（只到 i_f）
    for (i = i_Temp; i < i_f; i++)
        X[0][i][k] = Y1[i][k][0];  X[1][i][k] = Y1[i][k][1];
```
产出 `X[real/imag][38][64]`：时间 0..i_Temp-1 来自上帧（低带 X_low / 高频 Y0），i_Temp..38 来自本帧（X_low / Y1）。

### 8.4 `sbr_mapping`（包络/噪声/正弦映射到子带）
```c
memset(s_indexmapped[1], 0, 7 * sizeof(s_indexmapped[1]));   // 行 1..7 清零
for (e = 0; e < bs_num_env; e++) {
    ilim  = n[bs_freq_res[e+1]];                 // 本包络分辨率下的频带数
    table = bs_freq_res[e+1] ? f_tablehigh : f_tablelow;
    if (kx[1] != table[0]) 错误（表未重生成）→ sbr_turnoff;
    for (i = 0; i < ilim; i++)                   // 包络因子按频带摊到 QMF 子带
        for (m = table[i]; m < table[i+1]; m++)
            e_origmapped[e][m - kx[1]] = env_facs[e+1][i];
    k = (bs_num_noise > 1) && (t_env[e] >= t_q[1]);   // 选噪声层：env 在中间噪声边界后则用第 2 层
    for (i = 0; i < n_q; i++)                    // 噪声因子摊到子带
        for (m = f_tablenoise[i]; m < f_tablenoise[i+1]; m++)
            q_mapped[e][m - kx[1]] = noise_facs[k+1][i];
    for (i = 0; i < n[1]; i++)                   // 正弦标记：把 bs_add_harmonic 摊到带中点
        if (bs_add_harmonic_flag) {
            m_midpoint = (f_tablehigh[i] + f_tablehigh[i+1]) >> 1;
            s_indexmapped[e+1][m_midpoint - kx[1]] =
                bs_add_harmonic[i] *
                (e >= e_a[1] || s_indexmapped[0][m_midpoint - kx[1]] == 1);
            // 条件：本包络不是 l_A 或上帧该子带已有正弦
        }
    for (i = 0; i < ilim; i++) {                 // 频带内任一子带有正弦→整带置 s_mapped
        additional_sinusoid_present = 0;
        for (m = table[i]; m < table[i+1]; m++)
            if (s_indexmapped[e+1][m - kx[1]]) { additional_sinusoid_present = 1; break; }
        memset(&s_mapped[e][table[i] - kx[1]], additional_sinusoid_present,
               (table[i+1] - table[i]) * sizeof(...));
    }
}
memcpy(s_indexmapped[0], s_indexmapped[bs_num_env], sizeof(...));  // 供下帧
```

### 8.5 `sbr_env_estimate`（当前包络能量估计）
```c
kx1 = kx[1];
if (bs_interpol_freq) {                          // 插值模式：每子带独立、时间加权
    for (e = 0; e < bs_num_env; e++) {
        recip_env_size = 0.5f / (t_env[e+1] - t_env[e]);
        ilb = t_env[e]   * 2 + 2;                // +ENVELOPE_ADJUSTMENT_OFFSET
        iub = t_env[e+1] * 2 + 2;
        if (ilb >= 40) return;                   // 超出 X_high 时间范围（40）直接返回
        for (m = 0; m < m[1]; m++)
            e_curr[e][m] = sum_square(X_high[m+kx1] + ilb, iub-ilb) * recip_env_size;
            // 能量 = (Σ|X|²) × 0.5/(窗口时长)
    }
} else {                                         // 频带模式：按频带分组平均
    for (e = 0; e < bs_num_env; e++) {
        env_size = 2 * (t_env[e+1] - t_env[e]);
        ilb = t_env[e]*2 + 2;  iub = t_env[e+1]*2 + 2;
        table = bs_freq_res[e+1] ? f_tablehigh : f_tablelow;
        if (ilb >= 40) return;
        for (p = 0; p < n[bs_freq_res[e+1]]; p++) {
            sum = 0;  den = env_size * (table[p+1] - table[p]);
            for (k = table[p]; k < table[p+1]; k++)
                sum += sum_square(X_high[k] + ilb, iub - ilb);
            sum /= den;
            for (k = table[p]; k < table[p+1]; k++)
                e_curr[e][k - kx1] = sum;        // 同频带内所有子带同一值
        }
    }
}
```

### 8.6 `ff_aac_sbr_apply`（每帧调度，流程骨架）
```c
downsampled = (ext_sample_rate < sample_rate);   // 是否下采样合成
nch = (id_aac == TYPE_CPE) ? 2 : 1;
numTimeSlots = fl960 ? 15 : 16;
// 元素类型不一致 / 未读量化数据 → sbr_turnoff
if (!kx_and_m_pushed) { kx[0]=kx[1]; m[0]=m[1]; } else kx_and_m_pushed = 0;
if (start) { sbr_dequant(...); ready_for_dequant = 0; }
for (ch = 0; ch < nch; ch++) {
    sbr_qmf_analysis(..., ch ? R : L, data[ch].analysis_filterbank_samples,
                     scratch, data[ch].W, data[ch].Ypos, numTimeSlots);
    sbr_lf_gen(sbr, X_low, W, data[ch].Ypos, numTimeSlots);
    data[ch].Ypos ^= 1;                          // 双缓冲翻转
    if (start) {
        sbr_hf_inverse_filter(&dsp, alpha0, alpha1, X_low, k[0]);  // 只算 k0 个子带
        sbr_chirp(sbr, &data[ch]);
        sbr_hf_gen(ac, sbr, X_high, X_low, alpha0, alpha1,
                   bw_array, t_env, bs_num_env);
        if (!sbr_mapping(ac, sbr, &data[ch], e_a)) {
            sbr_env_estimate(e_curr, X_high, sbr, &data[ch]);
            sbr_gain_calc(sbr, &data[ch], e_a);
            sbr_hf_assemble(data[ch].Y[data[ch].Ypos], X_high, sbr, &data[ch], e_a);
        }
    }
    sbr_x_gen(sbr, X[ch], Y[1-Ypos], Y[Ypos], X_low, ch, numTimeSlots);
}
// PS 路径（若启用）在 X[0]/X[1] 上做 ff_ps_apply，nch=2
sbr_qmf_synthesis(..., L, X[0], ...);            // 通道 0
if (nch == 2) sbr_qmf_synthesis(..., R, X[1], ...);
```
要点：`alpha0/alpha1` 只在 `start`（有 SBR 数据）时更新；`X_low` 每帧更新；`Y[Ypos]` 写本帧，`Y[1-Ypos]` 是上帧结果（x_gen 用）。

---

## 9. Zig 移植关键注意点

1. **IEEE 位操作**：`exp2fi` 用 `@bitCast(u32→f32)`；`neg_odd_64`、pre/post shuffle 的取反可对 `f32` 直接 `*=-1`，但要留意 `-0.0` 的差异（FFmpeg 用异或符号位，Zig 建议用 `@bitCast` 翻转符号位以 bit-exact）。
2. **Huffman 表**：直接把 `sbr_huffman_tab` 的 `{symbol, length}` 拷出，构建 9bit 查表或逐位树。解码值 = symbol + `sbr_vlc_offsets[table]`。
3. **MDCT**：自实现 64 点"逆向 MDCT"（输入 64→输出 64，缩放分别为 `-2·32768` 与 `1/(64·32768)`），须与 av_tx 的窗口/中心对齐定义一致（av_tx MDCT 输入为 2N、输出 N；逆向半长 N→N）。这是与 FFmpeg 数值逐位对齐风险最高的部分。
4. **双缓冲/环形状态**：`Ypos`、`kx[0]/m[0]`、`env_facs_q[0]`、`noise_facs_q[0]`、`s_indexmapped[0]`、`bs_invf_mode[1]`、`e_a[0]`、`f_indexnoise/f_indexsine`、分析缓冲 `x[1312]`、合成缓冲 `v[2304]+offset` 均需精确保持。
5. **时间索引约定**：帧时间轴单位是"半个 slot"（2× 过采样），`t_env` 范围 0..16（或 15）；所有 X/Y 数组时间维 38/40 与 `ENVELOPE_ADJUSTMENT_OFFSET=2` 的偏移必须一致。
6. **错误处理路径**：各 `return -1`/`AVERROR_INVALIDDATA` 触发 `sbr_turnoff`（纯上采样），恢复后下一帧重新 reset。Zig 需保留这些降级路径。
7. **USAC**：本文档全部为非 USAC AAC 路径（`read_sbr_grid` 的 FIXFIX 上限 5、无 `inter_tes`、dtdf 非独立模式）。USAC 需额外分支（`indep_flag`、`bs_df_env[0]` 强制 0 等）。
8. **PS（参数立体声）**：`read_sbr_extension` 中 `EXTENSION_ID_PS` 可先以 `skip_bits` 占位，不影响单声道 SBR。
9. **缩放范围**：分析 `×(-2·32768)` 与合成 `/(64·32768)` 是 SBR 内部把信号放大到 ±32768 域处理的整体设计，移植时缩放必须逐位一致，否则增益会系统性偏差。

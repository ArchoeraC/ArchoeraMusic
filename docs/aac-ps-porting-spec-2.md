# AAC 参数立体声（PS）移植规格（续）——去相关、立体声处理、综合、DSP、表与 VLC

> 本文是 `aac-ps-porting-spec.md` 的续篇，覆盖 §5.2 剩余、§5.3、§5.4、全部 8 个 PSDSP 函数、表生成、VLC 构建。
> 所有代码均逐一对照本仓库 `reference/FFmpeg/libavcodec/` 下实际源码（float 路径，`USE_FIXED=0`）核实：
> - `aacps.c`（= `aacps_float.c` 展开）
> - `aacps_common.c`、`aacpsdata.c`、`aacps.h`
> - `aacpsdsp_template.c`、`aacpsdsp.h`
> - `aacps_tablegen.h`、`aacps_tablegen.c`、`aacps_tablegen_template.c`
> - `vlc.c`（`ff_vlc_init_from_lengths` / `build_table`）、`get_bits.h`（`get_vlc2`）

关键前置结论（已核实）：

- `CONFIG_HARDCODED_TABLES = 0`（本仓库 `config.h:675`），因此 `ps_tableinit()` **在运行时**执行（由 `ff_ps_init()` 调用一次），浮点表全部运行时生成；`aacps_tables.h` 硬编码版本由独立工具 `aacps_tablegen.c` 生成（仅 CONFIG_HARDCODED_TABLES=1 构建用）。Zig 移植应在初始化期复刻 `ps_tableinit()` 的四个生成块。
- `PS_BASELINE = 0`（`aacps.h:41`），所有 `!PS_BASELINE` 条件恒真，`enable_ipdopd &= !PS_BASELINE` 为恒等操作。
- float 路径下：`INTFLOAT = UINTFLOAT = INT64FLOAT = float`；`AAC_MUL*/AAC_MADD*/AAC_MSUB*` = 普通 IEEE 乘加（见原文档 §9）；`Q30/Q31` 恒等。
- `VLCElem` = `{ int16 sym; int16 len; }`（`vlc.h:32`），占 4 字节。

---

## 1. `ff_ps_apply` 完整流程（aacps.c 719-738）

```c
int ff_ps_apply(PSContext *ps, INTFLOAT L[2][38][64], INTFLOAT R[2][38][64], int top)
{
    INTFLOAT (*Lbuf)[32][2] = ps->Lbuf;      // 91 子子带 × 32 时隙 × 复数
    INTFLOAT (*Rbuf)[32][2] = ps->Rbuf;
    const int len = 32;
    int is34 = ps->common.is34bands;

    top += NR_BANDS[is34] - 64;               // NR_BANDS={71,91} → top += 7(20带)/27(34带)
    memset(ps->delay+top, 0, (NR_BANDS[is34] - top)*sizeof(ps->delay[0]));
    if (top < NR_ALLPASS_BANDS[is34])          // NR_ALLPASS_BANDS={30,50}
        memset(ps->ap_delay + top, 0, (NR_ALLPASS_BANDS[is34] - top)*sizeof(ps->ap_delay[0]));

    hybrid_analysis(&ps->dsp, Lbuf, ps->in_buf, L, is34, len);      // L → Lbuf
    decorrelation(ps, Rbuf, Lbuf, is34);                             // Lbuf → Rbuf
    stereo_processing(ps, Lbuf, Rbuf, is34);                         // 混音（原地改 Lbuf/Rbuf）
    hybrid_synthesis(&ps->dsp, L, Lbuf, is34, len);                  // Lbuf → L
    hybrid_synthesis(&ps->dsp, R, Rbuf, is34, len);                  // Rbuf → R
    return 0;
}
```

逐行语义：

1. `top` 是 SBR 使用的最高 QMF 子带 +1（调用处 `sbr->kx[1] + sbr->m[1]`）。`top += NR_BANDS - 64` 把它换算成**子子带坐标**。例如 34 带模式子子带总数 91，QMF 带 5..63 透传占据子子带 32..90，所以 QMF 带 top 对应子子带 top+27。
2. `memset(ps->delay+top, ...)`：把 `delay[top..NR_BANDS-1]`（该行每行 `[46][2]`，sizeof = 46*2*4 = 368B）清零。SBR 顶带以上的子子带无能量，其延迟线必须为 0。
3. `memset(ps->ap_delay+top, ...)`：同理清 `ap_delay[top..NR_ALLPASS_BANDS-1]`（每行 `[3][37][2]`，sizeof = 888B）。仅当 `top < NR_ALLPASS_BANDS` 才有意义。
4. 五段流水线：混合分析 → 去相关 → 立体声处理 → 两次综合回 QMF 域（L 与 R 各一次）。
5. **注意原地复用**：`L[2][38][64]` 既是分析输入又是综合输出；`Lbuf` 先作分析输出，再被 `stereo_processing` 当作“干信号 s”，`Rbuf` 为去相关“湿信号 d”。`stereo_interpolate` 输出的 `l`=Lbuf、`r`=Rbuf 分别被综合到 L、R。

Zig 要点：`top` 三处 memset 的字节数分别为 `(NR_BANDS-top)*46*2*4` 与 `(NR_ALLPASS_BANDS-top)*3*37*2*4`；直接用 `std.mem.set` 按行清即可。

---

## 2. 混合分析辅助函数（§5.1 的精确细节，供 DSP 理解）

用户已读 §5.1，此处补充 DSP 语义所需的**滤波器索引/平面别名**细节。三个辅助函数：

### 2.1 `hybrid6_cx`（aacps.c 80-102）—— 20 带，QMF 带 0 拆 6

```c
static void hybrid6_cx(PSDSPContext *dsp, INTFLOAT (*in)[2], INTFLOAT (*out)[32][2],
                       const INTFLOAT (*filter)[8][2], int len)
{
    int N = 8;
    LOCAL_ALIGNED_16(INTFLOAT, temp, [8], [2]);
    for (i = 0; i < len; i++, in++) {
        dsp->hybrid_analysis(temp, in, filter, 1, N);   // 产出 8 个复数输出带 temp[0..7]
        out[0][i] = temp[6];                            // 输出合并：6 个子子带
        out[1][i] = temp[7];
        out[2][i] = temp[0];
        out[3][i] = temp[1];
        out[4][i] = temp[2] + temp[5];                  // 相邻带两两求和
        out[5][i] = temp[3] + temp[4];
    }
}
```

- `stride=1`：`hybrid_analysis` 把第 i 个输出写到 `temp[i]`。
- 8 个原型带映射到 6 个子子带：`6,7,0,1,(2+5),(3+4)`。

### 2.2 `hybrid4_8_12_cx`（aacps.c 104-113）—— 34 带，QMF 带 0..4 拆 12/8/4

```c
static void hybrid4_8_12_cx(PSDSPContext *dsp, INTFLOAT (*in)[2], INTFLOAT (*out)[32][2],
                            const INTFLOAT (*filter)[8][2], int N, int len)
{
    for (i = 0; i < len; i++, in++)
        dsp->hybrid_analysis(out[0] + i, in, filter, 32, N);
}
```

- `stride=32`，基址 `out[0]+i`：`hybrid_analysis` 写 `(out[0]+i)[j*32]`，平面索引 = `out[0][i + 32*j]`，即 `out[j][i]`。**C 依赖平面别名把第 j 个子子带、第 i 个时隙写到 `out[j][i]`。** Zig 中 `out` 为 `[32][2]` 的 `*[N]` 切片时直接写 `out[j][i]` 即可，无需别名技巧。
- 子带 0→N=12（`f34_0_12`，写 `out+0`）、1→N=8（`f34_1_8`，写 `out+12`）、2/3/4→N=4（`f34_2_4`，写 `out+20/24/28`）。
- 滤波器列 `[8][2]` 只有 0..6 被读（中心抽头 index 6，对称对 0..5），第 7 列是存储余量（运行时生成时为 0）。

### 2.3 `hybrid2_re`（aacps.c 53-77）—— 20 带，QMF 带 1/2 各拆 2（实滤波器）

```c
static void hybrid2_re(INTFLOAT (*in)[2], INTFLOAT (*out)[32][2],
                       const INTFLOAT filter[7], int len, int reverse)
{
    for (i = 0; i < len; i++, in++) {
        INTFLOAT re_in = filter[6] * in[6][0];     // 中心抽头
        INTFLOAT re_op = 0.0f;
        INTFLOAT im_in = filter[6] * in[6][1];
        INTFLOAT im_op = 0.0f;
        for (j = 0; j < 6; j += 2) {               // 抽头 1,3,5（偶抽头为 0）
            re_op += filter[j+1] * (in[j+1][0] + in[12-j-1][0]);
            im_op += filter[j+1] * (in[j+1][1] + in[12-j-1][1]);
        }
        out[ reverse][i][0] = re_in + re_op;       // 同相
        out[ reverse][i][1] = im_in + im_op;
        out[!reverse][i][0] = re_in - re_op;       // 反相
        out[!reverse][i][1] = im_in - im_op;
    }
}
```

- 用 `g1_Q2[7]`（见 §6），对称对：`(j+1, 12-j-1)` = (1,11),(3,9),(5,7)。
- 带 1 调用 `reverse=1`（子子带 6 为同相、7 为反相），带 2 调用 `reverse=0`（子子带 8 同相、9 反相）。

---

## 3. `decorrelation` 剩余部分（aacps.c 399-517）精确语义

### 3.1 延迟线维护（每带 k，每帧）

```c
memcpy(delay[k], delay[k]+nL, PS_MAX_DELAY*sizeof(delay[k][0]));       // nL=32, PS_MAX_DELAY=14
memcpy(delay[k]+PS_MAX_DELAY, s[k], numQMFSlots*sizeof(delay[k][0]));  // 32 时隙
for (m = 0; m < PS_AP_LINKS; m++)
    memcpy(ap_delay[k][m], ap_delay[k][m]+numQMFSlots, 5*sizeof(ap_delay[k][m][0]));
```

`delay[k]` 尺寸 `[46][2]`，移位后布局：

| 索引 | 0..13 | 14..45 |
|---|---|---|
| 内容 | 上帧尾部（移位自旧 32..45） | 本帧 `s[k][0..31]` |

`ap_delay[k][m]` 尺寸 `[37][2]`，移位后 `[0..4]` = 旧 `[32..36]`，`[5..36]` 在 decorrelate 中逐时隙写入。

### 3.2 三个区域（k 从 0 连续递增）

**区域 A——全通区** `k ∈ [0, NR_ALLPASS_BANDS)`（NR_ALLPASS_BANDS={30,50}）：

```c
int b = k_to_i[k];                                  // 子子带 → 参数带
float g_decay_slope = 1.f - 0.05f * (k - DECAY_CUTOFF[is34]);   // DECAY_CUTOFF={10,32}
g_decay_slope = av_clipf(g_decay_slope, 0.f, 1.f);  // 裁剪到 [0,1]
// 延迟线移位（见 3.1）
ps->dsp.decorrelate(out[k], delay[k] + PS_MAX_DELAY - 2, ap_delay[k],
                    phi_fract[is34][k],
                    Q_fract_allpass[is34][k],
                    transient_gain[b], g_decay_slope, nL - n0);   // len=32
```

- **`delay[k]+14-2 = delay[k]+12`**：全通输入读 `delay[12..43]`。由于 delay 绝对时间 = 索引-14，读到的时间区间为 [-2, 29]，即相对本帧 slot n 是 **`z^-2`**（比“零延迟”起点 14 再提前 2）。
- **`phi_fract[is34][k]`**：整体分数延迟复旋转（见 DSP 函数 §6.6），对应公式里的 `z^-2 * phi_fract[k]` 中 phi 项。
- **`Q_fract_allpass[is34][k]`**：`[3][2]`（3 链路 × [re,im]），各链路的分数延迟旋转。
- **`transient_gain[b]`**：该子子带所属参数带 b 的瞬态增益（32 时隙的向量）。
- 每次调用 `decorrelate` 内部还先对 `ap_delay[m][0..4]` 做移位？—— 不，移位在 aacps.c 完成（3.1），DSP 只读 `ap_delay[m][n+2-m]` 并写 `ap_delay[m][n+5]`。

**区域 B——短延迟区** `k ∈ [NR_ALLPASS_BANDS, SHORT_DELAY_BAND)`（SHORT_DELAY_BAND={42,62}）：

```c
int i = k_to_i[k];
// 延迟线移位（同 3.1）
ps->dsp.mul_pair_single(out[k], delay[k] + PS_MAX_DELAY - 14, transient_gain[i], nL - n0);
//                                     ^^^ delay[k]+0 → 读 delay[0..31]
```

- 读 `delay[0..31]` = 绝对时间 [-14, 13] → 输出 slot n = 输入 time **n-14**（净延迟 14）。

**区域 C——最高频带** `k ∈ [SHORT_DELAY_BAND, NR_BANDS)`：

```c
ps->dsp.mul_pair_single(out[k], delay[k] + PS_MAX_DELAY - 1, transient_gain[i], nL - n0);
//                                     ^^^ delay[k]+13 → 读 delay[13..44]
```

- 读 `delay[13..44]` = 绝对时间 [-1, 30] → 输出 slot n = 输入 time **n-1**（净延迟 1）。

### 3.3 瞬态检测（float 分支，aacps.c 451-462）

```c
const float transient_impact = 1.5f;
const float a_smooth         = 0.25f;
const float peak_decay_factor = 0.76592833836465f;

for (i = 0; i < NR_PAR_BANDS[is34]; i++) {          // {20,34}
    for (n = n0; n < nL; n++) {                     // n0=0, nL=32
        float decayed_peak = peak_decay_factor * peak_decay_nrg[i];
        peak_decay_nrg[i] = FFMAX(decayed_peak, power[i][n]);
        power_smooth[i] += a_smooth * (power[i][n] - power_smooth[i]);
        peak_decay_diff_smooth[i] += a_smooth * (peak_decay_nrg[i] - power[i][n] - peak_decay_diff_smooth[i]);
        float denom = transient_impact * peak_decay_diff_smooth[i];
        transient_gain[i][n] = (denom > power_smooth[i]) ? power_smooth[i] / denom : 1.0f;
    }
}
```

- `power[i][n]` 由 `add_squares` 累加：`power[i] += |s[k][n]|²` 对满足 `k_to_i[k]==i` 的全部 k（`add_squares` 见 §6.1）。
- 状态变量 `peak_decay_nrg[34]/power_smooth[34]/peak_decay_diff_smooth[34]` 为**跨帧持久**；带宽切换时清零（见 3.4）。
- `memset(power, 0, 34 * sizeof(*power))` 每帧执行：清 `power[34][32]` 全部。

### 3.4 带宽切换复位

```c
if (is34 != ps->common.is34bands_old) {
    memset(ps->peak_decay_nrg,         0, sizeof(ps->peak_decay_nrg));   // 34 项
    memset(ps->power_smooth,           0, sizeof(ps->power_smooth));
    memset(ps->peak_decay_diff_smooth, 0, sizeof(ps->peak_decay_diff_smooth));
    memset(ps->delay,                  0, sizeof(ps->delay));            // [91][46][2]
    memset(ps->ap_delay,               0, sizeof(ps->ap_delay));         // [50][3][37][2]
}
```

### 3.5 参考公式（aacps.c 466-472 注释）

```
                    PS_AP_LINKS - 1
                          -----
                           | |  Q_fract_allpass[k][m]*z^-link_delay[m] - a[m]*g_decay_slope[k]
H[k][z] = z^-2 * phi_fract[k] * | | ----------------------------------------------------------------
                           | |  1 - a[m]*g_decay_slope[k]*Q_fract_allpass[k][m]*z^-link_delay[m]
                          m = 0
d[k][z] (out) = transient_gain_mapped[k][z] * H[k][z] * s[k][z]
```

`z^-2` 来自 `delay[k]+12` 的读偏移；`phi_fract`/`Q_fract_allpass` 为复单位圆旋转（`e^{-jπ·frac·f_center}`）。

---

## 4. `stereo_processing`（aacps.c 557-717）完整语义

### 4.0 H_LUT 选择

```c
TABLE_CONST INTFLOAT (*H_LUT)[8][4] = (PS_BASELINE || ps2->icc_mode < 3) ? HA : HB;
```

- `icc_mode < 3`（0,1,2）→ 混合方式 A（`HA`）；`icc_mode >= 3`（3,4,5）→ 混合方式 B（`HB`）。
- `H_LUT[iid][icc][k]`：行 46（iid），列 8（icc），元素 4 = {h11, h12, h21, h22}。

### 4.1 上一帧末包络拷贝到槽 0（包络插值起点）

```c
if (ps2->num_env_old) {
    memcpy(H11[0][0], H11[0][ps2->num_env_old], sizeof(H11[0][0]));  // [34] 项 float
    memcpy(H11[1][0], H11[1][ps2->num_env_old], sizeof(H11[0][0]));
    ... // H12/H21/H22 的 [0] 层与 [1] 层各 8 次 memcpy
}
```

- `H11[re/im][env+1][band]`：`[0]` 槽存上一帧末包络（`num_env_old` 槽），保证本帧第一个包络插值从上一帧末连续。

### 4.2 参数带重映射与带宽切换

```c
if (is34) {
    remap34(&iid_mapped, ps2->iid_par, ps2->nr_iid_par, ps2->num_env, 1);
    remap34(&icc_mapped, ps2->icc_par, ps2->nr_icc_par, ps2->num_env, 1);
    if (ps2->enable_ipdopd) {
        remap34(&ipd_mapped, ps2->ipd_par, ps2->nr_ipdopd_par, ps2->num_env, 0);
        remap34(&opd_mapped, ps2->opd_par, ps2->nr_ipdopd_par, ps2->num_env, 0);
    }
    if (!ps2->is34bands_old) {          // 20→34
        map_val_20_to_34(H11[0][0]); ...(8 次：H11..H22 的 0/1 层)
        ipdopd_reset(ipd_hist, opd_hist);   // 34 项各置 0
    }
} else {
    remap20(...);                       // 对称
    if (ps2->is34bands_old) {           // 34→20
        map_val_34_to_20(H11[0][0]); ...(8 次)
        ipdopd_reset(ipd_hist, opd_hist);
    }
}
```

- `remap34/remap20` 的映射函数见 §9（`map_idx_*`）。若参数带数已等于目标带数，指针直接指向原数组（不拷贝）。
- 带宽切换时把 H 系数做**值映射**（`map_val_20_to_34` / `map_val_34_to_20`，§9）并清相位历史。

### 4.3 H 系数生成 + ipd/opd 相位旋转（外层 env 循环 e）

```c
for (e = 0; e < ps2->num_env; e++) {
    for (b = 0; b < NR_PAR_BANDS[is34]; b++) {          // {20,34}
        INTFLOAT h11, h12, h21, h22;
        int row = iid_mapped[e][b] + 7 + 23 * ps2->iid_quant;   // 粗:+7(→0..14) 细:+30(→15..45)
        h11 = H_LUT[row][icc_mapped[e][b]][0];           // icc_mapped ∈ [0,7]
        h12 = H_LUT[row][icc_mapped[e][b]][1];
        h21 = H_LUT[row][icc_mapped[e][b]][2];
        h22 = H_LUT[row][icc_mapped[e][b]][3];

        if (!PS_BASELINE && ps2->enable_ipdopd && b < NR_IPDOPD_BANDS[is34]) {
            INTFLOAT h11i, h12i, h21i, h22i, ipd_adj_re, ipd_adj_im;
            int opd_idx = opd_hist[b] * 8 + opd_mapped[e][b];   // 0..511
            int ipd_idx = ipd_hist[b] * 8 + ipd_mapped[e][b];
            INTFLOAT opd_re = pd_re_smooth[opd_idx];  INTFLOAT opd_im = pd_im_smooth[opd_idx];
            INTFLOAT ipd_re = pd_re_smooth[ipd_idx];  INTFLOAT ipd_im = pd_im_smooth[ipd_idx];
            opd_hist[b] = opd_idx & 0x3F;               // 保留最近 2 个相位（6 位）
            ipd_hist[b] = ipd_idx & 0x3F;

            ipd_adj_re = opd_re*ipd_re + opd_im*ipd_im;      // 复数乘：opd * ipd
            ipd_adj_im = opd_im*ipd_re - opd_re*ipd_im;
            h11i = h11 * opd_im;   h11 = h11 * opd_re;       // h11 *= opd（复数）
            h12i = h12 * ipd_adj_im; h12 = h12 * ipd_adj_re; // h12 *= (opd·ipd)
            h21i = h21 * opd_im;   h21 = h21 * opd_re;
            h22i = h22 * ipd_adj_im; h22 = h22 * ipd_adj_re;
            H11[1][e+1][b] = h11i; H12[1][e+1][b] = h12i;    // 虚部层
            H21[1][e+1][b] = h21i; H22[1][e+1][b] = h22i;
        }
        H11[0][e+1][b] = h11;  H12[0][e+1][b] = h12;         // 实部层（总是写）
        H21[0][e+1][b] = h21;  H22[0][e+1][b] = h22;
    }
    ...
}
```

**相位平滑索引细节**（重要）：

- `pd_re_smooth[idx]`/`pd_im_smooth[idx]` 索引 = `pd0*64 + pd1*8 + pd2`，其中 pd0/pd1/pd2 ∈ [0,7] 是最近三个量化相位（pd0 最旧、pd2 最新）。
- `opd_hist[b]` 以 6 位编码最近两个相位：`hist = (pd_old<<3)|pd_prev`，则 `opd_idx = hist*8 + pd_new = pd_old*64 + pd_prev*8 + pd_new`，恰好是平滑表索引。
- `opd_idx & 0x3F` 保留低 6 位 = `(pd_prev<<3)|pd_new`，成为下一帧的 `hist`。
- 首帧 `hist=0`（`ipdopd_reset`），即旧两相位按 0 计。

**注意**：`b >= NR_IPDOPD_BANDS` 时 `H*[1][e+1][b]` 不写（残留旧值）。但 4.4 的插值循环在 `enable_ipdopd` 时对所有 k 读 `H*[1][e][b]`，因此跨帧残留值会被使用——这是 FFmpeg 的既定行为，移植必须逐位复刻（保持 H 数组为持久状态，不做额外清零）。

### 4.4 包络间插值 + 应用（内层子子带循环 k）

```c
for (k = 0; k < NR_BANDS[is34]; k++) {
    LOCAL_ALIGNED_16(INTFLOAT, h, [2], [4]);
    LOCAL_ALIGNED_16(INTFLOAT, h_step, [2], [4]);
    int start = ps2->border_position[e];         // 本包络起（槽号，可为 -1）
    int stop  = ps2->border_position[e+1];       // 本包络止
    INTFLOAT width = 1.f / ((stop - start) ? (stop - start) : 1);
    b = k_to_i[k];

    h[0][0] = H11[0][e][b];  h[0][1] = H12[0][e][b];   // 起点 = 上包络末
    h[0][2] = H21[0][e][b];  h[0][3] = H22[0][e][b];
    if (!PS_BASELINE && ps2->enable_ipdopd) {
        if ((is34 && k <= 13 && k >= 9) || (!is34 && k <= 1)) {   // 特定子子带区段相位取负
            h[1][0] = -H11[1][e][b];  h[1][1] = -H12[1][e][b];
            h[1][2] = -H21[1][e][b];  h[1][3] = -H22[1][e][b];
        } else {
            h[1][0] =  H11[1][e][b];  h[1][1] =  H12[1][e][b];
            h[1][2] =  H21[1][e][b];  h[1][3] =  H22[1][e][b];
        }
    }
    h_step[0][0] = (H11[0][e+1][b] - h[0][0]) * width;   // 终点-起点 × 步长
    h_step[0][1] = (H12[0][e+1][b] - h[0][1]) * width;
    h_step[0][2] = (H21[0][e+1][b] - h[0][2]) * width;
    h_step[0][3] = (H22[0][e+1][b] - h[0][3]) * width;
    if (!PS_BASELINE && ps2->enable_ipdopd) {
        h_step[1][0] = (H11[1][e+1][b] - h[1][0]) * width;
        ... (4 次)
    }
    if (stop - start)
        ps->dsp.stereo_interpolate[!PS_BASELINE && ps2->enable_ipdopd](
            l[k] + 1 + start, r[k] + 1 + start, h, h_step, stop - start);
}
```

- 插值时隙区间 `[start+1, stop]`，共 `stop-start` 个；slot 0 由上一帧末包络覆盖。
- `stereo_interpolate[0]`（无 ipd/opd，只处理实部层）或 `[1]`（ipd/opd，处理两层）。
- 子子带 `k∈[9,13]`（34 带）与 `k∈[0,1]`（20 带）的虚部层取负——对应与 `ipdopd` 相关的相位反转，是解码器既定怪癖。

---

## 5. `hybrid_synthesis`（aacps.c 145-184）

```c
static void hybrid_synthesis(PSDSPContext *dsp, INTFLOAT out[2][38][64],
                             INTFLOAT in[91][32][2], int is34, int len)
{
    if (is34) {
        for (n = 0; n < len; n++) {
            memset(out[0][n], 0, 5*sizeof(float));   // QMF 带 0..4 清零
            memset(out[1][n], 0, 5*sizeof(float));
            for (i = 0; i < 12; i++) { out[0][n][0] += in[   i][n][0]; out[1][n][0] += in[   i][n][1]; }
            for (i = 0; i <  8; i++) { out[0][n][1] += in[12+i][n][0]; out[1][n][1] += in[12+i][n][1]; }
            for (i = 0; i <  4; i++) {
                out[0][n][2] += in[20+i][n][0]; out[1][n][2] += in[20+i][n][1];
                out[0][n][3] += in[24+i][n][0]; out[1][n][3] += in[24+i][n][1];
                out[0][n][4] += in[28+i][n][0]; out[1][n][4] += in[28+i][n][1];
            }
        }
        dsp->hybrid_synthesis_deint(out, in + 27, 5, len);   // 子子带 32..90 → QMF 带 5..63
    } else {
        for (n = 0; n < len; n++) {
            out[0][n][0] = in[0][n][0] + in[1][n][0] + in[2][n][0] + in[3][n][0] + in[4][n][0] + in[5][n][0];
            out[1][n][0] = ... 同上 [1] ...;
            out[0][n][1] = in[6][n][0] + in[7][n][0];  out[1][n][1] = ...;
            out[0][n][2] = in[8][n][0] + in[9][n][0];  out[1][n][2] = ...;
        }
        dsp->hybrid_synthesis_deint(out, in + 7, 3, len);    // 子子带 10..70 → QMF 带 3..63
    }
}
```

- 综合 = 分析逆：同一 QMF 子带的多个子子带求和；未拆分的 QMF 带透传（`hybrid_synthesis_deint`）。
- 34 带：子子带 0..31 → QMF 带 0..4（12+8+4+4+4）；子子带 32..90 → QMF 带 5..63。
- 20 带：子子带 0..9 → QMF 带 0..2（6+2+2）；子子带 10..70 → QMF 带 3..63。
- `out[0][n]` 实部、`out[1][n]` 虚部，只写时隙 `n ∈ [0,32)`（QMF 重叠区未动）。

---

## 6. PSDSP 函数逐条（aacpsdsp_template.c）——8 个，含 C 关键片段 + 逐行注释

### 6.1 `ps_add_squares_c`

```c
static void ps_add_squares_c(INTFLOAT *restrict dst, const INTFLOAT (*src)[2], int n)
{
    for (int i = 0; i < n; i++)
        dst[i] += src[i][0]*src[i][0] + src[i][1]*src[i][1];
}
```

| 行 | 语义 |
|---|---|
| 循环 i ∈ [0,n) | `dst[i]` 累加复数能量 `|src[i]|² = re²+im²` |

- 调用处：`ps->dsp.add_squares(power[i], s[k], 32)` → `power[i][n] += |s[k][n]|²`。
- 注意 `dst`/`src` 不重叠；float 路径直接累加。

Zig：

```zig
fn psAddSquares(dst: []f32, src: *const [32][2]f32) void {
    for (src, 0..) |v, i| dst[i] += v[0]*v[0] + v[1]*v[1];
}
```

### 6.2 `ps_mul_pair_single_c`

```c
static void ps_mul_pair_single_c(INTFLOAT (*restrict dst)[2], INTFLOAT (*src0)[2],
                                 INTFLOAT *src1, int n)
{
    for (int i = 0; i < n; i++) {
        dst[i][0] = src0[i][0] * src1[i];
        dst[i][1] = src0[i][1] * src1[i];
    }
}
```

| 行 | 语义 |
|---|---|
| 循环 i ∈ [0,n) | 复数 `src0[i]` × 实标量 `src1[i]` 写入 `dst[i]` |

- 用于延迟区：`mul_pair_single(out[k], delay[k]+offset, transient_gain[i], 32)`。

### 6.3 `ps_hybrid_analysis_c` —— 13 抽头对称复滤波器

```c
static void ps_hybrid_analysis_c(INTFLOAT (*restrict out)[2], INTFLOAT (*in)[2],
                                 const INTFLOAT (*filter)[8][2], ptrdiff_t stride, int n)
{
    INTFLOAT inre0[6], inre1[6], inim0[6], inim1[6];
    for (int j = 0; j < 6; j++) {                 // 对称组合（13 抽头 = 中心 1 + 6 对）
        inre0[j] = in[j][0] + in[12 - j][0];      // 实部同相和
        inre1[j] = in[j][1] - in[12 - j][1];      // 实部反相（= 虚部差）
        inim0[j] = in[j][1] + in[12 - j][1];      // 虚部同相和
        inim1[j] = in[j][0] - in[12 - j][0];      // 虚部反相（= 实部差）
    }
    for (int i = 0; i < n; i++) {
        INTFLOAT sum_re = filter[i][6][0] * in[6][0];   // 中心抽头，只用实部系数
        INTFLOAT sum_im = filter[i][6][0] * in[6][1];
        for (int j = 0; j < 6; j++) {
            sum_re += filter[i][j][0]*inre0[j] - filter[i][j][1]*inre1[j];
            sum_im += filter[i][j][0]*inim0[j] + filter[i][j][1]*inim1[j];
        }
        out[i * stride][0] = sum_re;
        out[i * stride][1] = sum_im;
    }
}
```

| 行 | 语义 |
|---|---|
| `inre0/inre1/inim0/inim1` | 利用 `filter[i][j][1] = -proto·sinθ` 的奇偶性：对实部，同相组合 `in[j]+in[12-j]` 配 `cos` 项，反相组合 `in[j]-in[12-j]` 配 `sin` 项；虚部反之。把 13 次复数乘减为 6 次 + 中心 |
| 中心抽头 `filter[i][6][0]·in[6]` | `filter[i][6][1] = -proto·sin(θ(n=6)) = 0`（θ 在 n=6 处为 0），故只用实部 |
| `sum_re += fr*inre0 - fi*inre1` | 实部 = cos·(实同相) − sin·(实反相)。等价于复数卷积的实部 |
| `sum_im += fr*inim0 + fi*inim1` | 虚部 = cos·(虚同相) + sin·(虚反相) |
| `out[i*stride]` | 写第 i 个输出带，stride 决定布局（1 → 连续；32 → 平面别名） |

- **系数约定**：`filter[q][n][0]=proto[n]·cosθ`，`filter[q][n][1]=proto[n]·(−sinθ)`，`θ=2π(q+0.5)(n−6)/bands`（§7.3）。`filter` 数组是 `[bands][8][2]`，只用列 0..6。
- 数学上对每个输出带 q：`out_q[t] = Σ_{n=0}^{12} proto[n]·e^{−j·2π(q+0.5)(n−6)/bands}·in[t+n−6]`（分析滤波器，下变频）。

### 6.4 `ps_hybrid_analysis_ileave_c`

```c
static void ps_hybrid_analysis_ileave_c(INTFLOAT (*restrict out)[32][2],
                                        INTFLOAT L[2][38][64], int i, int len)
{
    for (; i < 64; i++)                     // QMF 带 i 起
        for (int j = 0; j < len; j++) {     // 时隙 j
            out[i][j][0] = L[0][j][i];      // L[实部][时隙][带] → out[带][时隙][实部]
            out[i][j][1] = L[1][j][i];
        }
}
```

| 行 | 语义 |
|---|---|
| `out[i][j][0] = L[0][j][i]` | 未拆分的 QMF 带透传：把 `L` 的（时隙×带）转置为 `out` 的（带×时隙） |

- 调用：`hybrid_analysis_ileave(out + 27, L, 5, len)`（34 带）→ 写 `out[32..90]`；`(out + 7, L, 3, len)`（20 带）→ 写 `out[10..70]`。注意 `i` 是**起始带**（5 或 3），`out` 基址已偏移。

### 6.5 `ps_hybrid_synthesis_deint_c`

```c
static void ps_hybrid_synthesis_deint_c(INTFLOAT out[2][38][64],
                                        INTFLOAT (*restrict in)[32][2], int i, int len)
{
    for (; i < 64; i++)
        for (int n = 0; n < len; n++) {
            out[0][n][i] = in[i][n][0];     // ileave 的逆
            out[1][n][i] = in[i][n][1];
        }
}
```

- 调用 `hybrid_synthesis_deint(out, in + 27, 5, 32)`：`in` 已偏移 27，`i` 从 5..63 → 实际读 `in[32..90]`，写 `out[band 5..63]`。20 带同理偏移 7。

### 6.6 `ps_decorrelate_c` —— 三级全通链（核心）

```c
static void ps_decorrelate_c(INTFLOAT (*out)[2], INTFLOAT (*delay)[2],
                             INTFLOAT (*ap_delay)[PS_QMF_TIME_SLOTS + PS_MAX_AP_DELAY][2],
                             const INTFLOAT phi_fract[2], const INTFLOAT (*Q_fract)[2],
                             const INTFLOAT *transient_gain,
                             INTFLOAT g_decay_slope, int len)
{
    static const INTFLOAT a[] = { 0.65143905753106f, 0.56471812200776f, 0.48954165955695f };
    INTFLOAT ag[PS_AP_LINKS];           // 链路反馈系数 × 衰减斜率
    for (m = 0; m < 3; m++)
        ag[m] = a[m] * g_decay_slope;

    for (n = 0; n < len; n++) {
        // ① 整体分数延迟 phi_fract 旋转：in = delay[n] * phi_fract（复数乘法）
        INTFLOAT in_re = delay[n][0]*phi_fract[0] - delay[n][1]*phi_fract[1];
        INTFLOAT in_im = delay[n][0]*phi_fract[1] + delay[n][1]*phi_fract[0];
        for (m = 0; m < PS_AP_LINKS; m++) {
            INTFLOAT a_re  = ag[m] * in_re;               // 反馈项 ag*x
            INTFLOAT a_im  = ag[m] * in_im;
            INTFLOAT link_delay_re = ap_delay[m][n+2-m][0];   // 该链路历史输出（链间错位）
            INTFLOAT link_delay_im = ap_delay[m][n+2-m][1];
            INTFLOAT fractional_delay_re = Q_fract[m][0];     // 分数延迟旋转
            INTFLOAT fractional_delay_im = Q_fract[m][1];
            INTFLOAT apd_re = in_re;                          // 保存本链路输入
            INTFLOAT apd_im = in_im;
            // 一级全通：error = Q*y_delayed - ag*x
            in_re = link_delay_re*fractional_delay_re - link_delay_im*fractional_delay_im - a_re;
            in_im = link_delay_re*fractional_delay_im + link_delay_im*fractional_delay_re - a_im;
            // 写回：y[n] = x + ag*error（直接 I 型全通）
            ap_delay[m][n+5][0] = apd_re + ag[m]*in_re;
            ap_delay[m][n+5][1] = apd_im + ag[m]*in_im;
        }
        out[n][0] = transient_gain[n] * in_re;      // 瞬态增益缩放
        out[n][1] = transient_gain[n] * in_im;
    }
}
```

**逐行注释（重点）**：

| 行 | 语义 |
|---|---|
| `ag[m] = a[m]*g_decay_slope` | 链路 m 反馈系数，`g_decay_slope = clip(1 − 0.05(k−CUTOFF), 0, 1)` 每带固定 |
| `in = delay[n]·phi_fract` | 复乘 `phi_fract[k]`（单位圆 `e^{−jπ·0.39·f_center}`），实现整体分数延迟 |
| `a_re/a_im` | 反馈项 `ag[m]·x`，用在 error 里做 − |
| `link_delay = ap_delay[m][n+2−m]` | 读链延迟：m=0→`[n+2]`、m=1→`[n+1]`、m=2→`[n]`。写指针恒为 `[n+5]`，故链路内回读滞后写 3+m 时隙（m=0:3, m=1:4, m=2:5）——即 `z^{-link_delay}` 实现 |
| `apd_re/apd_im` | 保存本链路输入 x，供写回 |
| `error = Q·y_delayed − ag·x` | 全通分子：`Q_fract[m]·link_delay − ag·x`（复乘 `Q_fract` 实现分数延迟旋转） |
| `ap_delay[m][n+5] = x + ag·error` | 全通输出 `y = x + ag·(Q·y_delayed − ag·x)`，写回延迟线。n+5 ∈ [5,36]，与移位后 `[0..4]` 拼接成完整环 |
| `out[n] = transient_gain[n]·in_re` | 三级链末端 `in` 是最后一级的 error 信号（不是 y），乘瞬态增益输出 |

**全通传递函数**（每个链路）：

```
y[n] = x[n] + ag·(Q·y[n−d] − ag·x[n])   →   H_allpass = (1 − ag²) / (1 − ag·Q·z^{−d})
```

三级级联 + 前置 `z^{−2}·phi_fract` 即 aacps.c 注释中的 H[k][z]（§3.5）。FFmpeg 注释公式中的分子 `Q·z^{−l} − a·g` 对应这里的 error 项，是理论形式；**实际实现的逐位行为以上面代码为准**。

**读/写索引合法性**：
- 读 `ap_delay[m][n+2−m]`：m=0 → n+2 ∈ [2,33]；m=1 → n+1 ∈ [1,32]；m=2 → n ∈ [0,31]。均 ≤ 36（数组宽 37）。
- 写 `ap_delay[m][n+5]` ∈ [5,36]。同一帧内链路内存在 3/4/5 时隙的回读（读旧写新），跨帧由调用前的 5 元素移位衔接。

Zig：

```zig
fn psDecorrelate(
    out: *[32][2]f32,
    delay: *const [32][2]f32,        // 已移位，基址 delay[k]+12
    apDelay: *[3][37][2]f32,
    phiFract: [2]f32,
    qFract: *const [3][2]f32,
    transientGain: *const [32]f32,
    gDecaySlope: f32,
) void {
    const a = [3]f32{ 0.65143905753106, 0.56471812200776, 0.48954165955695 };
    var ag: [3]f32 = undefined;
    for (a, 0..) |av, m| ag[m] = av * gDecaySlope;
    for (delay, 0..) |dn, n| {
        var inRe = dn[0] * phiFract[0] - dn[1] * phiFract[1];
        var inIm = dn[0] * phiFract[1] + dn[1] * phiFract[0];
        for (0..3) |m| {
            const aRe = ag[m] * inRe;
            const aIm = ag[m] * inIm;
            const ldRe = apDelay[m][n + 2 - m][0];
            const ldIm = apDelay[m][n + 2 - m][1];
            const fRe = qFract[m][0];
            const fIm = qFract[m][1];
            const apdRe = inRe;
            const apdIm = inIm;
            inRe = ldRe * fRe - ldIm * fIm - aRe;
            inIm = ldRe * fIm + ldIm * fRe - aIm;
            apDelay[m][n + 5][0] = apdRe + ag[m] * inRe;
            apDelay[m][n + 5][1] = apdIm + ag[m] * inIm;
        }
        out[n][0] = transientGain[n] * inRe;
        out[n][1] = transientGain[n] * inIm;
    }
}
```

### 6.7 `ps_stereo_interpolate_c`（无 ipd/opd）

```c
static void ps_stereo_interpolate_c(INTFLOAT (*l)[2], INTFLOAT (*r)[2],
                                    INTFLOAT h[2][4], INTFLOAT h_step[2][4], int len)
{
    INTFLOAT h0 = h[0][0], h1 = h[0][1], h2 = h[0][2], h3 = h[0][3];   // 只实部层
    UINTFLOAT hs0 = h_step[0][0], hs1 = h_step[0][1],
             hs2 = h_step[0][2], hs3 = h_step[0][3];
    for (n = 0; n < len; n++) {
        INTFLOAT l_re = l[n][0], l_im = l[n][1], r_re = r[n][0], r_im = r[n][1];
        h0 += hs0; h1 += hs1; h2 += hs2; h3 += hs3;    // 逐时隙线性插值
        l[n][0] = h0*l_re + h2*r_re;                   // l = h11·s + h21·d
        l[n][1] = h0*l_im + h2*r_im;
        r[n][0] = h1*l_re + h3*r_re;                   // r = h12·s + h22·d
        r[n][1] = h1*l_im + h3*r_im;
    }
}
```

- 混合：`[l; r] = [h11 h21; h12 h22] · [s; d]`，全实数。
- `h/h_step` 只读实部层 `[0][0..3]`，虚部层 `[1]` 不读。

### 6.8 `ps_stereo_interpolate_ipdopd_c`

```c
    INTFLOAT h00 = h[0][0], h10 = h[1][0];   // 实部层 h[0]、虚部层 h[1]
    INTFLOAT h01 = h[0][1], h11 = h[1][1];
    INTFLOAT h02 = h[0][2], h12 = h[1][2];
    INTFLOAT h03 = h[0][3], h13 = h[1][3];
    ... hs00..hs13 对应 h_step 两层 ...
    for (n = 0; n < len; n++) {
        INTFLOAT l_re = l[n][0], l_im = l[n][1], r_re = r[n][0], r_im = r[n][1];
        h00 += hs00; h01 += hs01; h02 += hs02; h03 += hs03;
        h10 += hs10; h11 += hs11; h12 += hs12; h13 += hs13;
        l[n][0] =  h00*l_re + h02*r_re - h10*l_im - h12*r_im;
        l[n][1] =  h00*l_im + h02*r_im + h10*l_re + h12*r_re;
        r[n][0] =  h01*l_re + h03*r_re - h11*l_im - h13*r_im;
        r[n][1] =  h01*l_im + h03*r_im + h11*l_re + h13*r_re;
    }
```

- 复数混合：`l = (h11+j·h11i)·s + (h21+j·h21i)·d`（h10/h12 是虚部系数）。实部 = 实×实 − 虚×虚；虚部 = 实×虚 + 虚×实。

---

## 7. 表清单、选择逻辑与生成公式

### 7.1 静态数据表（非生成，来自 aacpsdata.c / aacps_common.c）

**huff_sizes / huff_offset / 表顺序**（aacpsdata.c 24, 91-97）：

```c
static const uint8_t huff_sizes[]  = { 61, 61, 29, 29, 15, 15,  8,  8,  8,  8 };
static const int8_t  huff_offset[] = {-30,-30,-14,-14, -7, -7,  0,  0,  0,  0 };
// 顺序：iid_df1, iid_dt1, iid_df0, iid_dt0, icc_df, icc_dt, ipd_df, ipd_dt, opd_df, opd_dt
//   （与 enum 一致：huff_iid_df1=0, huff_iid_dt1=1, huff_iid_df0=2, huff_iid_dt0=3,
//     huff_icc_df=4, huff_icc_dt=5, huff_ipd_df=6, huff_ipd_dt=7, huff_opd_df=8, huff_opd_dt=9）
```

**huff_iid 选择表**（aacps_common.c 54-59）：

```c
static const int huff_iid[] = { huff_iid_df0, huff_iid_df1, huff_iid_dt0, huff_iid_dt1 };
// 用法：huff_iid[2*dt + iid_quant]
//   dt=0 粗(quant=0) → 索引0 → df0；dt=0 细(quant=1) → 索引1 → df1
//   dt=1 粗          → 索引2 → dt0；dt=1 细          → 索引3 → dt1
```

**icc/ipd/opd 选择**：`dt ? huff_icc_dt : huff_icc_df`，ipd/opd 同理。

**位流参数表**（aacps_common.c 28-39）：

```c
static const int8_t num_env_tab[2][4]        = { { 0, 1, 2, 4 }, { 1, 2, 3, 4 } };
static const int8_t nr_iidicc_par_tab[]      = { 10, 20, 34, 10, 20, 34 };
static const int8_t nr_iidopd_par_tab[]      = {  5, 11, 17,  5, 11, 17 };
// num_env_tab[frame_class][2bit 索引]
// nr_iidicc_par_tab / nr_iidopd_par_tab：按 iid_mode(0..5) / icc_mode(0..5) 索引
```

**ff_log2_tab**（libavutil 静态表，`num_env` ∈ {1,2,4} 时取值 0/1/2）：

```c
// ff_log2_tab[i] = floor(log2(i))，用于固定边界：border_position[e] = (e*32 >> ff_log2_tab[num_env]) - 1
```

### 7.2 `ff_k_to_i_20` / `ff_k_to_i_34`（aacpsdata.c 100-113，Table 8.48/8.49）

`k_to_i[k]`：子子带 k → 参数带 i。**原样照抄**（值为 int8）：

`ff_k_to_i_20[71]`：
```
1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 14, 15,
15, 15, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18,
18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19
```

`ff_k_to_i_34[91]`：
```
0, 1, 2, 3, 4, 5, 6, 6, 7, 2, 1, 0, 10, 10, 4, 5, 6, 7, 8,
9, 10, 11, 12, 9, 14, 11, 12, 13, 14, 15, 16, 13, 16, 17, 18, 19, 20, 21,
22, 22, 23, 23, 24, 24, 25, 25, 26, 26, 27, 27, 27, 28, 28, 28, 29, 29, 29,
30, 30, 30, 31, 31, 31, 31, 32, 32, 32, 32, 33, 33, 33, 33, 33, 33, 33, 33,
33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33
```

### 7.3 运行时生成表（ps_tableinit，aacps_tablegen.h 85-214）—— 4 个生成块

`CONFIG_HARDCODED_TABLES=0` 时 `ps_tableinit()` 在 `ff_ps_init()` 中被调用一次。四个块：

**块 A：`pd_re_smooth`/`pd_im_smooth`[512]（相位平滑表）**

```c
ipdopd_sin[] = { 0, M_SQRT1_2, 1,  M_SQRT1_2,  0, -M_SQRT1_2, -1, -M_SQRT1_2 };
ipdopd_cos[] = { 1, M_SQRT1_2, 0, -M_SQRT1_2, -1, -M_SQRT1_2,  0,  M_SQRT1_2 };
// M_SQRT1_2 = 0.7071067811865475

for (pd0,pd1,pd2 in 0..7) {
    re_smooth = 0.25f*cos[pd0] + 0.5f*cos[pd1] + cos[pd2];   // 加权（最新权 1.0）
    im_smooth = 0.25f*sin[pd0] + 0.5f*sin[pd1] + sin[pd2];
    pd_mag = 1 / hypot(im_smooth, re_smooth);                // 归一化到单位圆
    pd_re_smooth[pd0*64+pd1*8+pd2] = re_smooth * pd_mag;
    pd_im_smooth[pd0*64+pd1*8+pd2] = im_smooth * pd_mag;
}
```

**块 B：`HA`/`HB`[46][8][4]（混合矩阵）**

```c
static const float iid_par_dequant[46] = {   // 行序与 H_LUT 行索引一致
    // 粗（行 0..14 = 编码 −7..7）
    0.05623413251903, 0.12589254117942, 0.19952623149689, 0.31622776601684,
    0.44668359215096, 0.63095734448019, 0.79432823472428, 1,
    1.25892541179417, 1.58489319246111, 2.23872113856834, 3.16227766016838,
    5.01187233627272, 7.94328234724282, 17.7827941003892,
    // 细（行 15..45 = 编码 −15..15）
    0.00316227766017, 0.00562341325190, 0.01,             0.01778279410039,
    0.03162277660168, 0.05623413251903, 0.07943282347243, 0.11220184543020,
    0.15848931924611, 0.22387211385683, 0.31622776601684, 0.39810717055350,
    0.50118723362727, 0.63095734448019, 0.79432823472428, 1,
    1.25892541179417, 1.58489319246111, 1.99526231496888, 2.51188643150958,
    3.16227766016838, 4.46683592150963, 6.30957344480193, 8.91250938133745,
    12.5892541179417, 17.7827941003892, 31.6227766016838, 56.2341325190349,
    100,              177.827941003892, 316.227766016837,
};
static const float icc_invq[8]       = { 1, 0.937, 0.84118, 0.60092, 0.36764, 0, -0.589, -1 };
static const float acos_icc_invq[8]  = { 0, 0.35685527, 0.57133466, 0.92614472, 1.1943263,
                                         M_PI/2, 2.2006171, M_PI };
// M_PI/2 = 1.5707963267948966

for (iid = 0; iid < 46; iid++) {
    float c  = iid_par_dequant[iid];
    float c1 = M_SQRT2 / sqrtf(1.0f + c*c);        // M_SQRT2 = 1.4142135623730951
    float c2 = c * c1;
    for (icc = 0; icc < 8; icc++) {
        // —— 混合方式 A ——
        float alpha = 0.5f * acos_icc_invq[icc];
        float beta  = alpha * (c1 - c2) * M_SQRT1_2;
        HA[iid][icc][0] = c2 * cosf(beta + alpha);
        HA[iid][icc][1] = c1 * cosf(beta - alpha);
        HA[iid][icc][2] = c2 * sinf(beta + alpha);
        HA[iid][icc][3] = c1 * sinf(beta - alpha);
        // —— 混合方式 B ——
        float rho = FFMAX(icc_invq[icc], 0.05f);
        float alpha = 0.5f * atan2f(2.0f * c * rho, c*c - 1.0f);
        float mu = c + 1.0f / c;
        mu = sqrtf(1 + (4 * rho * rho - 4)/(mu * mu));
        float gamma = atanf(sqrtf((1.0f - mu)/(1.0f + mu)));
        if (alpha < 0) alpha += M_PI/2;
        alpha_c = cosf(alpha); alpha_s = sinf(alpha);
        gamma_c = cosf(gamma); gamma_s = sinf(gamma);
        HB[iid][icc][0] =  M_SQRT2 * alpha_c * gamma_c;
        HB[iid][icc][1] =  M_SQRT2 * alpha_s * gamma_c;
        HB[iid][icc][2] = -M_SQRT2 * alpha_s * gamma_s;
        HB[iid][icc][3] =  M_SQRT2 * alpha_c * gamma_s;
    }
}
```

**块 C：混合分析滤波器（解析生成）** `f20_0_8[8][8][2]`、`f34_0_12[12][8][2]`、`f34_1_8[8][8][2]`、`f34_2_4[4][8][2]`

```c
static const float g0_Q8[]  = { 0.00746082949812f, 0.02270420949825f, 0.04546865930473f,
                                0.07266113929591f, 0.09885108575264f, 0.11793710567217f, 0.125f };
static const float g0_Q12[] = { 0.04081179924692f, 0.03812810994926f, 0.05144908135699f,
                                0.06399831151592f, 0.07428313801106f, 0.08100347892914f, 0.08333333333333f };
static const float g1_Q8[]  = { 0.01565675600122f, 0.03752716391991f, 0.05417891378782f,
                                0.08417044116767f, 0.10307344158036f, 0.12222452249753f, 0.125f };
static const float g2_Q4[]  = { -0.05908211155639f, -0.04871498374946f, 0.0f,
                                0.07778723915851f,  0.16486303567403f,  0.23279856662996f, 0.25f };

static void make_filters_from_proto(float (*filter)[8][2], const float *proto, int bands) {
    for (q = 0; q < bands; q++)
        for (n = 0; n < 7; n++) {                       // 只填列 0..6
            double theta = 2 * M_PI * (q + 0.5) * (n - 6) / bands;
            filter[q][n][0] = proto[n] *  cos(theta);
            filter[q][n][1] = proto[n] * -sin(theta);
        }
}
// 调用：
//   make_filters_from_proto(f20_0_8,  g0_Q8,   8);
//   make_filters_from_proto(f34_0_12, g0_Q12, 12);
//   make_filters_from_proto(f34_1_8,  g1_Q8,   8);
//   make_filters_from_proto(f34_2_4,  g2_Q4,   4);
```

- `n=6` 为中心抽头：`theta=0`，`filter[q][6] = { proto[6], 0 }`，与 §6.3 只读实部一致。
- 第 7 列（n=7）从不写入/读取（存储余量）。
- **结论**：f20/f34 原型滤波器由 `cos/sin` 解析生成，无 Hann 窗。若目标移植自 VLC/faad 的 `hann_128_96` 表，需按此公式重新生成或采用其实现语义（本文档以 FFmpeg 为准）。

`g1_Q2[7]`（aacps.c 37-40，供 `hybrid2_re`）：

```c
static const INTFLOAT g1_Q2[] = {
    0.0f, 0.01899487526049f, 0.0f, -0.07293139167538f,
    0.0f, 0.30596630545168f, 0.5f
};
// 偶抽头 0,2,4 为 0（实滤波器对称对只读 1,3,5）
```

**块 D：去相关表 `Q_fract_allpass[2][50][3][2]`、`phi_fract[2][50][2]`**

```c
static const int8_t f_center_20[] = { -3, -1, 1, 3, 5, 7, 10, 14, 18, 22 };
static const int8_t f_center_34[] = { 2,  6, 10, 14, 18, 22, 26, 30,
                                      34,-10, -6, -2, 51, 57, 15, 21,
                                      27, 33, 39, 45, 54, 66, 78, 42,
                                      102, 66, 78, 90,102,114,126, 90 };
static const float fractional_delay_links[] = { 0.43f, 0.75f, 0.347f };
const float fractional_delay_gain = 0.39f;

// 20 带（NR_ALLPASS_BANDS20=30）：
for (k = 0; k < 30; k++) {
    double f_center = (k < 10) ? f_center_20[k] * 0.125 : k - 6.5f;   // k≥10: 3.5,4.5,...,23.5
    for (m = 0; m < 3; m++) {
        double theta = -M_PI * fractional_delay_links[m] * f_center;
        Q_fract_allpass[0][k][m][0] = cos(theta);
        Q_fract_allpass[0][k][m][1] = sin(theta);
    }
    double theta = -M_PI * fractional_delay_gain * f_center;
    phi_fract[0][k][0] = cos(theta);
    phi_fract[0][k][1] = sin(theta);
}
// 34 带（NR_ALLPASS_BANDS34=50）：
for (k = 0; k < 50; k++) {
    double f_center = (k < 32) ? f_center_34[k] / 24.0 : k - 26.5f;   // k≥32: 5.5,6.5,...,23.5
    ... 同 20 带，写入 [1][k] ...
}
```

- 注意 `f_center` 用 `double` 计算，结果赋 `float`。`theta` 为负，等价 `e^{−jπ·frac·f_center}`。

### 7.4 运行时 vs 静态 总结

| 表 | 来源 | 生成方式 |
|---|---|---|
| `pd_re_smooth/pd_im_smooth` | ps_tableinit 块 A | 运行时 |
| `HA/HB` | ps_tableinit 块 B | 运行时 |
| `f20_0_8/f34_0_12/f34_1_8/f34_2_4` | ps_tableinit 块 C | 运行时解析生成 |
| `Q_fract_allpass/phi_fract` | ps_tableinit 块 D | 运行时 |
| `iid_par_dequant/icc_invq/acos_icc_invq/ipdopd_sin/cos` | ps_tableinit 内 static | 源码常量 |
| `g0_Q8/g0_Q12/g1_Q8/g2_Q4` | ps_tableinit 内 static | 源码常量 |
| `g1_Q2` | aacps.c | 源码常量 |
| `ff_k_to_i_20/34` | aacpsdata.c | 源码常量 |
| `huff_sizes/aacps_huff_tabs/huff_offset` | aacpsdata.c | 源码常量 |
| `num_env_tab/nr_iidicc_par_tab/nr_iidopd_par_tab` | aacps_common.c | 源码常量 |
| 10 张 VLC 查找表 | `ff_ps_init_common` | 运行时由 `ff_vlc_init_tables_from_lengths` 构建（§8） |

`aacps_tablegen.c` 是**独立工具**（`main()` 调用 `ps_tableinit()` 后把表以 C 源码形式打印），只在 `CONFIG_HARDCODED_TABLES=1` 构建时把输出编入 `aacps_tables.h`。**本仓库 `config.h:675` 明确 `CONFIG_HARDCODED_TABLES 0`**，Zig 移植在初始化期直接执行 4 个生成块即可。

---

## 8. VLC 表（vlc_ps）：完整规格

### 8.1 十张表的元数据

`ff_ps_init_common`（aacps_common.c 291-306）构建顺序 = 枚举顺序。对每张表调用：

```c
vlc_ps[i] = ff_vlc_init_tables_from_lengths(&state,
                 i <= 5 ? 9 : 5,     // nb_bits：iid/icc 用 9，ipd/opd 用 5
                 huff_sizes[i],      // 条目数
                 &tab[0][1], 2,      // 码长字段，stride 2 字节
                 &tab[0][0], 2, 1,   // 符号字段，stride 2 字节、1 字节宽
                 huff_offset[i], 0); // 符号偏移
```

| 表索引 | 名称 | nb_bits | 条目数 | offset | get_vlc2 参数 |
|---|---|---|---|---|---|
| 0 | huff_iid_df1 | 9 | 61 | -30 | (9, max_depth 3) |
| 1 | huff_iid_dt1 | 9 | 61 | -30 | (9, 3) |
| 2 | huff_iid_df0 | 9 | 29 | -14 | (9, 3) |
| 3 | huff_iid_dt0 | 9 | 29 | -14 | (9, 3) |
| 4 | huff_icc_df | 9 | 15 | -7 | (9, 2) |
| 5 | huff_icc_dt | 9 | 15 | -7 | (9, 2) |
| 6 | huff_ipd_df | 5 | 8 | 0 | (5, 1) |
| 7 | huff_ipd_dt | 5 | 8 | 0 | (5, 1) |
| 8 | huff_opd_df | 5 | 8 | 0 | (5, 1) |
| 9 | huff_opd_dt | 5 | 8 | 0 | (5, 1) |

`get_vlc2(gb, vlc_ps[table_idx], NB_BITS, MAX_DEPTH)` 的 NB_BITS/MAX_DEPTH：iid (9,3)、icc (9,2)、ipd/opd (5,1)。最长码：iid 20（→9+9+2 三级）、icc 14（→9+5 二级）、ipd/opd 5（单级）。

### 8.2 `ff_vlc_init_from_lengths` 算法（vlc.c 306-351）—— 规范哈夫曼构建

```c
j = code = 0;
for (i = 0; i < nb_codes; i++, lens += lens_wrap) {
    int len = *lens;                       // 码长（aacps 全为正）
    if (len > 0) {
        buf[j].bits   = len;
        buf[j].symbol = sym + offset;      // 符号 + 偏移
        buf[j++].code = code;              // 规范码（MSB 对齐）
    }
    if (len > len_max || code & ((1U << (32 - len)) - 1))   // 对齐校验
        goto fail;
    code += 1U << (32 - len);              // 分配下一码
    if (code > UINT32_MAX + 1ULL)          // 过载校验
        goto fail;
}
```

**要点**：
- 码值**按表内顺序累加分配**（不排序）——`aacpsdata.c` 的表已满足规范哈夫曼顺序约束。
- `buf[j].code` 是 **MSB 对齐**的 32 位值（码占据最高 len 位），`buf[j].symbol = sym + offset`。
- 约束：`len <= 3*nb_bits`（len_max）且每次分配的码必须与 (32-len) 位对齐。

### 8.3 `build_table`（vlc.c 138-227）—— 二级/三级查找表

```c
table_size = 1 << table_nb_bits;                 // 主表 2^nb_bits 项（VLCElem = {sym,len}）
for (i = 0; i < nb_codes; i++) {
    n = codes[i].bits;  code = codes[i].code;  symbol = codes[i].symbol;
    if (n <= table_nb_bits) {                    // 直接落主表
        j  = code >> (32 - table_nb_bits);       // 主表前缀索引
        nb = 1 << (table_nb_bits - n);           // 覆盖项数
        for (k = 0; k < nb; k++) {
            if ((table[j].len || table[j].sym) && (table[j].len != n || table[j].sym != symbol))
                return ERROR;                    // 同一前缀的填充必须一致
            table[j].len = n;  table[j].sym = symbol;
            j += 1;
        }
    } else {                                     // 子表（n > nb_bits）
        n -= table_nb_bits;                      // 子表剩余位
        code_prefix = code >> (32 - table_nb_bits);
        subtable_bits = n;
        codes[i].bits = n;  codes[i].code = code << table_nb_bits;
        for (k = i+1; k < nb_codes; k++) {       // 合并同前缀的后续码
            n = codes[k].bits - table_nb_bits;
            if (n <= 0) break;
            code = codes[k].code;
            if (code >> (32-table_nb_bits) != code_prefix) break;
            codes[k].bits = n; codes[k].code = code << table_nb_bits;
            subtable_bits = FFMAX(subtable_bits, n);
        }
        subtable_bits = FFMIN(subtable_bits, table_nb_bits);
        table[code_prefix].len = -subtable_bits;        // 负 len = 子表指示
        index = build_table(vlc, subtable_bits, k-i, codes+i, flags);   // 递归
        table[code_prefix].sym = index;                 // 子表基址
        i = k-1;
    }
}
for (i = 0; i < table_size; i++)
    if (table[i].len == 0) table[i].sym = -1;           // 未填充项
```

**要点**：
- 主表项 `{sym, len}`：len>0 表示真实码长；len<0 表示子表（sym=子表基址，|len|=子表位宽）；len==0 填充为 `{-1, 0}`。
- 递归中 `codes` 数组被就地改写（bits/code 缩小到子表视角），Zig 需注意传引用。
- 分配器：`alloc_table` 顺序追加；Zig 可动态分配每张表（`alloc` 主表 2^nb_bits + 递归子表），或用预分配池（C 用 5652 项池，见 aacps_common.c 293）。

### 8.4 `get_vlc2` 解码（get_bits.h 573-600, 645-658）

```c
idx  = SHOW_UBITS(gb, bits);        // 读位流头部 bits 位（MSB 优先）
code = table[idx].sym;  n = table[idx].len;
if (max_depth > 1 && n < 0) {       // 子表下钻
    SKIP bits 位；刷新缓存；
    nb = -n;
    idx  = SHOW_UBITS(gb, nb) + code;
    code = table[idx].sym;  n = table[idx].len;
    if (max_depth > 2 && n < 0) {   // 第三级
        SKIP nb 位；刷新缓存；
        nb  = -n;
        idx  = SHOW_UBITS(gb, nb) + code;
        code = table[idx].sym;  n  = table[idx].len;
    }
}
SKIP n 位；   // 真实码长
return code;
```

- iid：表 9 位主查，最多下钻两级（最长 20 位 → 9+9+2）。`max_depth=3` 允许下钻 2 次。
- icc：`max_depth=2`，最多下钻 1 次。
- ipd/opd：`max_depth=1`，单级（5 位主表直接命中）。

### 8.5 `aacps_huff_tabs` 完整数据（242 条，{symbol, code_length}）

`huff_sizes` 依次切分。符号需加 `huff_offset[i]` 才是参数值。

```
/* huff_iid_df1 — 61 条（offset -30） */
{28,4},{32,4},{29,3},{31,3},{27,5},{33,5},{26,6},{34,6},{25,7},{35,7},
{24,8},{36,8},{37,9},{40,11},{19,12},{41,12},{22,10},{38,10},{9,17},{51,17},
{11,17},{49,17},{13,16},{47,16},{16,14},{18,13},{42,13},{44,14},{12,17},{48,17},
{4,18},{5,18},{2,18},{3,18},{15,15},{21,11},{39,11},{45,15},{8,18},{52,18},
{6,18},{7,18},{55,18},{56,18},{53,18},{54,18},{17,14},{43,14},{59,18},{60,18},
{57,18},{58,18},{0,18},{1,18},{10,18},{50,18},{14,16},{46,16},{20,12},{23,10},
{30,1}
/* huff_iid_dt1 — 61 条（offset -30） */
{31,2},{26,7},{34,7},{27,6},{33,6},{35,8},{24,9},{36,9},{39,11},{41,12},
{9,15},{10,15},{48,15},{49,15},{17,13},{23,10},{37,10},{43,13},{11,15},{12,15},
{4,16},{56,16},{2,16},{3,16},{59,16},{60,16},{57,16},{58,16},{0,16},{1,16},
{5,16},{55,16},{6,16},{54,16},{13,15},{15,14},{20,12},{40,12},{22,11},{38,11},
{45,14},{47,15},{7,16},{53,16},{18,13},{42,13},{16,14},{44,14},{8,16},{52,16},
{14,15},{46,15},{50,16},{51,16},{19,13},{21,12},{25,9},{28,5},{32,5},{29,3},
{30,1}
/* huff_iid_df0 — 29 条（offset -14） */
{14,1},{15,3},{13,3},{16,4},{12,4},{17,5},{11,5},{10,6},{18,6},{19,6},
{9,7},{20,8},{8,9},{7,10},{21,11},{22,13},{6,13},{23,14},{24,14},{5,15},
{25,15},{4,16},{3,17},{0,17},{1,17},{2,17},{26,17},{27,18},{28,18}
/* huff_iid_dt0 — 29 条（offset -14） */
{14,1},{13,2},{15,3},{12,4},{16,5},{11,6},{17,7},{10,8},{18,9},{9,10},
{19,11},{8,12},{20,13},{21,14},{7,15},{22,17},{6,17},{23,19},{0,19},{1,19},
{2,19},{3,20},{4,20},{5,20},{24,20},{25,20},{26,20},{27,20},{28,20}
/* huff_icc_df — 15 条（offset -7） */
{7,1},{8,2},{6,3},{9,4},{5,5},{10,6},{4,7},{11,8},{12,9},{3,10},
{13,11},{2,12},{14,13},{1,14},{0,14}
/* huff_icc_dt — 15 条（offset -7） */
{7,1},{8,2},{6,3},{9,4},{5,5},{10,6},{4,7},{11,8},{3,9},{12,10},
{2,11},{13,12},{1,13},{0,14},{14,14}
/* huff_ipd_df — 8 条（offset 0） */
{1,3},{4,4},{5,4},{3,4},{6,4},{2,4},{7,4},{0,1}
/* huff_ipd_dt — 8 条（offset 0） */
{5,4},{4,5},{3,5},{2,4},{6,4},{1,3},{7,3},{0,1}
/* huff_opd_df — 8 条（offset 0） */
{7,3},{1,3},{3,4},{6,4},{2,4},{5,5},{4,5},{0,1}
/* huff_opd_dt — 8 条（offset 0） */
{5,4},{2,4},{6,4},{4,5},{3,5},{1,3},{7,3},{0,1}
```

**符号取值范围**（加 offset 后）：iid 粗 [-14,14]（校验限 [-7,7]）、细 [-30,30]（校验限 [-15,15]）；icc [-7,7]（校验限 [0,7]，`>7U` 无符号比较兼查负值）；ipd/opd [0,7]（位流 mask 0x07）。

---

## 9. 参数带重映射函数（aacps.c 200-397）—— stereo_processing 依赖

### 9.1 `map_idx_10_to_20`（int 索引重排）

```c
static void map_idx_10_to_20(int8_t *par_mapped, const int8_t *par, int full)
{
    int b = full ? 9 : 4;          // full=0（ipd/opd）时另置 par_mapped[10]=0
    if (!full) par_mapped[10] = 0;
    for (; b >= 0; b--)
        par_mapped[2*b+1] = par_mapped[2*b] = par[b];   // 一对二复制
}
```

### 9.2 `map_idx_34_to_20`（Table 8.46 加权合并）

```c
par_mapped[ 0] = (2*par[0] + par[1]) / 3;    par_mapped[ 1] = (par[1] + 2*par[2]) / 3;
par_mapped[ 2] = (2*par[3] + par[4]) / 3;    par_mapped[ 3] = (par[4] + 2*par[5]) / 3;
par_mapped[ 4] = (par[6] + par[7]) / 2;      par_mapped[ 5] = (par[8] + par[9]) / 2;
par_mapped[ 6] = par[10];                    par_mapped[ 7] = par[11];
par_mapped[ 8] = (par[12] + par[13]) / 2;    par_mapped[ 9] = (par[14] + par[15]) / 2;
par_mapped[10] = par[16];
if (full) {
    par_mapped[11] = par[17];                par_mapped[12] = par[18];   par_mapped[13] = par[19];
    par_mapped[14] = (par[20]+par[21])/2;    par_mapped[15] = (par[22]+par[23])/2;
    par_mapped[16] = (par[24]+par[25])/2;    par_mapped[17] = (par[26]+par[27])/2;
    par_mapped[18] = (par[28]+par[29]+par[30]+par[31])/4;    par_mapped[19] = (par[32]+par[33])/2;
}
```

### 9.3 `map_idx_10_to_34`

```c
if (full) {
    par_mapped[33]=par_mapped[32]=par_mapped[31]=par_mapped[30]=par_mapped[29]=par_mapped[28]=par[9];
    par_mapped[27]=par_mapped[26]=par_mapped[25]=par_mapped[24]=par[8];
    par_mapped[23]=par_mapped[22]=par_mapped[21]=par_mapped[20]=par[7];
    par_mapped[19]=par_mapped[18]=par[6];
    par_mapped[17]=par_mapped[16]=par[5];
} else
    par_mapped[16] = 0;
par_mapped[15]=par_mapped[14]=par_mapped[13]=par_mapped[12]=par[4];
par_mapped[11]=par_mapped[10]=par[3];
par_mapped[9]=par_mapped[8]=par_mapped[7]=par_mapped[6]=par[2];
par_mapped[5]=par_mapped[4]=par_mapped[3]=par[1];
par_mapped[2]=par_mapped[1]=par_mapped[0]=par[0];
```

### 9.4 `map_idx_20_to_34`

```c
if (full) {
    par_mapped[33]=par_mapped[32]=par[19];  par_mapped[31]=par_mapped[30]=par_mapped[29]=par_mapped[28]=par[18];
    par_mapped[27]=par_mapped[26]=par[17];  par_mapped[25]=par_mapped[24]=par[16];
    par_mapped[23]=par_mapped[22]=par[15];  par_mapped[21]=par_mapped[20]=par[14];
    par_mapped[19]=par[13];                 par_mapped[18]=par[12];  par_mapped[17]=par[11];
}
par_mapped[16]=par[10];  par_mapped[15]=par_mapped[14]=par[9];
par_mapped[13]=par_mapped[12]=par[8];  par_mapped[11]=par[7];
par_mapped[10]=par[6];  par_mapped[9]=par_mapped[8]=par[5];
par_mapped[7]=par_mapped[6]=par[4];  par_mapped[5]=par[3];
par_mapped[4]=(par[2]+par[3])/2;  par_mapped[3]=par[2];
par_mapped[2]=par[1];  par_mapped[1]=(par[0]+par[1])/2;  par_mapped[0]=par[0];
```

### 9.5 `map_val_20_to_34` / `map_val_34_to_20`（H 系数值映射，float）

`map_val_20_to_34`：与 9.4 结构相同，但 `par_mapped[4]=(par[2]+par[3])*0.5f`、`par_mapped[1]=(par[0]+par[1])*0.5f`（`AAC_HALF_SUM`），且原地操作（`par[33]=par[19]` 等按从高到低的顺序赋值——高位先写，避免覆盖低索引未读值；**顺序敏感，必须从 33 递减**）。

`map_val_34_to_20`（float 分支）：

```c
par[0] = (2*par[0] + par[1]) * 0.33333333f;
par[1] = (par[1] + 2*par[2]) * 0.33333333f;
par[2] = (2*par[3] + par[4]) * 0.33333333f;
par[3] = (par[4] + 2*par[5]) * 0.33333333f;
par[4] = (par[6] + par[7]) * 0.5f;   par[5] = (par[8] + par[9]) * 0.5f;
par[6] = par[10];                    par[7] = par[11];
par[8] = (par[12] + par[13]) * 0.5f; par[9] = (par[14] + par[15]) * 0.5f;
par[10] = par[16];  par[11] = par[17];  par[12] = par[18];  par[13] = par[19];
par[14] = (par[20]+par[21]) * 0.5f;  par[15] = (par[22]+par[23]) * 0.5f;
par[16] = (par[24]+par[25]) * 0.5f;  par[17] = (par[26]+par[27]) * 0.5f;
par[18] = (par[28]+par[29]+par[30]+par[31]) * 0.25f;
par[19] = (par[32]+par[33]) * 0.5f;
// 顺序敏感：从低到高覆盖，par[0..3] 用旧 par[1..5]；par[4..] 用旧 par[6..]
```

**注意**：两个 `map_val_*` 是原地 H 系数（float）重排，与 `map_idx_*`（int8 参数索引）不同，索引/值域不一样，不要混用。

---

## 10. 跨帧状态与生命周期（供 Zig 结构设计）

**PSContext 持久状态**（必须跨帧保留，`aacps.h:71-89`）：

| 字段 | 尺寸 | 何时修改 |
|---|---|---|
| `common`（PSCommonContext） | — | 每帧 ff_ps_read_data 覆盖 |
| `in_buf[5][44][2]` | 混合分析环形缓冲 | ff_ps_apply 的 hybrid_analysis（移位 6 槽） |
| `delay[91][46][2]` | 去相关延迟线 | decorrelation（每带移位 14+32）/ ff_ps_apply 顶部清零 |
| `ap_delay[50][3][37][2]` | 全通延迟线 | decorrelation（5 元素移位 + 逐时隙写） |
| `peak_decay_nrg[34]` | 峰值衰减能量 | decorrelation 瞬态检测 |
| `power_smooth[34]` | 平滑功率 | decorrelation |
| `peak_decay_diff_smooth[34]` | 差值平滑 | decorrelation |
| `H11..H22[2][6][34]` | H 矩阵 | stereo_processing（[0] 槽 + 每 env 一槽） |
| `Lbuf/Rbuf[91][32][2]` | 子子带工作缓冲 | ff_ps_apply 内 |
| `opd_hist/ipd_hist[34]` | 相位平滑历史 | stereo_processing |

**带宽切换（is34bands 变化）复位**：
- decorrelation：清 `peak_decay_nrg/power_smooth/peak_decay_diff_smooth/delay/ap_delay`。
- stereo_processing：对 H 的 [0] 槽做 `map_val_*` 值映射 + `ipdopd_reset`（清 hist）。
- 检测条件：`is34 != common.is34bands_old`（decorrelation）与 `!is34bands_old` / `is34bands_old`（stereo_processing 两侧，等价的带宽切换判定）。

**初始化顺序**（每解码器一次）：
```c
ff_ps_init_common();   // 构建 10 张 VLC 表（全局，只一次）
ff_ps_init();          // ps_tableinit()：生成全部浮点表（全局，只一次）
ff_ps_ctx_init(&ps);   // → ff_psdsp_init(&ps->dsp)：注册 8 个 DSP 函数
```

---

## 11. Zig 移植注意点补充（承接原文档 §11）

1. **表生成**：`ps_tableinit()` 四块全部在 Zig 初始化期执行（`std.math.cos/sin/atan2/hypot/sqrt`）。注意 `f_center` 用 `f64` 中间量、结果转 `f32`；块 D 的 `theta` 为负。
2. **`map_val_20_to_34` 顺序敏感**：从索引 33 向低写；`map_val_34_to_20` 从低向高写，先读后写。Zig 中若用切片覆盖需显式保持相同求值顺序（避免编译器重排读旧值）。
3. **平面别名**：`hybrid4_8_12_cx` 的 `out[0][i+32*j]` 平面技巧在 Zig 里不需要，直接写 `out[j][i]`。
4. **`H*[1][e+1][b]` 跨带残留**：`b >= NR_IPDOPD_BANDS` 时不写虚部层，但插值读所有 b 的虚部——Zig 的 H 数组必须初始化为 0 且永不显式清零（首帧 `b>=17` 读 0，行为一致）。
5. **decorrelate 的 `ap_delay` 回读错位**：读 `[n+2-m]`、写 `[n+5]`，链路间还有串行级联（同 n 内 m 递增）。逐位移植时保持内层 m 循环与写回顺序。
6. **VLC 构建**：复刻 `ff_vlc_init_from_lengths` + `build_table`（约 60 行）；注意 `build_table` 递归内就地改写 `codes[i].bits/.code`，子表 `sym=子表基址`、`len=-子表位宽`；未填充项 `{−1, 0}`。
7. **位读取**：MSB-first；`get_bits(n)` 读 n 位无符号；`ff_ps_read_data` 在 gb 副本上解析，成功后 `skip_bits_long` 推进宿主。
8. **浮点**：无需位精确（除非要求与参考解码器逐位一致）；C 的 `UINTFLOAT` 强制转换在 float 下无操作，可忽略。
9. **验证**：对照 `ff_k_to_i_20/34`、`aacps_huff_tabs` 数值逐条核验；H_LUT 行索引恒为 `iid+7+23*iid_quant ∈ [0,46)`。

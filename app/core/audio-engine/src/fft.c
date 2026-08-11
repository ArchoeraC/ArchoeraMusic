/**
 * fft.c — 频谱分析
 *
 * 自实现 Cooley-Tukey 基 2 FFT，无外部依赖。
 * 功能：
 *   - O(n log n) 快速傅里叶变换
 *   - Hann 窗函数
 *   - 频谱平滑（指数移动平均）
 *   - 对数刻度（dB）转换
 *   - 频段聚合（任意输出频段数）
 *   - 峰值保持 + 衰减
 *   - 自适应多声道（1~6ch，含 5.1）：输入按声道数自动下混为左右声道，
 *     频谱输出保持立体声兼容（ldata/rdata）
 */
#include "fft.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define LOG_TAG "[audio-engine:fft]"
#include <stdio.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* 默认参数 */
#define DEFAULT_SMOOTHING 0.0f    /* 无平滑 */
#define DEFAULT_PEAK_DECAY 0.01f  /* 每帧衰减 1% */
#define MIN_DB -120.0f            /* dB 下限 */
#define NOISE_FLOOR 0.04f         /* 归一化噪声门限（≈ -52dB）：低于此值
                                    直接置 0，抑制背景噪声/量化毛刺成为
                                    半高 bar，频谱更干净、渲染开销更小 */

struct FFTAnalyzer {
    int sample_rate;
    int fft_size;
    int fft_order;          /* log2(fft_size) */
    bool enabled;

    /* 窗函数 */
    float *window;

    /* 预计算查表（对齐 Electron Rust 端 rustfft 的工程思路：创建时一次
     * 构建，运行时直接查表，避免每帧重算位反转与三角函数递推） */
    int *bitrev;        /* 位反转表（fft_size 项） */
    float *twiddle;     /* 旋转因子表（fft_size/2 对 cos/sin，W_n^k） */

    /* 输入缓冲（左声道） */
    float *input_buf;
    /* 输入缓冲（右声道，立体声模式使用） */
    float *input_buf_r;
    int buf_pos;

    /* FFT 工作区 */
    float *fft_real;
    float *fft_imag;

    /* 频谱数据（左声道） */
    float *spectrum;        /* 线性幅度谱（平滑后） */
    float *raw_spectrum;    /* 原始频谱（未平滑） */
    float *peak_spectrum;   /* 峰值保持谱 */

    /* 频谱数据（右声道） */
    float *spectrum_r;
    float *raw_spectrum_r;
    float *peak_spectrum_r;

    /* 参数 */
    float smoothing;        /* 平滑系数 0~1 */
    float peak_decay;       /* 峰值衰减速度 */

    /* 帧回调：每完成一次频谱计算后调用（供按音频位置推送） */
    fft_frame_cb frame_cb;
    void *frame_cb_user;

    /* 缓冲满（频谱计算）次数：每次消耗 fft_size/2 样本（首次数满消耗 fft_size），
     * 用于样本级精确计算音频位置 */
    long long filled_count;

    /* 节拍检测（封面跟随节奏缩放）：低/中/高频段能量滑动基线 +
     * 冷却帧计数 + 本帧脉冲强度（0~1，拉模式下由 fft_take_beat_strength
     * 取走并清除；无脉冲为 0） */
    float beat_ema_low;
    float beat_ema_mid;
    float beat_ema_high;
    int beat_seed_frames;   /* 基线建立期（前 3 帧只记基线不触发） */
    int beat_cooldown;
    float beat_strength;
};

/* ─── 工具函数 ─────────────────────────────────────────────── */

/* 检查是否为 2 的幂 */
static bool is_power_of_two(int n)
{
    return n > 0 && (n & (n - 1)) == 0;
}

/* 计算 log2(n) */
static int log2_int(int n)
{
    int order = 0;
    while (n > 1) {
        n >>= 1;
        order++;
    }
    return order;
}

/* ─── Cooley-Tukey 基 2 FFT ────────────────────────────────── */

/*
 * 原地计算 FFT（迭代版本，避免递归）
 * 输入：real, imag（长度 size）
 * 输出：real, imag（频域数据）
 *
 * 性能：位反转与旋转因子均预计算查表（bitrev / twiddle，见 fft_create），
 * 每帧只做纯整数查表 + 蝶形复乘，无逐位反转循环、无三角函数/复乘递推
 * （对齐 Electron Rust 端 rustfft 的 SIMD 查表思路；精度优于递推——递推
 * 每次复乘更新因子会累积舍入误差）。
 */
static void compute_fft_inplace(float *real, float *imag,
                                const int *bitrev, const float *twiddle,
                                int size, int order)
{
    /* 位反转置换（查表 O(n)，替代逐位反转 O(n log n)） */
    for (int i = 0; i < size; i++) {
        int j = bitrev[i];
        if (j > i) {
            float tmp = real[i];
            real[i] = real[j];
            real[j] = tmp;
            tmp = imag[i];
            imag[i] = imag[j];
            imag[j] = tmp;
        }
    }

    /* 蝶形运算：块内第 j 个因子的指数 = j * (size/m)，
     * 即 W_m^j = W_size^(j*size/m)，直接查 twiddle 表 */
    for (int stage = 1; stage <= order; stage++) {
        int m = 1 << stage;           /* 子问题大小 */
        int half_m = m >> 1;
        int step = size >> stage;     /* 因子指数步长（size/m） */

        for (int k = 0; k < size; k += m) {
            for (int j = 0; j < half_m; j++) {
                const float *w = twiddle + 2 * (j * step);
                float wr = w[0];
                float wi = w[1];
                int idx1 = k + j;
                int idx2 = k + j + half_m;

                /* 蝶形运算 */
                float tr = wr * real[idx2] - wi * imag[idx2];
                float ti = wr * imag[idx2] + wi * real[idx2];

                real[idx2] = real[idx1] - tr;
                imag[idx2] = imag[idx1] - ti;
                real[idx1] += tr;
                imag[idx1] += ti;
            }
        }
    }
}

/* ─── 频谱处理 ─────────────────────────────────────────────── */

/* 计算幅度谱（归一化到 0~1） */
static void compute_magnitude(const float *real, const float *imag,
                              float *out, int size)
{
    int half = size / 2;
    float scale = 2.0f / size;  /* 归一化因子 */

    for (int i = 0; i < half; i++) {
        float r = real[i];
        float im = imag[i];
        out[i] = sqrtf(r * r + im * im) * scale;
    }
}

/* 指数移动平均平滑 */
static void apply_smoothing(float *spectrum, const float *raw,
                            int size, float alpha)
{
    if (alpha <= 0.0f) {
        memcpy(spectrum, raw, size * sizeof(float));
    } else {
        for (int i = 0; i < size; i++) {
            spectrum[i] = alpha * spectrum[i] + (1.0f - alpha) * raw[i];
        }
    }
}

/* 峰值保持 + 衰减 */
static void update_peak(float *peak, const float *spectrum,
                        int size, float decay)
{
    for (int i = 0; i < size; i++) {
        if (spectrum[i] > peak[i]) {
            peak[i] = spectrum[i];
        } else {
            peak[i] -= decay;
            if (peak[i] < 0.0f) peak[i] = 0.0f;
        }
    }
}

/* 脉冲频段配置（封面跟随节奏缩放）：
 * 低频 = kick 主体（40~150Hz）；中频 = snare/主音泛音（150~2kHz）；
 * 高频 = hihat/电子合成音/打击乐瞬态（2k~10kHz）。
 * trigger_ratio：能量/滑动基线达到该比值视为脉冲起始；peak_ratio：达到
 * 该比值强度记 1.0；weight：综合权重（中高频略低，避免一有能量就乱跳）；
 * use_max：1 = 取频段内最大 bin（瞬态/hat 敏感，避免平均稀释），
 *         0 = 频段平均（kick/snare 能量分散多个 bin）。
 * 参数经真实 mp3 校准（2026-08，西憂花-ふわふわhazy 265s 实测，目标
 * ~130BPM 4-on-floor）：低频收窄至 40~150Hz 保持 kick 命中率，中高频
 * 拓宽脉冲来源（合成音/瞬态也能触发），冷却 2 帧 ≈100ms 防连击同时
 * 允许高频密集瞬态。 */
typedef struct {
    float lo_freq;
    float hi_freq;
    float trigger_ratio;
    float peak_ratio;
    float weight;
    int use_max;
} BeatBand;

static const BeatBand kBeatBands[3] = {
    { 40.0f, 150.0f, 1.3f, 2.2f, 1.0f, 0 },
    { 150.0f, 2000.0f, 1.4f, 2.8f, 0.85f, 0 },
    { 2000.0f, 10000.0f, 1.6f, 3.5f, 0.7f, 1 },
};

static float *beat_ema_of(FFTAnalyzer *fft, int band)
{
    return band == 0 ? &fft->beat_ema_low
         : band == 1 ? &fft->beat_ema_mid
                     : &fft->beat_ema_high;
}

static float beat_band_energy(const FFTAnalyzer *fft, int b0, int b1, int use_max)
{
    float sum = 0.0f, mx = 0.0f;
    for (int i = b0; i < b1; i++) {
        float l = fft->spectrum[i];
        float r = fft->spectrum_r[i];
        float v = l > r ? l : r;
        sum += v;
        if (v > mx) mx = v;
    }
    return use_max ? mx : sum / (float)(b1 - b0);
}

static void detect_beat(FFTAnalyzer *fft, int half)
{
    if (!fft->enabled) return;

    float freq_per_bin = (float)fft->sample_rate / (float)fft->fft_size;

    fft->beat_strength = 0.0f;

    /* 基线建立期：前 3 帧各频段仅记录能量基线，不触发。此后 EMA 永不
     * 重置——瞬态间能量归零时基线自然衰减（×0.85），避免每次脉冲都被
     * 当作「首帧基线」而漏检（曾导致高频段完全不触发）。 */
    if (fft->beat_seed_frames < 3) {
        fft->beat_seed_frames++;
        for (int b = 0; b < 3; b++) {
            const BeatBand *band = &kBeatBands[b];
            int b0 = (int)(band->lo_freq / freq_per_bin);
            int b1 = (int)(band->hi_freq / freq_per_bin);
            if (b0 < 0) b0 = 0;
            if (b1 > half) b1 = half;
            if (b1 <= b0) b1 = b0 + 1;
            *beat_ema_of(fft, b) = beat_band_energy(fft, b0, b1, band->use_max);
        }
        return;
    }

    /* 三频段独立测能量突增，强度取加权最大值（脉冲不只局限于鼓点） */
    float best = 0.0f;
    for (int b = 0; b < 3; b++) {
        const BeatBand *band = &kBeatBands[b];
        int b0 = (int)(band->lo_freq / freq_per_bin);
        int b1 = (int)(band->hi_freq / freq_per_bin);
        if (b0 < 0) b0 = 0;
        if (b1 > half) b1 = half;
        if (b1 <= b0) b1 = b0 + 1;

        float energy = beat_band_energy(fft, b0, b1, band->use_max);
        float *ema = beat_ema_of(fft, b);
        /* 本帧近静音（含频段内瞬态间隙）：不触发，基线仅衰减 */
        if (energy < 1e-3f) {
            *ema *= 0.85f;
            continue;
        }
        /* 基线被长时间静音拖到极低：用当前能量轻量拉回，不触发（防噪声） */
        if (*ema < 1e-4f) {
            *ema = energy * 0.15f;
            continue;
        }
        float ratio = energy / *ema;
        *ema = *ema * 0.85f + energy * 0.15f;

        if (ratio > band->trigger_ratio) {
            float s = (ratio - band->trigger_ratio) /
                      (band->peak_ratio - band->trigger_ratio);
            if (s > 1.0f) s = 1.0f;
            s *= band->weight;
            if (s > best) best = s;
        }
    }
    /* 冷却每帧递减（与是否命中无关）：触发后恰好 2 帧静默期，
     * 之后恢复检测——此前冷却只在命中帧递减，连续静音帧会让冷却
     * 永不解锁，吞掉后续所有脉冲（合成信号验证复现）。 */
    if (fft->beat_cooldown > 0) {
        fft->beat_cooldown--;
        return;
    }
    if (best <= 0.0f) return;
    fft->beat_cooldown = 2; /* ≈100ms（约 50ms/帧），防连击 */
    fft->beat_strength = best;
}

/* ─── 公共 API ─────────────────────────────────────────────── */

FFTAnalyzer* fft_create(int sample_rate, int fft_size)
{
    if (!is_power_of_two(fft_size)) {
        fprintf(stderr, "%s 错误: fft_size 必须是 2 的幂，收到 %d\n",
                LOG_TAG, fft_size);
        return NULL;
    }

    FFTAnalyzer *fft = calloc(1, sizeof(*fft));
    if (!fft) return NULL;

    fft->sample_rate = sample_rate;
    fft->fft_size = fft_size;
    fft->fft_order = log2_int(fft_size);
    fft->enabled = false;
    fft->smoothing = DEFAULT_SMOOTHING;
    fft->peak_decay = DEFAULT_PEAK_DECAY;

    int half = fft_size / 2;

    /* 分配内存 */
    fft->window = malloc(fft_size * sizeof(float));
    fft->bitrev = malloc(fft_size * sizeof(int));
    fft->twiddle = malloc(fft_size * sizeof(float));
    fft->input_buf = malloc(fft_size * sizeof(float));
    fft->input_buf_r = malloc(fft_size * sizeof(float));
    fft->fft_real = malloc(fft_size * sizeof(float));
    fft->fft_imag = malloc(fft_size * sizeof(float));
    fft->spectrum = malloc(half * sizeof(float));
    fft->raw_spectrum = malloc(half * sizeof(float));
    fft->peak_spectrum = malloc(half * sizeof(float));
    fft->spectrum_r = malloc(half * sizeof(float));
    fft->raw_spectrum_r = malloc(half * sizeof(float));
    fft->peak_spectrum_r = malloc(half * sizeof(float));

    if (!fft->window || !fft->bitrev || !fft->twiddle ||
        !fft->input_buf || !fft->input_buf_r ||
        !fft->fft_real || !fft->fft_imag || !fft->spectrum ||
        !fft->raw_spectrum || !fft->peak_spectrum ||
        !fft->spectrum_r || !fft->raw_spectrum_r || !fft->peak_spectrum_r) {
        fft_destroy(fft);
        return NULL;
    }

    /* 初始化 Hamming 窗（对齐 Electron Rust 端 0.54 - 0.46*cos） */
    for (int i = 0; i < fft_size; i++) {
        fft->window[i] = 0.54f - 0.46f * cosf(2.0f * M_PI * i / (fft_size - 1));
    }

    /* 预计算位反转表与旋转因子表（创建一次，每帧直接查表） */
    for (int i = 0; i < fft_size; i++) {
        int j = 0;
        for (int k = 0; k < fft->fft_order; k++) {
            j = (j << 1) | ((i >> k) & 1);
        }
        fft->bitrev[i] = j;
    }
    for (int k = 0; k < half; k++) {
        float angle = -2.0f * M_PI * k / (float)fft_size;
        fft->twiddle[2 * k] = cosf(angle);
        fft->twiddle[2 * k + 1] = sinf(angle);
    }

    /* 初始化峰值谱 */
    memset(fft->peak_spectrum, 0, half * sizeof(float));
    memset(fft->peak_spectrum_r, 0, half * sizeof(float));

    fprintf(stderr, "%s 创建: %dHz / FFT %d 点 (order=%d)\n",
            LOG_TAG, sample_rate, fft_size, fft->fft_order);
    return fft;
}

void fft_set_enabled(FFTAnalyzer *fft, bool enabled)
{
    if (!fft) return;
    fft->enabled = enabled;
}

void fft_set_frame_cb(FFTAnalyzer *fft, fft_frame_cb cb, void *user_data)
{
    if (!fft) return;
    fft->frame_cb = cb;
    fft->frame_cb_user = user_data;
}

/** 已处理音频时间（秒）：第 n 次缓冲满消耗 fft_size + (n-1)*fft_size/2 样本 */
double fft_get_processed_seconds(const FFTAnalyzer *fft)
{
    if (!fft || fft->filled_count <= 0) return 0.0;
    long long half = fft->fft_size / 2;
    long long total = fft->fft_size + (fft->filled_count - 1) * half;
    return (double)total / (double)fft->sample_rate;
}

bool fft_take_beat(FFTAnalyzer *fft)
{
    if (!fft) return false;
    bool hit = fft->beat_strength > 0.0f;
    fft->beat_strength = 0.0f;
    return hit;
}

float fft_take_beat_strength(FFTAnalyzer *fft)
{
    if (!fft) return 0.0f;
    float s = fft->beat_strength;
    fft->beat_strength = 0.0f;
    return s;
}

void fft_set_smoothing(FFTAnalyzer *fft, float alpha)
{
    if (!fft) return;
    if (alpha < 0.0f) alpha = 0.0f;
    if (alpha > 0.99f) alpha = 0.99f;
    fft->smoothing = alpha;
}

void fft_set_peak_decay(FFTAnalyzer *fft, float decay)
{
    if (!fft) return;
    if (decay < 0.0f) decay = 0.0f;
    if (decay > 1.0f) decay = 1.0f;
    fft->peak_decay = decay;
}

void fft_reset_peak(FFTAnalyzer *fft)
{
    if (!fft) return;
    memset(fft->peak_spectrum, 0, (fft->fft_size / 2) * sizeof(float));
    memset(fft->peak_spectrum_r, 0, (fft->fft_size / 2) * sizeof(float));
}

int fft_get_size(const FFTAnalyzer *fft)
{
    return fft ? fft->fft_size : 0;
}

int fft_get_sample_rate(const FFTAnalyzer *fft)
{
    return fft ? fft->sample_rate : 0;
}

/* 对左右输入缓冲执行窗函数 → FFT → 幅度 → 平滑 → 峰值 */
static void process_buffers(FFTAnalyzer *fft, int half)
{
    /* ─── 左声道 FFT ─── */
    for (int j = 0; j < fft->fft_size; j++) {
        fft->fft_real[j] = fft->input_buf[j] * fft->window[j];
        fft->fft_imag[j] = 0.0f;
    }
    compute_fft_inplace(fft->fft_real, fft->fft_imag,
                       fft->bitrev, fft->twiddle,
                       fft->fft_size, fft->fft_order);
    compute_magnitude(fft->fft_real, fft->fft_imag,
                    fft->raw_spectrum, fft->fft_size);

    /* ─── 右声道 FFT ─── */
    for (int j = 0; j < fft->fft_size; j++) {
        fft->fft_real[j] = fft->input_buf_r[j] * fft->window[j];
        fft->fft_imag[j] = 0.0f;
    }
    compute_fft_inplace(fft->fft_real, fft->fft_imag,
                       fft->bitrev, fft->twiddle,
                       fft->fft_size, fft->fft_order);
    compute_magnitude(fft->fft_real, fft->fft_imag,
                    fft->raw_spectrum_r, fft->fft_size);

    /* 左右声道分别平滑 */
    apply_smoothing(fft->spectrum, fft->raw_spectrum,
                  half, fft->smoothing);
    apply_smoothing(fft->spectrum_r, fft->raw_spectrum_r,
                  half, fft->smoothing);

    /* 左右声道分别更新峰值 */
    update_peak(fft->peak_spectrum, fft->spectrum,
               half, fft->peak_decay);
    update_peak(fft->peak_spectrum_r, fft->spectrum_r,
               half, fft->peak_decay);

    /* 节拍检测（封面跟随节奏缩放）：先于帧回调，确保回调触发时标志就绪 */
    detect_beat(fft, half);

    /* 新频谱已就绪：通知订阅者（每缓冲满计算一次即触发一次） */
    if (fft->frame_cb) {
        fft->frame_cb(fft->frame_cb_user, fft->fft_size);
    }
}

void fft_process_multi(FFTAnalyzer *fft, const float *pcm, int samples, int channels)
{
    if (!fft || !pcm || samples <= 0 || channels <= 0) return;
    if (!fft->enabled) return;

    int half = fft->fft_size / 2;
    const float INV_SQRT2 = 0.70710678f; /* 1/sqrt(2)，ITU-R BS.775 下混系数 */

    /* 收集样本：按声道数将交错 PCM 下混为左右声道写入独立缓冲 */
    for (int i = 0; i < samples; i++) {
        if (fft->buf_pos < fft->fft_size) {
            const float *s = pcm + (size_t)i * channels;
            float l, r;

            switch (channels) {
            case 1: /* 单声道：左右相同 */
                l = s[0];
                r = s[0];
                break;
            case 2: /* 立体声 */
                l = s[0];
                r = s[1];
                break;
            case 3: /* L R C */
                l = s[0] + INV_SQRT2 * s[2];
                r = s[1] + INV_SQRT2 * s[2];
                break;
            case 4: /* 四声道：FL FR BL BR */
                l = s[0] + INV_SQRT2 * s[2];
                r = s[1] + INV_SQRT2 * s[3];
                break;
            case 5: /* L R C BL BR */
                l = s[0] + INV_SQRT2 * s[2] + INV_SQRT2 * s[3];
                r = s[1] + INV_SQRT2 * s[2] + INV_SQRT2 * s[4];
                break;
            case 6: /* 5.1：FL FR C LFE BL BR，LFE 不入下混 */
                l = s[0] + INV_SQRT2 * s[2] + INV_SQRT2 * s[4];
                r = s[1] + INV_SQRT2 * s[2] + INV_SQRT2 * s[5];
                break;
            default: /* 超出已知布局：退化为取前两个声道 */
                l = s[0];
                r = channels >= 2 ? s[1] : s[0];
                break;
            }

            fft->input_buf[fft->buf_pos] = l;
            fft->input_buf_r[fft->buf_pos] = r;
            fft->buf_pos++;
        }

        /* 缓冲满时计算 FFT */
        if (fft->buf_pos >= fft->fft_size) {
            fft->filled_count++;
            process_buffers(fft, half);

            /* 清空缓冲，保留一半重叠 */
            int overlap = half;
            memmove(fft->input_buf, fft->input_buf + overlap,
                   overlap * sizeof(float));
            memmove(fft->input_buf_r, fft->input_buf_r + overlap,
                   overlap * sizeof(float));
            fft->buf_pos = overlap;
        }
    }
}

void fft_process(FFTAnalyzer *fft, const float *pcm, int samples)
{
    fft_process_multi(fft, pcm, samples, 1);
}

void fft_process_frame(FFTAnalyzer *fft, const float *l, const float *r, int samples)
{
    if (!fft || !l || !r || samples <= 0) return;
    if (!fft->enabled) return;

    int size = fft->fft_size;
    if (samples > size) samples = size;

    /* 拷贝到输入缓冲（对齐 Rust 端「取最新 fft_size 样本」的窗口语义：
     * 本函数收到的样本即调用方定位的「以当前音频位置为终点的窗口」） */
    memcpy(fft->input_buf, l, samples * sizeof(float));
    memcpy(fft->input_buf_r, r, samples * sizeof(float));
    if (samples < size) {
        memset(fft->input_buf + samples, 0, (size - samples) * sizeof(float));
        memset(fft->input_buf_r + samples, 0, (size - samples) * sizeof(float));
    }

    fft->buf_pos = size;
    fft->filled_count++;
    process_buffers(fft, size / 2);
}

void fft_process_stereo(FFTAnalyzer *fft, const float *pcm, int samples)
{
    fft_process_multi(fft, pcm, samples, 2);
}

void fft_get_spectrum(const FFTAnalyzer *fft, float *out_mag, int bins)
{
    if (!fft || !out_mag || bins <= 0) return;

    int half = fft->fft_size / 2;
    if (bins > half) bins = half;

    /* 线性插值聚合到目标频段数 */
    if (bins == half) {
        memcpy(out_mag, fft->spectrum, half * sizeof(float));
    } else {
        float step = (float)half / bins;
        for (int i = 0; i < bins; i++) {
            float pos = i * step;
            int idx = (int)pos;
            float frac = pos - idx;

            if (idx + 1 < half) {
                out_mag[i] = fft->spectrum[idx] * (1.0f - frac) +
                            fft->spectrum[idx + 1] * frac;
            } else {
                out_mag[i] = fft->spectrum[idx];
            }
        }
    }
}

void fft_get_spectrum_stereo(const FFTAnalyzer *fft,
                              float *out_mag_l, float *out_mag_r, int bins)
{
    if (!fft || !out_mag_l || !out_mag_r || bins <= 0) return;

    int half = fft->fft_size / 2;
    if (bins > half) bins = half;

    /* helper: 线性插值聚合到目标频段数 */
    #define BIN_AGGREGATE(src, dst, n) do { \
        if ((n) == half) { \
            memcpy((dst), (src), half * sizeof(float)); \
        } else { \
            float _step = (float)half / (n); \
            for (int _i = 0; _i < (n); _i++) { \
                float _pos = _i * _step; \
                int _idx = (int)_pos; \
                float _frac = _pos - _idx; \
                if (_idx + 1 < half) { \
                    (dst)[_i] = (src)[_idx] * (1.0f - _frac) + \
                                (src)[_idx + 1] * _frac; \
                } else { \
                    (dst)[_i] = (src)[_idx]; \
                } \
            } \
        } \
    } while(0)

    BIN_AGGREGATE(fft->spectrum, out_mag_l, bins);
    BIN_AGGREGATE(fft->spectrum_r, out_mag_r, bins);

    #undef BIN_AGGREGATE
}

void fft_get_spectrum_db(const FFTAnalyzer *fft, float *out_db,
                         int bins, float min_db)
{
    if (!fft || !out_db || bins <= 0) return;

    int half = fft->fft_size / 2;
    if (bins > half) bins = half;

    /* 先获取线性谱 */
    float *linear = malloc(half * sizeof(float));
    if (!linear) return;

    fft_get_spectrum(fft, linear, bins);

    /* 转换为 dB */
    for (int i = 0; i < bins; i++) {
        float mag = linear[i];
        if (mag < 1e-10f) mag = 1e-10f;  /* 避免 log(0) */
        float db = 20.0f * log10f(mag);
        if (db < min_db) db = min_db;
        out_db[i] = db;
    }

    free(linear);
}

void fft_get_spectrum_db_stereo(const FFTAnalyzer *fft,
                                float *out_db_l, float *out_db_r,
                                int bins, float min_db)
{
    if (!fft || !out_db_l || !out_db_r || bins <= 0) return;

    float *linear_l = malloc(bins * sizeof(float));
    float *linear_r = malloc(bins * sizeof(float));
    if (!linear_l || !linear_r) {
        free(linear_l);
        free(linear_r);
        return;
    }

    fft_get_spectrum_stereo(fft, linear_l, linear_r, bins);

    for (int i = 0; i < bins; i++) {
        float mag_l = linear_l[i];
        float mag_r = linear_r[i];
        if (mag_l < 1e-10f) mag_l = 1e-10f;
        if (mag_r < 1e-10f) mag_r = 1e-10f;
        float db_l = 20.0f * log10f(mag_l);
        float db_r = 20.0f * log10f(mag_r);
        out_db_l[i] = db_l < min_db ? min_db : db_l;
        out_db_r[i] = db_r < min_db ? min_db : db_r;
    }

    free(linear_l);
    free(linear_r);
}

void fft_get_spectrum_norm_stereo(const FFTAnalyzer *fft,
                                  float *out_mag_l, float *out_mag_r, int bins)
{
    if (!fft || !out_mag_l || !out_mag_r || bins <= 0) return;

    /* 未启用或暂无数据：输出全 0（前端渲染为静音） */
    if (!fft->enabled) {
        memset(out_mag_l, 0, bins * sizeof(float));
        memset(out_mag_r, 0, bins * sizeof(float));
        return;
    }

    /* 对数频段范围（对齐 Electron Rust 端） */
    const float MIN_FREQ = 80.0f;
    const float MAX_FREQ = 2000.0f;

    int half = fft->fft_size / 2;
    float freq_per_bin = (float)fft->sample_rate / (float)fft->fft_size;
    int min_bin = (int)floorf(MIN_FREQ / freq_per_bin);
    int max_bin = (int)ceilf(MAX_FREQ / freq_per_bin);
    if (max_bin > half) max_bin = half;
    if (min_bin >= max_bin) {
        memset(out_mag_l, 0, bins * sizeof(float));
        memset(out_mag_r, 0, bins * sizeof(float));
        return;
    }

    float log_min = logf(MIN_FREQ);
    float log_max = logf(MAX_FREQ);

    for (int i = 0; i < bins; i++) {
        float freq_lo = expf(log_min + (log_max - log_min) * (float)i / (float)bins);
        float freq_hi = expf(log_min + (log_max - log_min) * (float)(i + 1) / (float)bins);
        int bin_lo = (int)floorf(freq_lo / freq_per_bin);
        int bin_hi = (int)ceilf(freq_hi / freq_per_bin);
        if (bin_lo < min_bin) bin_lo = min_bin;
        if (bin_hi > max_bin) bin_hi = max_bin;

        float avg_l = 0.0f, avg_r = 0.0f;
        if (bin_lo < bin_hi) {
            /* 段内平均线性幅度（与 Rust 端 norm()/FFT_SIZE 语义一致） */
            float sum_l = 0.0f, sum_r = 0.0f;
            for (int j = bin_lo; j < bin_hi; j++) {
                sum_l += fft->spectrum[j];
                sum_r += fft->spectrum_r[j];
            }
            avg_l = sum_l / (float)(bin_hi - bin_lo);
            avg_r = sum_r / (float)(bin_hi - bin_lo);
        }

        /* dB → 归一化 [0,1]：-60dB 为 0，0dB 为 1；
         * 低于噪声门限的归一化值直接置 0（抑制背景噪声细节） */
        float db_l = 20.0f * log10f(avg_l + 1e-10f);
        float db_r = 20.0f * log10f(avg_r + 1e-10f);
        float norm_l = (db_l + 60.0f) / 60.0f;
        float norm_r = (db_r + 60.0f) / 60.0f;
        out_mag_l[i] = norm_l <= NOISE_FLOOR ? 0.0f : (norm_l >= 1.0f ? 1.0f : norm_l);
        out_mag_r[i] = norm_r <= NOISE_FLOOR ? 0.0f : (norm_r >= 1.0f ? 1.0f : norm_r);
    }
}

void fft_get_peak_spectrum(const FFTAnalyzer *fft, float *out_peak, int bins)
{
    if (!fft || !out_peak || bins <= 0) return;

    int half = fft->fft_size / 2;
    if (bins > half) bins = half;

    /* 线性插值聚合到目标频段数 */
    if (bins == half) {
        memcpy(out_peak, fft->peak_spectrum, half * sizeof(float));
    } else {
        float step = (float)half / bins;
        for (int i = 0; i < bins; i++) {
            float pos = i * step;
            int idx = (int)pos;
            float frac = pos - idx;

            if (idx + 1 < half) {
                out_peak[i] = fft->peak_spectrum[idx] * (1.0f - frac) +
                             fft->peak_spectrum[idx + 1] * frac;
            } else {
                out_peak[i] = fft->peak_spectrum[idx];
            }
        }
    }
}

void fft_get_peak_spectrum_stereo(const FFTAnalyzer *fft,
                                  float *out_peak_l, float *out_peak_r, int bins)
{
    if (!fft || !out_peak_l || !out_peak_r || bins <= 0) return;

    int half = fft->fft_size / 2;
    if (bins > half) bins = half;

    /* 复用 BIN_AGGREGATE 宏（定义在 fft_get_spectrum_stereo 中） */
    #define BIN_AGGREGATE(src, dst, n) do { \
        if ((n) == half) { \
            memcpy((dst), (src), half * sizeof(float)); \
        } else { \
            float _step = (float)half / (n); \
            for (int _i = 0; _i < (n); _i++) { \
                float _pos = _i * _step; \
                int _idx = (int)_pos; \
                float _frac = _pos - _idx; \
                if (_idx + 1 < half) { \
                    (dst)[_i] = (src)[_idx] * (1.0f - _frac) + \
                                (src)[_idx + 1] * _frac; \
                } else { \
                    (dst)[_i] = (src)[_idx]; \
                } \
            } \
        } \
    } while(0)

    BIN_AGGREGATE(fft->peak_spectrum, out_peak_l, bins);
    BIN_AGGREGATE(fft->peak_spectrum_r, out_peak_r, bins);

    #undef BIN_AGGREGATE
}

void fft_destroy(FFTAnalyzer *fft)
{
    if (!fft) return;
    free(fft->window);
    free(fft->bitrev);
    free(fft->twiddle);
    free(fft->input_buf);
    free(fft->input_buf_r);
    free(fft->fft_real);
    free(fft->fft_imag);
    free(fft->spectrum);
    free(fft->raw_spectrum);
    free(fft->peak_spectrum);
    free(fft->spectrum_r);
    free(fft->raw_spectrum_r);
    free(fft->peak_spectrum_r);
    free(fft);
}

// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_fft.h — 基于 FFmpeg libavutil/tx 的频谱分析器（纯计算）
 *
 * 用途：不链接 Zig 内核（HAS_ARCHOERA_KERNEL 未定义）时，纯 FFmpeg 构建的
 * 频谱后端。多分辨率 FFT（4 种窗长）覆盖 40–16kHz / 128 对数带，随后在
 * C 侧完成与 `kernel/dsp/spectrum.zig` 相同的显示增强（AGC / γ / 倾斜 /
 * dB + 软膝 / 峰值保持 / 对数谱通量节拍），保证事件契约不变。
 *
 * 约束：
 *   - 不建线程、不做 I/O；由 `spectrum_service.c` 的频谱线程调用；
 *   - create 时一次建表（窗 / 旋转因子 / band 映射），process 零分配；
 *   - 输入为「最近 frames 个每声道样本」，窗口中心对准当前播放位置
 *     （由 future_samples 指定未来样本数，与 VQT 后端语义一致）。
 */
#ifndef ERA_SPECTRUM_FFT_H
#define ERA_SPECTRUM_FFT_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EraFftSpectrum EraFftSpectrum;

/**
 * 创建分析器。参数同 `zk_dsp_spectrum_create`：
 * sample_rate>0、bins 1..1024、min_hz>0、min_hz<max_hz<sample_rate/2。
 * 非法参数 / OOM 返回 NULL。
 */
EraFftSpectrum *era_fft_spectrum_create(int sample_rate, int bins,
                                        float min_hz, float max_hz);

/** 销毁；NULL 空操作。 */
void era_fft_spectrum_destroy(EraFftSpectrum *s);

/** 清空帧间状态（seek / 切歌 / 会话重建）；核/表保留。 */
void era_fft_spectrum_reset(EraFftSpectrum *s);

/** 峰值保持开关（关闭时清空峰值线）。 */
void era_fft_spectrum_set_peak_hold(EraFftSpectrum *s, bool enabled);

/** 运行时开关 AGC（关闭时增益复位 1.0）。 */
void era_fft_spectrum_set_agc(EraFftSpectrum *s, bool enabled);

/** 运行时设置 γ（<=0 / NaN / Inf 忽略；收敛到 [0.25, 4.0]）。 */
void era_fft_spectrum_set_gamma(EraFftSpectrum *s, float gamma);

/** 运行时设置高频倾斜（NaN/Inf 忽略；收敛到 [-24, 24] dB/oct）。 */
void era_fft_spectrum_set_tilt(EraFftSpectrum *s, float db_per_oct);

/**
 * 处理一帧（窗口居中）。
 * l/r 为最近 frames 个每声道样本；l[frames-1] 对应「当前位置 + future_samples」。
 * out_l/out_r 长度 = bins，写 [0,1]。返回本帧节拍强度 0..1。
 */
float era_fft_spectrum_process_centered(EraFftSpectrum *s,
                                        const float *l, const float *r,
                                        int frames, int future_samples,
                                        float *out_l, float *out_r);

/** 取当前峰值保持线（长度 bins，[0,1]）；NULL 空操作。 */
void era_fft_spectrum_peaks(const EraFftSpectrum *s,
                            float *out_l, float *out_r);

#ifdef __cplusplus
}
#endif

#endif /* ERA_SPECTRUM_FFT_H */

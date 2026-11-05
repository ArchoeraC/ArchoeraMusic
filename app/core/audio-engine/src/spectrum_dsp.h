// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_dsp.h — 频谱分析后端选择层（内部接口）
 *
 * `spectrum_service.c` 只依赖本接口，不知道分析器来自哪里：
 *   - 链接了 Zig 内核（HAS_ARCHOERA_KERNEL）→ `kernel/dsp/spectrum.zig` 的
 *     VQT（`zk_dsp_spectrum_*`）；
 *   - 纯 FFmpeg 构建 → `spectrum_fft.c` 的多分辨率 FFT（libavutil/tx）。
 *
 * CMake 选项 `ARCHOERA_SPECTRUM_ANALYZER=auto|zig|fft` 决定编哪条分支；
 * 两种后端输出同一契约（128 带 [0,1] + 峰值 + 节拍），前端无感。
 */
#ifndef ERA_SPECTRUM_DSP_H
#define ERA_SPECTRUM_DSP_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EraDspSpectrum EraDspSpectrum;

/** 创建分析器（参数同内核/FFT 后端）；失败返回 NULL。 */
EraDspSpectrum *era_dsp_spectrum_create(int sample_rate, int bins,
                                        float min_hz, float max_hz);

/** 销毁；NULL 空操作。 */
void era_dsp_spectrum_destroy(EraDspSpectrum *s);

/** 清空帧间状态（seek / 切歌 / 会话重建）。 */
void era_dsp_spectrum_reset(EraDspSpectrum *s);

/** 峰值保持开关。 */
void era_dsp_spectrum_set_peak_hold(EraDspSpectrum *s, bool enabled);

/** AGC 开关。 */
void era_dsp_spectrum_set_agc(EraDspSpectrum *s, bool enabled);

/** 显示 γ。 */
void era_dsp_spectrum_set_gamma(EraDspSpectrum *s, float gamma);

/** 高频倾斜（dB/oct）。 */
void era_dsp_spectrum_set_tilt(EraDspSpectrum *s, float db_per_oct);

/** 处理一帧（窗口居中）；返回节拍强度 0..1。 */
float era_dsp_spectrum_process_centered(EraDspSpectrum *s,
                                        const float *l, const float *r,
                                        int frames, int future_samples,
                                        float *out_l, float *out_r);

/** 取峰值保持线（长度 bins）。 */
void era_dsp_spectrum_peaks(const EraDspSpectrum *s,
                            float *out_l, float *out_r);

/** 当前后端名（日志/诊断用）："zig-vqt" / "ffmpeg-fft"。 */
const char *era_dsp_spectrum_backend(void);

#ifdef __cplusplus
}
#endif

#endif /* ERA_SPECTRUM_DSP_H */

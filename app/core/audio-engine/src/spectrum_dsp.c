// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * spectrum_dsp.c — 频谱分析后端选择（Zig VQT / FFmpeg FFT）
 *
 * 编译期二选一（CMake `ARCHOERA_SPECTRUM_ANALYZER`）：
 *   - Zig 内核在场且未显式指定 fft → 转发到 `zk_dsp_spectrum_*`；
 *   - 纯 FFmpeg 构建或显式 `-DARCHOERA_SPECTRUM_ANALYZER=fft` → 转发到
 *     `era_fft_spectrum_*`（libavutil/tx）。
 *
 * 句柄在两条分支下都是不透明指针，服务层（spectrum_service.c）无感知。
 */
#include "spectrum_dsp.h"

#if defined(HAS_ARCHOERA_KERNEL) && !defined(ERA_SPECTRUM_USE_FFT)

#include "kernel_bridge.h"

EraDspSpectrum *era_dsp_spectrum_create(int sample_rate, int bins,
                                        float min_hz, float max_hz)
{
    return (EraDspSpectrum *)zk_dsp_spectrum_create(sample_rate, bins,
                                                    min_hz, max_hz);
}

void era_dsp_spectrum_destroy(EraDspSpectrum *s)
{
    zk_dsp_spectrum_destroy((ZkSpectrum *)s);
}

void era_dsp_spectrum_reset(EraDspSpectrum *s)
{
    zk_dsp_spectrum_reset((ZkSpectrum *)s);
}

void era_dsp_spectrum_set_peak_hold(EraDspSpectrum *s, bool enabled)
{
    zk_dsp_spectrum_set_peak_hold((ZkSpectrum *)s, enabled ? 1 : 0);
}

void era_dsp_spectrum_set_agc(EraDspSpectrum *s, bool enabled)
{
    zk_dsp_spectrum_set_agc((ZkSpectrum *)s, enabled ? 1 : 0);
}

void era_dsp_spectrum_set_gamma(EraDspSpectrum *s, float gamma)
{
    zk_dsp_spectrum_set_gamma((ZkSpectrum *)s, gamma);
}

void era_dsp_spectrum_set_tilt(EraDspSpectrum *s, float db_per_oct)
{
    zk_dsp_spectrum_set_tilt((ZkSpectrum *)s, db_per_oct);
}

float era_dsp_spectrum_process_centered(EraDspSpectrum *s,
                                        const float *l, const float *r,
                                        int frames, int future_samples,
                                        float *out_l, float *out_r)
{
    return zk_dsp_spectrum_process_centered((ZkSpectrum *)s, l, r, frames,
                                            future_samples, out_l, out_r);
}

void era_dsp_spectrum_peaks(const EraDspSpectrum *s, float *out_l, float *out_r)
{
    zk_dsp_spectrum_peaks((const ZkSpectrum *)s, out_l, out_r);
}

const char *era_dsp_spectrum_backend(void)
{
    return "zig-vqt";
}

#else /* 纯 FFmpeg 构建（或显式指定 fft） */

#include "spectrum_fft.h"

EraDspSpectrum *era_dsp_spectrum_create(int sample_rate, int bins,
                                        float min_hz, float max_hz)
{
    return (EraDspSpectrum *)era_fft_spectrum_create(sample_rate, bins,
                                                     min_hz, max_hz);
}

void era_dsp_spectrum_destroy(EraDspSpectrum *s)
{
    era_fft_spectrum_destroy((EraFftSpectrum *)s);
}

void era_dsp_spectrum_reset(EraDspSpectrum *s)
{
    era_fft_spectrum_reset((EraFftSpectrum *)s);
}

void era_dsp_spectrum_set_peak_hold(EraDspSpectrum *s, bool enabled)
{
    era_fft_spectrum_set_peak_hold((EraFftSpectrum *)s, enabled);
}

void era_dsp_spectrum_set_agc(EraDspSpectrum *s, bool enabled)
{
    era_fft_spectrum_set_agc((EraFftSpectrum *)s, enabled);
}

void era_dsp_spectrum_set_gamma(EraDspSpectrum *s, float gamma)
{
    era_fft_spectrum_set_gamma((EraFftSpectrum *)s, gamma);
}

void era_dsp_spectrum_set_tilt(EraDspSpectrum *s, float db_per_oct)
{
    era_fft_spectrum_set_tilt((EraFftSpectrum *)s, db_per_oct);
}

float era_dsp_spectrum_process_centered(EraDspSpectrum *s,
                                        const float *l, const float *r,
                                        int frames, int future_samples,
                                        float *out_l, float *out_r)
{
    return era_fft_spectrum_process_centered((EraFftSpectrum *)s, l, r, frames,
                                             future_samples, out_l, out_r);
}

void era_dsp_spectrum_peaks(const EraDspSpectrum *s, float *out_l, float *out_r)
{
    era_fft_spectrum_peaks((const EraFftSpectrum *)s, out_l, out_r);
}

const char *era_dsp_spectrum_backend(void)
{
    return "ffmpeg-fft";
}

#endif

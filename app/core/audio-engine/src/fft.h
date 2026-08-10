/**
 * fft.h — 频谱分析（用于前端可视化）
 *
 * 自实现 Cooley-Tukey 基 2 FFT，无外部依赖。
 * 支持：
 *   - 任意 2 的幂次 FFT 点数
 *   - Hann 窗函数
 *   - 频谱平滑（指数移动平均）
 *   - 对数刻度（dB）
 *   - 频段聚合（任意输出频段数）
 *   - 峰值保持 + 衰减
 */
#ifndef FFT_H
#define FFT_H

#include <stdbool.h>

typedef struct FFTAnalyzer FFTAnalyzer;

/**
 * 创建 FFT 分析器实例
 *
 * @param sample_rate  采样率（Hz）
 * @param fft_size     FFT 点数（必须是 2 的幂，如 1024, 2048, 4096）
 * @return 实例，失败返回 NULL
 */
FFTAnalyzer* fft_create(int sample_rate, int fft_size);

/**
 * 启用/禁用 FFT 分析
 *
 * @param fft     实例
 * @param enabled 是否启用
 */
void fft_set_enabled(FFTAnalyzer *fft, bool enabled);

/**
 * 处理 PCM 数据（提取频谱，单声道，左右频谱相同）
 *
 * @param fft     实例
 * @param pcm     交错 float PCM 数据（每帧 1 个样本）
 * @param samples 样本数（每声道）
 */
void fft_process(FFTAnalyzer *fft, const float *pcm, int samples);

/**
 * 处理 PCM 数据（提取立体声频谱，左右声道独立分析）
 *
 * @param fft     实例
 * @param pcm     交错 float PCM 数据（L R L R ...）
 * @param samples 样本数（每声道）
 */
void fft_process_stereo(FFTAnalyzer *fft, const float *pcm, int samples);

/**
 * 处理 PCM 数据（自适应声道数，频谱输出保持立体声兼容）
 *
 * 对交错 float PCM 按声道数（1~6）自动下混为左右声道后再分析，
 * 频谱输出格式与立体声一致（ldata/rdata）。声道布局遵循 FFmpeg 默认布局：
 *   1ch  单声道        L = R = s0
 *   2ch  立体声        L = s0, R = s1
 *   3ch  L R C         L = s0 + 0.7071*C, R = s1 + 0.7071*C
 *   4ch  四声道        L = s0 + 0.7071*BL, R = s1 + 0.7071*BR
 *   5ch  L R C BL BR   L = s0 + 0.7071*C + 0.7071*BL, R = s1 + 0.7071*C + 0.7071*BR
 *   6ch  5.1          L = s0 + 0.7071*C + 0.7071*BL, R = s1 + 0.7071*C + 0.7071*BR（LFE 不入下混）
 *
 * @param fft      实例
 * @param pcm      交错 float PCM 数据（L R C LFE BL BR ...）
 * @param samples  样本数（每声道）
 * @param channels 声道数（1~6，超出范围时退化为取前两个声道）
 */
void fft_process_multi(FFTAnalyzer *fft, const float *pcm, int samples, int channels);

/**
 * 直接对给定左右声道样本计算一帧频谱（不做流式累积，拉模式用）
 *
 * 与 fft_process_multi（播放线程持续喂样本、缓冲满才出帧）不同，
 * 本函数立即对传入的样本加窗 → FFT → 幅度 → 平滑 → 峰值，结果可经
 * fft_get_spectrum_norm_stereo 读取。语义对齐 Electron Rust 端 analyze()：
 * 「以当前音频位置为终点的最近 fft_size 个样本」直接算一帧。
 *
 * 调用方需自行保证 l/r 为每声道样本（已按源声道布局下混）。
 * samples ≤ fft_size；不足 fft_size 时尾部补零。
 *
 * @param fft     实例
 * @param l       左声道样本（每声道样本数 = samples）
 * @param r       右声道样本（每声道样本数 = samples）
 * @param samples 每声道样本数（≤ fft_size）
 */
void fft_process_frame(FFTAnalyzer *fft, const float *l, const float *r, int samples);

/**
 * 获取线性幅度谱（单声道）
 *
 * @param fft       实例
 * @param out_mag   输出幅度谱（线性，0~1），至少 bins 个元素
 * @param bins      请求的频段数
 */
void fft_get_spectrum(const FFTAnalyzer *fft, float *out_mag, int bins);

/**
 * 获取立体声线性幅度谱（左右声道独立）
 *
 * @param fft         实例
 * @param out_mag_l   输出左声道幅度谱，至少 bins 个元素
 * @param out_mag_r   输出右声道幅度谱，至少 bins 个元素
 * @param bins        请求的频段数
 */
void fft_get_spectrum_stereo(const FFTAnalyzer *fft,
                             float *out_mag_l, float *out_mag_r, int bins);

/**
 * 获取对数频谱（dB，单声道）
 *
 * @param fft       实例
 * @param out_db    输出 dB 值（通常 -60~0），至少 bins 个元素
 * @param bins      请求的频段数
 * @param min_db    最小 dB 值（低于此值截断），如 -60.0f
 */
void fft_get_spectrum_db(const FFTAnalyzer *fft, float *out_db, int bins, float min_db);

/**
 * 获取立体声对数频谱（dB，左右声道独立）
 *
 * @param fft         实例
 * @param out_db_l    输出左声道 dB 值，至少 bins 个元素
 * @param out_db_r    输出右声道 dB 值，至少 bins 个元素
 * @param bins        请求的频段数
 * @param min_db      最小 dB 值
 */
void fft_get_spectrum_db_stereo(const FFTAnalyzer *fft,
                                float *out_db_l, float *out_db_r,
                                int bins, float min_db);

/**
 * 获取归一化立体声频谱（前端渲染契约，对齐 Electron Rust 端 analyze()）
 *
 * 对数频段映射（80~2000Hz，与前端渲染一致）→ 段内平均幅度 → dB →
 * (dB + 60) / 60 归一化到 [0, 1]（-60dB 为 0，0dB 为 1）。
 *
 * @param fft         实例
 * @param out_mag_l   输出左声道归一化谱（[0,1]），至少 bins 个元素
 * @param out_mag_r   输出右声道归一化谱（[0,1]），至少 bins 个元素
 * @param bins        请求的频段数（前端固定 128）
 */
void fft_get_spectrum_norm_stereo(const FFTAnalyzer *fft,
                                  float *out_mag_l, float *out_mag_r, int bins);

/**
 * 获取峰值保持谱（单声道）
 *
 * @param fft       实例
 * @param out_peak  输出峰值谱（线性，0~1），至少 bins 个元素
 * @param bins      请求的频段数
 */
void fft_get_peak_spectrum(const FFTAnalyzer *fft, float *out_peak, int bins);

/**
 * 获取立体声峰值保持谱（左右声道独立）
 *
 * @param fft           实例
 * @param out_peak_l    输出左声道峰值谱，至少 bins 个元素
 * @param out_peak_r    输出右声道峰值谱，至少 bins 个元素
 * @param bins          请求的频段数
 */
void fft_get_peak_spectrum_stereo(const FFTAnalyzer *fft,
                                  float *out_peak_l, float *out_peak_r, int bins);

/**
 * 重置峰值保持（左右声道同时重置）
 */
void fft_reset_peak(FFTAnalyzer *fft);

/**
 * 设置平滑系数
 *
 * @param fft       实例
 * @param alpha     平滑系数（0~1），越大越平滑，0.8 为常用值
 */
void fft_set_smoothing(FFTAnalyzer *fft, float alpha);

/**
 * 设置峰值衰减速度
 *
 * @param fft       实例
 * @param decay     每帧衰减量（0~1），如 0.01f
 */
void fft_set_peak_decay(FFTAnalyzer *fft, float decay);

/**
 * 获取 FFT 点数
 */
int fft_get_size(const FFTAnalyzer *fft);

/**
 * 获取采样率
 */
int fft_get_sample_rate(const FFTAnalyzer *fft);

/**
 * 获取已处理音频时间（秒）
 *
 * 基于每声道样本计数，粒度 = 缓冲满间隔（≈ fft_size/2 样本），
 * 比管线 position（帧粒度）更细，用于按音频位置驱动频谱推送。
 */
double fft_get_processed_seconds(const FFTAnalyzer *fft);

/**
 * 取走本帧脉冲命中标志（并清除）
 *
 * 封面跟随节奏缩放：C 侧在每帧频谱计算时检测低频（kick 40~150Hz）、
 * 中频（snare/主音 150~2kHz）、高频（hihat/合成音 2k~10kHz）三个频段
 * 的能量突增（相对各自滑动基线），任一命中即置位。本函数取走标志供
 * 前端消费（拉模式每帧调用一次）；未启用 / 无数据 / 未命中时返回 false。
 *
 * @param fft 实例
 * @return 上一帧是否有脉冲
 */
bool fft_take_beat(FFTAnalyzer *fft);

/**
 * 取走本帧脉冲强度（0~1，并清除）
 *
 * 强度 = 三频段能量突增幅度的加权最大值（突增越猛越接近 1），不仅限于
 * 鼓点——高频电子合成音/打击乐瞬态同样贡献。前端据此区分脉冲大小：
 * 弱脉冲轻微缩放、强脉冲大幅缩放。
 *
 * @param fft 实例
 * @return 上一帧脉冲强度（0~1；无命中为 0）
 */
float fft_take_beat_strength(FFTAnalyzer *fft);

/**
 * 每完成一帧 FFT 频谱计算后的回调（新频谱已就绪，可读取）
 *
 * 触发时机：fft_process* 处理过程中输入缓冲满、执行完一次
 * 窗函数 → FFT → 幅度 → 平滑 → 峰值后同步调用。
 * 用于按音频位置推送频谱（转码可快于实时，墙钟驱动不可靠）。
 *
 * @param user_data 注册时传入的用户数据
 * @param fft_size  本次 FFT 点数
 */
typedef void (*fft_frame_cb)(void *user_data, int fft_size);

/**
 * 注册 FFT 帧回调
 *
 * @param fft       实例
 * @param cb        回调（可为 NULL 取消）
 * @param user_data 透传给回调
 */
void fft_set_frame_cb(FFTAnalyzer *fft, fft_frame_cb cb, void *user_data);

/** 销毁实例 */
void fft_destroy(FFTAnalyzer *fft);

#endif /* FFT_H */

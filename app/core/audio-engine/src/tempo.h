/**
 * tempo.h — 变速变调处理器（基于 Rust signalsmith-stretch）
 *
 * 通过 C FFI 调用 Rust audio-tempo 静态库。
 *
 * 参数：
 *   - speed：[0.5, 2.0]，1.0 = 原速
 *   - pitch_semitones：[-12, 12]，0 = 不变调
 *   - pitch_sync：true = 变速保音调（默认）；false = 变速变调
 */
#ifndef TEMPO_H
#define TEMPO_H

#include <stdbool.h>

typedef struct Tempo Tempo;

/** 创建 tempo 处理器 */
Tempo* tempo_create(int sample_rate, int channels);

/** 销毁 */
void tempo_destroy(Tempo *t);

/** 切歌/seek 时清空 FFT 历史 */
void tempo_reset(Tempo *t);

/** 启用/禁用（禁用时 passthrough） */
void tempo_set_enabled(Tempo *t, bool enabled);

/** 设置播放速度 [0.5, 2.0] */
void tempo_set_speed(Tempo *t, float speed);

/** 设置音调偏移（半音）[-12, 12] */
void tempo_set_pitch(Tempo *t, float semitones);

/** 设置音调同步模式 */
void tempo_set_pitch_sync(Tempo *t, bool sync);

/**
 * 处理 PCM 数据
 *
 * @param t           实例
 * @param pcm         输入/输出缓冲区（交错 float PCM，就地修改）
 * @param samples_in  输入采样数（每声道）
 * @param samples_out 输出采样数（每声道），调用者传入的缓冲区容量，返回时更新为实际输出
 * @return 0 成功，<0 错误
 */
int tempo_process(Tempo *t, float *pcm, int *samples_in_out);

/** 是否处于 bypass 状态（速度≈1.0 且音调≈0） */
bool tempo_is_bypass(const Tempo *t);

#endif /* TEMPO_H */

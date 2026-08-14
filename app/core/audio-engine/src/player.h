/**
 * player.h — 自写播放器模块（miniaudio，§10.8 替代 libmpv）
 *
 * 职责：引擎转码完成后加载 OGG 文件（MA_SOUND_FLAG_DECODE 全解码内存，
 * seek 即时）→ ma_engine 输出到系统音频设备（ALSA/PulseAudio/PipeWire/
 * WASAPI/CoreAudio，跨平台）。控制走 stdin JSON 命令（play/pause/seek/
 * set_volume/get_status），位置事件经 player_poll 周期推送。
 *
 * 线程模型：ma_engine 回调在设备线程；player_command/player_poll 由主线程
 * （stdin 命令循环）调用，ma_engine API 内部线程安全。
 */
#ifndef ARCHOERA_PLAYER_H
#define ARCHOERA_PLAYER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlayerCtx PlayerCtx;

/** 引擎事件输出回调（json 行，含 '\0' 结束、无换行） */
typedef void (*player_event_fn)(const char *json_line, void *user_data);

/**
 * 启动播放：加载 OGG → 输出 playing 事件 → 自动播放。
 * 返回 NULL 表示失败（文件不可读 / 无音频设备）。
 */
PlayerCtx *player_start(const char *ogg_path,
                        player_event_fn on_event,
                        void *user_data);

/** 播放控制命令（type: play/pause/set_playing/seek/set_volume/get_status）。
 *  pos_ms/gain 仅在对应命令时使用（set_playing 用 gain!=0 表 playing）。 */
void player_command(PlayerCtx *p, const char *type,
                    const double *pos_ms, const double *gain);

/** 设置位置事件推送间隔（ms，降频协商）。<20ms 时钳制为 20ms。 */
void player_set_position_interval(PlayerCtx *p, int interval_ms);

/** 播放循环节拍：按音频位置周期推送 position 事件；播放自然结束返回 1。 */
int player_poll(PlayerCtx *p);

/** 停止并释放（停止播放 + 卸载 engine）。 */
void player_stop(PlayerCtx *p);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_PLAYER_H */

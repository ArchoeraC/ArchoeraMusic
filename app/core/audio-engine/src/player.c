/**
 * player.c — 自写播放器实现（miniaudio，替代 libmpv/media_kit，§10.8）
 *
 * miniaudio v0.11.25（MIT-0/公有领域双许可）单头文件实现：
 *   - MA_SOUND_FLAG_DECODE：OGG 全解码到内存（本地完整转码文件几~几十 MB，
 *     seek 即时跳转，无重解码）
 *   - 输出设备：ALSA/PulseAudio/PipeWire（Linux）、WASAPI（Windows）、
 *     CoreAudio（macOS），跨平台零系统依赖
 * 位置事件按音频位置驱动（每 50ms 音频 1 帧，对齐 FFT 拉模式 50ms 轮询：
 * 若保持 100ms，Dart _pollSpectrum 两次读到同一 position，FFT 窗口实际
 * 每 100ms 才前进一次（10Hz），节拍检测命中率会掉 ~40%（实测 127→74/min）。
 */
#define _POSIX_C_SOURCE 200809L

#include "player.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 单头文件实现仅编译一次（player.c 内） */
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

/* 位置事件推送间隔（音频秒）：50ms 对齐 FFT 拉模式轮询（20Hz 分析） */
#define POSITION_INTERVAL_MS 50

struct PlayerCtx {
    ma_engine engine;
    ma_sound sound;
    int has_sound;
    int playing;
    double duration_ms;
    ma_uint64 sample_rate;
    ma_uint64 last_pos_frame;
    int ended_reported;
    int poll_count;
    /* seek 保护窗口：seek 后游标可能滞后/短暂回退（音频线程未同步），
       pending 期间不推送位置事件，避免旧游标值把 UI 刷回原进度 */
    int seek_pending;
    ma_uint64 seek_target_frame;
    int seek_poll_count;
    player_event_fn on_event;
    void *user_data;
};

/* 播放自然结束回调（设备线程） */
static void on_sound_end(void *p_user_data, ma_sound *p_sound)
{
    (void)p_sound;
    PlayerCtx *p = (PlayerCtx *)p_user_data;
    if (!p) return;
    p->playing = 0;
    p->ended_reported = 1;
}

PlayerCtx *player_start(const char *ogg_path,
                        player_event_fn on_event,
                        void *user_data)
{
    ma_result r;
    PlayerCtx *p = (PlayerCtx *)calloc(1, sizeof(PlayerCtx));
    if (!p) return NULL;
    p->on_event = on_event;
    p->user_data = user_data;

    /* 默认设备（ALSA/Pulse/PipeWire 自动选择）。headless 无设备时失败。 */
    r = ma_engine_init(NULL, &p->engine);
    if (r != MA_SUCCESS) {
        fprintf(stderr, "[player] ma_engine_init 失败: %d\n", (int)r);
        free(p);
        return NULL;
    }

    /* 全解码模式：seek 即时；无需实时解码线程 */
    r = ma_sound_init_from_file(&p->engine, ogg_path,
                                MA_SOUND_FLAG_DECODE, NULL, NULL, &p->sound);
    if (r != MA_SUCCESS) {
        fprintf(stderr, "[player] 加载 %s 失败: %d\n", ogg_path, (int)r);
        ma_engine_uninit(&p->engine);
        free(p);
        return NULL;
    }
    p->has_sound = 1;
    ma_sound_set_end_callback(&p->sound, on_sound_end, p);

    ma_format fmt;
    ma_uint32 channels = 0;
    ma_uint32 sample_rate = 0;
    if (ma_sound_get_data_format(&p->sound, &fmt, &channels, &sample_rate,
                                 NULL, 0) == MA_SUCCESS) {
        p->sample_rate = sample_rate;
    }
    ma_uint64 len_frames = 0;
    if (p->sample_rate > 0 &&
        ma_sound_get_length_in_pcm_frames(&p->sound, &len_frames) == MA_SUCCESS) {
        p->duration_ms = (double)len_frames * 1000.0 / (double)p->sample_rate;
    }

    /* playing 事件：完整时长就绪，Flutter 回填 + 开始显示播放状态 */
    if (p->on_event) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"playing\",\"duration_ms\":%.0f}", p->duration_ms);
        p->on_event(buf, p->user_data);
    }

    ma_sound_start(&p->sound);
    p->playing = 1;
    return p;
}

void player_command(PlayerCtx *p, const char *type,
                    const double *pos_ms, const double *gain)
{
    if (!p || !p->has_sound) return;

    if (strcmp(type, "play") == 0) {
        ma_sound_start(&p->sound);
        p->playing = 1;
    } else if (strcmp(type, "pause") == 0) {
        ma_sound_stop(&p->sound);
        p->playing = 0;
    } else if (strcmp(type, "set_playing") == 0 && gain) {
        if (*gain != 0.0) {
            ma_sound_start(&p->sound);
            p->playing = 1;
        } else {
            ma_sound_stop(&p->sound);
            p->playing = 0;
        }
    } else if (strcmp(type, "seek") == 0 && pos_ms && p->sample_rate > 0) {
        ma_uint64 frame =
            (ma_uint64)(*pos_ms / 1000.0 * (double)p->sample_rate);
        ma_sound_seek_to_pcm_frame(&p->sound, frame);
        p->last_pos_frame = frame;
        /* 开启保护窗口：游标同步期间不推送位置事件（防旧值刷回 UI） */
        p->seek_pending = 1;
        p->seek_target_frame = frame;
        p->seek_poll_count = 0;
        /* 立即确认：以 seek 目标值推送一次 position，Dart 立即回填新位置，
           不会先闪回原进度再跳转 */
        if (p->on_event) {
            char buf[128];
            snprintf(buf, sizeof(buf),
                     "{\"type\":\"position\",\"position_ms\":%.0f}", *pos_ms);
            p->on_event(buf, p->user_data);
        }
    } else if (strcmp(type, "set_volume") == 0 && gain) {
        ma_sound_set_volume(&p->sound, (float)*gain);
    } else if (strcmp(type, "get_status") == 0) {
        ma_uint64 cur = 0;
        if (ma_sound_get_cursor_in_pcm_frames(&p->sound, &cur) != MA_SUCCESS) {
            cur = 0;
        }
        double ms = p->sample_rate > 0
            ? (double)cur * 1000.0 / (double)p->sample_rate : 0.0;
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "{\"type\":\"status\",\"position_ms\":%.0f,"
                 "\"duration_ms\":%.0f,\"playing\":%s}",
                 ms, p->duration_ms, p->playing ? "true" : "false");
        p->on_event(buf, p->user_data);
    }
}

int player_poll(PlayerCtx *p)
{
    if (!p || !p->has_sound) return 0;

    /* 位置事件：按音频位置驱动（每 POSITION_INTERVAL_MS 音频 1 帧） */
    if (p->playing && p->sample_rate > 0) {
        ma_uint64 cur = 0;
        if (ma_sound_get_cursor_in_pcm_frames(&p->sound, &cur) == MA_SUCCESS) {
            ma_uint64 step = p->sample_rate / (1000 / POSITION_INTERVAL_MS);
            if (step == 0) step = 1;
            if (p->seek_pending) {
                /* 等待游标进入目标区域（±400ms）后解除保护；期间不推送，
                   防止 seek 前旧游标值把 UI 刷回原进度。seek 到末尾附近时
                   游标可能停在 duration 前，超时兜底强制解除 */
                if (cur >= p->seek_target_frame &&
                    cur <= p->seek_target_frame + step * 4) {
                    p->seek_pending = 0;
                    p->last_pos_frame = cur;
                } else if (++p->seek_poll_count > 60) {
                    p->seek_pending = 0;
                    p->last_pos_frame = cur;
                }
            } else if (cur >= p->last_pos_frame + step) {
                p->last_pos_frame = cur;
                double ms = (double)cur * 1000.0 / (double)p->sample_rate;
                char buf[128];
                snprintf(buf, sizeof(buf),
                         "{\"type\":\"position\",\"position_ms\":%.0f}", ms);
                p->on_event(buf, p->user_data);
            }
        }
    }

    /* 自然结束事件（只报一次） */
    if (p->ended_reported) {
        p->ended_reported = 0;
        if (p->on_event) p->on_event("{\"type\":\"player:ended\"}", p->user_data);
        return 1;
    }
    return 0;
}

void player_stop(PlayerCtx *p)
{
    if (!p) return;
    if (p->has_sound) {
        ma_sound_stop(&p->sound);
        ma_sound_uninit(&p->sound);
        p->has_sound = 0;
    }
    ma_engine_uninit(&p->engine);
    free(p);
}

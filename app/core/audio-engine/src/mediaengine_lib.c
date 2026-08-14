/**
 * mediaengine_lib.c — 音频引擎 FFI 库实现（Dart 桌面端直连，替代进程 IPC）
 *
 * 引擎线程复制 main.c run_interactive 的交互逻辑，数据源参数化：
 *   stdin 命令  → 命令 FIFO（archoera_mediaengine_command）
 *   control 事件 → 事件 FIFO（archoera_mediaengine_poll_event）
 *   PCM UDS 发送 → 会话目录文件直写（stream.pcm / stream.wav）
 *
 * Web/CLI（main.c）路径不受影响。本文件为独立单元，与 main.c 无静态依赖。
 */
#define _DEFAULT_SOURCE /* strdup 等 POSIX 函数（-std=c11 严格模式） */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#include "audio_engine.h"
#include "player.h"
#include "archoera_mediaengine.h"

/* ── 队列容量 ────────────────────────────────────────────────── */
#define EV_CAP 512      /* 事件队列条数 */
#define EV_LINE 511     /* 事件行上限 */
#define CMD_CAP 256     /* 命令队列条数 */
#define CMD_LINE 4095   /* 命令行上限 */

typedef struct ArchoeraMediaEngine {
    char *source;
    EngineConfig cfg;
    char *player_file;
    char *session_dir;
    char *wav_file;
    char *pcm_file;

    pthread_t thread;
    int thread_created;
    volatile int stop_requested;
    volatile int done;      /* 引擎线程已退出 */

    /* 事件 FIFO */
    pthread_mutex_t ev_mutex;
    char ev_buf[EV_CAP][EV_LINE + 1];
    int ev_head, ev_tail, ev_count;

    /* 命令 FIFO */
    pthread_mutex_t cmd_mutex;
    pthread_cond_t cmd_cond;
    char cmd_buf[CMD_CAP][CMD_LINE + 1];
    int cmd_head, cmd_tail, cmd_count;

    /* 引擎线程内部状态 */
    AudioPipeline *p;
    PlayerCtx *player;
    FILE *wav;
    FILE *pcm;

    /* 转码期间的待执行 seek：player 未启动时记录，播放器启动后应用。
       修复「转码/加载阶段拖动进度条不跳转」：seek 命令不再被静默丢弃 */
    int seek_pending;
    double pending_seek_ms;

    /* 降频协商的位置事件间隔（ms；0 = 未协商，播放器用默认 50ms）：
       player 启动前协商则记录于此，播放器启动后立即应用 */
    int pos_interval_ms;
} ArchoeraMediaEngine;

/* ── 事件/命令队列 ───────────────────────────────────────────── */

static void ev_enqueue(ArchoeraMediaEngine *e, const char *line)
{
    pthread_mutex_lock(&e->ev_mutex);
    /* position 事件「只保留最新」合并：队列已有 position 时覆盖最后一条
       而非追加——恢复 50ms 前若理论上有积压（降频期不消费），从源头消除
       突发与 FIFO 溢出（EV_CAP 512 有界）。语义：position 绝对值，最新有义 */
    if (strncmp(line, "{\"type\":\"position\"", 18) == 0) {
        for (int i = e->ev_count - 1; i >= 0; i--) {
            int idx = (e->ev_head + i) % EV_CAP;
            if (strncmp(e->ev_buf[idx], "{\"type\":\"position\"", 18) == 0) {
                strncpy(e->ev_buf[idx], line, EV_LINE);
                e->ev_buf[idx][EV_LINE] = '\0';
                pthread_mutex_unlock(&e->ev_mutex);
                return;
            }
        }
    }
    if (e->ev_count < EV_CAP) {
        strncpy(e->ev_buf[e->ev_tail], line, EV_LINE);
        e->ev_buf[e->ev_tail][EV_LINE] = '\0';
        e->ev_tail = (e->ev_tail + 1) % EV_CAP;
        e->ev_count++;
    }
    pthread_mutex_unlock(&e->ev_mutex);
}

static int cmd_enqueue(ArchoeraMediaEngine *e, const char *line)
{
    int r = -1;
    pthread_mutex_lock(&e->cmd_mutex);
    if (e->cmd_count < CMD_CAP) {
        strncpy(e->cmd_buf[e->cmd_tail], line, CMD_LINE);
        e->cmd_buf[e->cmd_tail][CMD_LINE] = '\0';
        e->cmd_tail = (e->cmd_tail + 1) % CMD_CAP;
        e->cmd_count++;
        r = 0;
    }
    pthread_cond_signal(&e->cmd_cond);
    pthread_mutex_unlock(&e->cmd_mutex);
    return r;
}

/* 非阻塞取一条命令（引擎线程调用）；返回 1 有命令、0 空 */
static int cmd_dequeue(ArchoeraMediaEngine *e, char *buf, int cap)
{
    int r = 0;
    pthread_mutex_lock(&e->cmd_mutex);
    if (e->cmd_count > 0) {
        strncpy(buf, e->cmd_buf[e->cmd_head], cap - 1);
        buf[cap - 1] = '\0';
        e->cmd_head = (e->cmd_head + 1) % CMD_CAP;
        e->cmd_count--;
        r = 1;
    }
    pthread_mutex_unlock(&e->cmd_mutex);
    return r;
}

/* ── 简单 JSON 解析（与 main.c 同协议；控制命令字段） ──────────── */

static const char* skip_ws(const char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    return s;
}

static const char* json_find(const char *json, const char *key)
{
    char search[128];
    int key_len = (int)strlen(key);
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *pos = strstr(json, search);
    if (!pos) return NULL;
    return skip_ws(pos + key_len + 3);
}

static int json_get_string(const char *json, const char *key, char *buf, int bufsize)
{
    const char *val = json_find(json, key);
    if (!val || *val != '"') return -1;
    val++;
    int i = 0;
    while (*val && *val != '"' && i < bufsize - 1) {
        buf[i++] = *val++;
    }
    buf[i] = '\0';
    return i;
}

static int json_get_number(const char *json, const char *key, double *out)
{
    const char *val = json_find(json, key);
    if (!val) return -1;
    char *end;
    *out = strtod(val, &end);
    return (end == val) ? -1 : 0;
}

static int json_get_bool(const char *json, const char *key, bool *out)
{
    const char *val = json_find(json, key);
    if (!val) return -1;
    if (strncmp(val, "true", 4) == 0) { *out = true; return 0; }
    if (strncmp(val, "false", 5) == 0) { *out = false; return 0; }
    return -1;
}

static int json_get_float_array(const char *json, const char *key,
                                float *out, int max_count)
{
    const char *val = json_find(json, key);
    if (!val || *val != '[') return 0;
    val++;
    int count = 0;
    while (*val && *val != ']' && count < max_count) {
        val = skip_ws(val);
        if (*val == ']' || *val == '\0') break;
        char *end;
        out[count++] = strtof(val, &end);
        val = skip_ws(end);
        if (*val == ',') val++;
    }
    return count;
}

/* ── WAV 落盘（float32 IEEE，格式 3；miniaudio dr_wav 解码播放） ── */

static void wav_begin(ArchoeraMediaEngine *e)
{
    e->wav = fopen(e->wav_file, "wb");
    if (!e->wav) return;

    int sample_rate = pipeline_get_output_sample_rate(e->p);
    int channels = e->cfg.output_channels;
    uint16_t block_align = (uint16_t)(channels * 4);
    uint32_t byte_rate = (uint32_t)(sample_rate * channels * 4);
    uint32_t placeholder = 0xFFFFFFFF;

    fwrite("RIFF", 1, 4, e->wav);
    fwrite(&placeholder, 4, 1, e->wav);
    fwrite("WAVEfmt ", 1, 8, e->wav);
    uint32_t fmt_size = 16;
    fwrite(&fmt_size, 4, 1, e->wav);
    uint16_t audio_format = 3;
    fwrite(&audio_format, 2, 1, e->wav);
    uint16_t ch = (uint16_t)channels;
    fwrite(&ch, 2, 1, e->wav);
    uint32_t sr = (uint32_t)sample_rate;
    fwrite(&sr, 4, 1, e->wav);
    fwrite(&byte_rate, 4, 1, e->wav);
    fwrite(&block_align, 2, 1, e->wav);
    uint16_t bits = 32;
    fwrite(&bits, 2, 1, e->wav);
    fwrite("data", 1, 4, e->wav);
    fwrite(&placeholder, 4, 1, e->wav);
}

static void wav_finalize(ArchoeraMediaEngine *e)
{
    if (!e->wav) return;
    long data_size = ftell(e->wav) - 44;
    fseek(e->wav, 40, SEEK_SET);
    uint32_t sz = (uint32_t)data_size;
    fwrite(&sz, 4, 1, e->wav);
    fseek(e->wav, 4, SEEK_SET);
    sz = (uint32_t)(data_size + 36);
    fwrite(&sz, 4, 1, e->wav);
    fclose(e->wav);
    e->wav = NULL;
}

/* PCM 流出回调：WAV 落盘 + PCM 块格式落盘（[pos_ms|samples|channels]+float） */
static void on_pcm_out(const float *pcm, int samples, int channels,
                       double position_ms, void *user_data)
{
    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)user_data;
    if (samples <= 0 || channels <= 0) return;

    if (e->wav) {
        fwrite(pcm, sizeof(float), (size_t)samples * (size_t)channels, e->wav);
    }
    if (e->pcm) {
        int32_t header[3];
        header[0] = (int32_t)position_ms;
        header[1] = (int32_t)samples;
        header[2] = (int32_t)channels;
        fwrite(header, sizeof(header), 1, e->pcm);
        fwrite(pcm, sizeof(float), (size_t)samples * (size_t)channels, e->pcm);
    }
}

/* skip_encoder 时管线无编码输出；非 skip 走丢弃回调（FFI 桌面恒为 player 模式） */
static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

/* 播放器事件 → 事件 FIFO（player_event_fn 签名） */
static void player_event_cb(const char *json, void *user_data)
{
    ev_enqueue((ArchoeraMediaEngine *)user_data, json);
}

/* ── 控制命令处理（对应 main.c handle_command；事件改入 FIFO） ──── */

static void handle_command(ArchoeraMediaEngine *e, const char *line)
{
    char type[64] = {0};
    if (json_get_string(line, "type", type, sizeof(type)) < 0) return;

    if (strcmp(type, "set_eq") == 0) {
        float gains[EQ_BANDS] = {0};
        int n = json_get_float_array(line, "gains", gains, EQ_BANDS);
        if (n > 0) pipeline_set_eq_gains(e->p, gains);
        double preamp = 0;
        if (json_get_number(line, "preamp", &preamp) == 0) {
            pipeline_set_preamp(e->p, (float)preamp);
        }
    } else if (strcmp(type, "set_volume") == 0) {
        double vol = 1.0;
        if (json_get_number(line, "gain", &vol) == 0) {
            if (e->player) {
                player_command(e->player, "set_volume", NULL, &vol);
            } else {
                pipeline_set_volume(e->p, (float)vol);
            }
        }
    } else if (strcmp(type, "set_normalization") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_normalization_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "set_limiter") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_limiter_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "set_fft") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_fft_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "set_tempo_speed") == 0) {
        double speed = 1.0;
        if (json_get_number(line, "speed", &speed) == 0) {
            pipeline_set_tempo_speed(e->p, (float)speed);
        }
    } else if (strcmp(type, "set_tempo_pitch") == 0) {
        double semitones = 0.0;
        if (json_get_number(line, "semitones", &semitones) == 0) {
            pipeline_set_tempo_pitch(e->p, (float)semitones);
        }
    } else if (strcmp(type, "set_tempo") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_tempo_enabled(e->p, enabled);
        }
    } else if (strcmp(type, "get_status") == 0) {
        if (e->player) {
            player_command(e->player, "get_status", NULL, NULL);
        } else {
            char buf[256];
            double pos = pipeline_get_position(e->p);
            double dur = pipeline_get_duration(e->p);
            snprintf(buf, sizeof(buf),
                "{\"type\":\"status\",\"position_ms\":%.0f,\"duration_ms\":%.0f}",
                pos * 1000.0, dur * 1000.0);
            ev_enqueue(e, buf);
        }
    } else if (strcmp(type, "play") == 0) {
        if (e->player) player_command(e->player, "play", NULL, NULL);
    } else if (strcmp(type, "pause") == 0) {
        if (e->player) player_command(e->player, "pause", NULL, NULL);
    } else if (strcmp(type, "set_playing") == 0) {
        bool playing = true;
        if (json_get_bool(line, "playing", &playing) == 0 && e->player) {
            double v = playing ? 1.0 : 0.0;
            player_command(e->player, "set_playing", NULL, &v);
        }
    } else if (strcmp(type, "seek") == 0) {
        double pos = 0.0;
        if (json_get_number(line, "position_ms", &pos) == 0) {
            /* 无条件记录 pending（player 存在则立即执行）：
               转码/加载阶段拖动进度条也能生效——播放器启动后应用目标位置 */
            e->seek_pending = 1;
            e->pending_seek_ms = pos;
            if (e->player) {
                player_command(e->player, "seek", &pos, NULL);
            }
        }
    } else if (strcmp(type, "set_event_interval") == 0) {
        /* 降频协商（engine-event-push-plan §4.2）：Dart 发目标间隔 →
           写入 player 运行期字段 → 立即回执 event_interval 确认实际生效值。
           以 C 回执为准，Dart 不假设切换已生效 */
        double iv = 0.0;
        if (json_get_number(line, "interval_ms", &iv) == 0 && iv >= 20) {
            int interval = (int)iv;
            if (interval < 20) interval = 20;
            e->pos_interval_ms = interval;
            if (e->player) {
                player_set_position_interval(e->player, interval);
            }
            char buf[96];
            snprintf(buf, sizeof(buf),
                "{\"type\":\"event_interval\",\"interval_ms\":%d}", interval);
            ev_enqueue(e, buf);
        }
    } else if (strcmp(type, "stop") == 0) {
        e->stop_requested = 1;
    }
}

/* ── 引擎线程 ────────────────────────────────────────────────── */

static void *engine_thread(void *arg)
{
    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)arg;

    /* pipeline_create 在引擎线程执行：avformat_open_input 对网络源是阻塞 IO，
       在 Dart isolate 线程执行会被 VM 中断信号打断（poll/recv 返回 EINTR，
       FFmpeg 网络层直接失败）。pthread 线程不接收 Dart VM 信号，安全。 */
    e->p = pipeline_create(e->source, &e->cfg, dummy_output, NULL);
    if (!e->p) {
        char err[320];
        snprintf(err, sizeof(err),
            "{\"type\":\"error\",\"message\":\"pipeline create failed: %s\"}",
            e->source);
        ev_enqueue(e, err);
        ev_enqueue(e, "{\"type\":\"exited\",\"code\":-1}");
        e->done = 1;
        return NULL;
    }

    if (e->player_file) {
        wav_begin(e);
    }
    e->pcm = fopen(e->pcm_file, "wb");
    if (e->wav || e->pcm) {
        pipeline_set_pcm_out_cb(e->p, on_pcm_out, e);
    }

    /* ready 事件 */
    char ready[320];
    snprintf(ready, sizeof(ready),
        "{\"type\":\"ready\",\"version\":\"%s\",\"duration_ms\":%.0f,"
        "\"sample_rate\":%d,\"channels\":%d,\"out_sample_rate\":%d}",
        audio_engine_version(),
        pipeline_get_duration(e->p) * 1000.0,
        pipeline_get_source_sample_rate(e->p),
        pipeline_get_source_channels(e->p),
        pipeline_get_output_sample_rate(e->p));
    ev_enqueue(e, ready);

    /* 转码主循环（全速；命令队列非阻塞消费） */
    for (;;) {
        if (e->stop_requested) break;
        ssize_t n = pipeline_process(e->p);
        if (n < 0) {
            char err[160];
            snprintf(err, sizeof(err),
                "{\"type\":\"error\",\"message\":\"pipeline error %zd\"}", (size_t)n);
            ev_enqueue(e, err);
            break;
        }
        if (n == 0) break; /* EOF */

        char line[CMD_LINE + 1];
        while (cmd_dequeue(e, line, sizeof(line))) {
            handle_command(e, line);
        }
    }

    int code = 0;
    if (!e->stop_requested) {
        int ret = pipeline_run(e->p); /* flush 残留 */
        if (ret < 0) {
            char err[160];
            snprintf(err, sizeof(err), "{\"type\":\"error\",\"message\":\"flush %d\"}", ret);
            ev_enqueue(e, err);
            code = ret;
        } else {
            ev_enqueue(e, "{\"type\":\"done\"}");
        }

        if (e->wav) wav_finalize(e); /* 转码完成，WAV 头回填后供播放器加载 */
        if (e->player_file && !e->stop_requested) {
            e->player = player_start(e->wav_file, player_event_cb, e);
            if (!e->player) {
                ev_enqueue(e, "{\"type\":\"error\",\"message\":\"player start failed\"}");
            }
            /* 转码期间协商的位置事件间隔：播放器启动后立即应用 */
            if (e->player && e->pos_interval_ms > 0) {
                player_set_position_interval(e->player, e->pos_interval_ms);
            }
            /* 转码期间记录的 seek 目标：播放器启动后立即应用
               （player 已存在时 seek 命令在 handle_command 即时执行过） */
            if (e->player && e->seek_pending) {
                e->seek_pending = 0;
                player_command(e->player, "seek", &e->pending_seek_ms, NULL);
            }
            /* 播放循环（50ms 节拍；播放自然结束 / stop 退出） */
            while (!e->stop_requested) {
                if (e->player && player_poll(e->player)) {
                    break; /* 播放结束 */
                }
                char line[CMD_LINE + 1];
                while (cmd_dequeue(e, line, sizeof(line))) {
                    handle_command(e, line);
                }
                struct timespec ts = {0, 50 * 1000000L};
                nanosleep(&ts, NULL);
            }
            if (e->player) {
                player_stop(e->player);
                e->player = NULL;
            }
        }
    }

    if (e->wav) { fclose(e->wav); e->wav = NULL; }
    if (e->pcm) { fclose(e->pcm); e->pcm = NULL; }
    if (e->p) { pipeline_destroy(e->p); e->p = NULL; }

    char exited[64];
    snprintf(exited, sizeof(exited), "{\"type\":\"exited\",\"code\":%d}", code);
    ev_enqueue(e, exited);

    e->done = 1;
    return NULL;
}

/* ── 公开 API ────────────────────────────────────────────────── */

ArchoeraMediaEngine *archoera_mediaengine_create(const char *source,
                                     const EngineConfig *cfg,
                                     const char *player_file,
                                     const char *session_dir,
                                     char *errbuf, int errbuf_size)
{
    if (!source || !session_dir) return NULL;

    ArchoeraMediaEngine *e = (ArchoeraMediaEngine *)calloc(1, sizeof(ArchoeraMediaEngine));
    if (!e) return NULL;

    e->source = strdup(source);
    if (player_file) e->player_file = strdup(player_file);
    e->session_dir = strdup(session_dir);
    e->cfg = cfg ? *cfg : ENGINE_CONFIG_DEFAULT;
    if (e->player_file) {
        e->cfg.skip_encoder = true; /* 播放模式：仅 PCM 落盘，无 Opus 编码 */
    }

    size_t dl = strlen(session_dir);
    e->wav_file = (char *)malloc(dl + 16);
    e->pcm_file = (char *)malloc(dl + 16);
    snprintf(e->wav_file, dl + 16, "%s/stream.wav", session_dir);
    snprintf(e->pcm_file, dl + 16, "%s/stream.pcm", session_dir);

    pthread_mutex_init(&e->ev_mutex, NULL);
    pthread_mutex_init(&e->cmd_mutex, NULL);
    pthread_cond_init(&e->cmd_cond, NULL);

    /* pipeline_create（avformat_open_input 网络 IO）移到引擎线程执行：
       create 立即返回，不占用 Dart isolate 线程（避免 VM 中断信号打断
       阻塞系统调用；详见 engine_thread 注释）。错误经 error 事件上报。 */
    if (pthread_create(&e->thread, NULL, engine_thread, e) != 0) {
        free(e->source);
        free(e->player_file);
        free(e->session_dir);
        free(e->wav_file);
        free(e->pcm_file);
        pthread_mutex_destroy(&e->ev_mutex);
        pthread_mutex_destroy(&e->cmd_mutex);
        pthread_cond_destroy(&e->cmd_cond);
        free(e);
        if (errbuf && errbuf_size > 0) {
            snprintf(errbuf, errbuf_size, "pthread_create failed");
        }
        return NULL;
    }
    e->thread_created = 1;
    return e;
}

int archoera_mediaengine_command(ArchoeraMediaEngine *e, const char *json_line)
{
    if (!e || !json_line) return -1;
    return cmd_enqueue(e, json_line);
}

int archoera_mediaengine_poll_event(ArchoeraMediaEngine *e, char *buf, int cap)
{
    if (!e || !buf || cap <= 0) return 0;
    int r = 0;
    pthread_mutex_lock(&e->ev_mutex);
    if (e->ev_count > 0) {
        strncpy(buf, e->ev_buf[e->ev_head], cap - 1);
        buf[cap - 1] = '\0';
        e->ev_head = (e->ev_head + 1) % EV_CAP;
        e->ev_count--;
        r = 1;
    }
    pthread_mutex_unlock(&e->ev_mutex);
    return r;
}

const char *archoera_mediaengine_session_dir(ArchoeraMediaEngine *e)
{
    return e ? e->session_dir : NULL;
}

int archoera_mediaengine_is_done(ArchoeraMediaEngine *e)
{
    return e ? e->done : 1;
}

void archoera_mediaengine_destroy(ArchoeraMediaEngine *e)
{
    if (!e) return;
    e->stop_requested = 1;
    if (e->p) {
        pipeline_signal_shutdown(e->p); /* 转码中 → 优雅中断退出 */
    }
    if (e->thread_created) {
        pthread_join(e->thread, NULL);
        e->thread_created = 0;
    }
    free(e->source);
    free(e->player_file);
    free(e->session_dir);
    free(e->wav_file);
    free(e->pcm_file);
    pthread_mutex_destroy(&e->ev_mutex);
    pthread_mutex_destroy(&e->cmd_mutex);
    pthread_cond_destroy(&e->cmd_cond);
    free(e);
}

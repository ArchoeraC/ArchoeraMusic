/**
 * main.c — archoera-audio-engine CLI 入口
 *
 * 用法：
 *   批量模式（默认）：
 *     archoera-audio-engine <输入文件/URL> [选项]
 *     一次性转码，stdout 输出 OGG/Opus 流
 *
 *   交互模式（Phase 3）：
 *     archoera-audio-engine <输入文件/URL> --interactive --control-fd 3 [--fft-fd 4] [选项]
 *     stdin 接收 JSON 控制命令，stdout 输出 OGG/Opus 流，control-fd 输出状态/响应的 JSON 行
 *     --fft-fd 指定的 fd 输出 FFT 频谱 JSON 行
 *
 *   播放模式（Phase 4，自写播放器，§10.8 替代 libmpv）：
 *     archoera-audio-engine <输入文件/URL> --interactive --control-uds <path> \
 *         --stream-uds <path> --player-file <transcoded.wav> [选项]
 *     转码 PCM 落盘为 <transcoded.wav>，完成后经 miniaudio 播放（内置 dr_wav，
 *     本地完整文件 seek 即时）；播放中 stdin 仍接收 play/pause/seek/set_volume/get_status
 *     命令，位置经 control 事件推送
 *
 * stdin 控制命令（JSON，每行一个）：
 *   {"type":"set_eq","gains":[0,1,0,-1,0,0,0,0,0,0],"preamp":0}
 *   {"type":"set_volume","gain":0.8}
 *   {"type":"set_normalization","enabled":true}
 *   {"type":"set_limiter","enabled":true}
 *   {"type":"set_fft","enabled":true}
 *   {"type":"get_status"}
 *   {"type":"stop"}   // 请求退出（keep-alive/播放等待循环据此退出）
 *   {"type":"play"} / {"type":"pause"}   // 播放模式：播放/暂停（g_player 非空时）
 *   {"type":"set_playing","playing":true} // 播放模式：设置播放状态
 *   {"type":"seek","position_ms":12345}   // 播放模式：跳转到指定毫秒
 *
 * control-fd 响应/状态（JSON，每行一个）：
 *   {"type":"ready","version":"0.3.0","duration_ms":234567,"sample_rate":48000,"channels":2}
 *   {"type":"status","position_ms":12345,"duration_ms":234567}
 *   {"type":"done"}   // 转码完成；--keep-alive-ms > 0 时进程保持存活（等待消费者）
 *   {"type":"playing","duration_ms":234567}  // 播放模式：播放器就绪（完整时长回填）
 *   {"type":"position","position_ms":12345}  // 播放模式：位置事件（每 100ms 音频 1 帧）
 *   {"type":"player:ended"}  // 播放模式：播放自然结束
 *   {"type":"error","message":"..."}
 *
 * fft-fd 频谱数据（JSON，每行一个，由 --fft-fd 指定 fd 输出）：
 *   {"type":"fft","bins":128,"offsetMs":12345,"ldata":[0.0,0.5,...],"rdata":[0.0,0.5,...]}
 *   固定 128 bins，对数频段映射（80~2000Hz），值归一化到 [0,1]（对齐 Electron Rust 端契约）；
 *   offsetMs = 起始偏移 + 已处理音频位置，供前端按播放位置取帧（拉模式）
 *
 *   桌面端（Flutter 直连）用 --pcm-uds <path> 替代：原始 float PCM 经 UDS 流出，
 *   频谱分析由客户端完成（FFT 客户端化），引擎只负责解码/处理/转码。
 */
#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include "../include/audio_engine.h"
#include "decoder.h"
#include "pcm_uds.h"
#include "player.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>

/* 全局管线指针，供 SIGTERM 处理器优雅关闭 */
static AudioPipeline *g_pipeline = NULL;

/* SIGTERM 已收到（keep-alive 等待循环据此退出） */
static volatile sig_atomic_t g_sigterm_received = 0;
/* stdin stop 命令已收到（keep-alive 等待循环据此退出） */
static volatile sig_atomic_t g_want_exit = 0;

/* FFT 推送（回调驱动）：目标 fd / 间隔（音频秒）/ 上次推送位置 */
static int g_fft_fd = -1;
static double g_fft_interval_sec = 0.1;
static double g_last_fft_pos = -1.0;
/* seek/CUE 起始偏移（ms）：FFT offsetMs = 起始偏移 + 引擎内已处理位置 */
static long g_offset_ms = 0;

/* 流消费者等待超时（ms）：桌面 Flutter 转发桥连接延迟远小于此值 */
#define STREAM_WAIT_MS 15000

/* PCM 流出 UDS 服务器（Flutter 直连收取原始 PCM，FFT 客户端化） */
static PcmUds *g_pcm_uds = NULL;
/* OGG 流 UDS 服务器（libmpv unix:// 直连，替代 stdout，零 TCP） */
static PcmUds *g_stream_uds = NULL;
/* 控制事件 UDS 服务器（桌面端 Flutter 直连收 ready/status/done/error JSON 行；
 * Dart Process 无法传 fd3，故经 UDS 输出；Web/Node 仍走 fd3） */
static PcmUds *g_ctl_uds = NULL;
/* 控制输出 fd（--control-fd，默认 3；无 --control-uds 时使用） */
static int g_ctl_fd = -1;

/* 播放器实例（--player-file 启用；转码 done 后进入播放模式） */
static PlayerCtx *g_player = NULL;

/* 播放模式 PCM 落盘（WAV，float32；miniaudio 内置 dr_wav 零依赖解码播放） */
static FILE *g_wav_file = NULL;

/* 写 WAV 文件头（IEEE float32，format 3） */
static void wav_begin(const char *path, int sample_rate, int channels)
{
    g_wav_file = fopen(path, "wb");
    if (!g_wav_file) return;

    uint16_t block_align = (uint16_t)(channels * 4);
    uint32_t byte_rate = (uint32_t)(sample_rate * channels * 4);
    uint32_t placeholder = 0xFFFFFFFF; /* RIFF/data 大小占位，结束时回填 */

    fwrite("RIFF", 1, 4, g_wav_file);
    fwrite(&placeholder, 4, 1, g_wav_file);
    fwrite("WAVEfmt ", 1, 8, g_wav_file);
    uint32_t fmt_size = 16;
    fwrite(&fmt_size, 4, 1, g_wav_file);
    uint16_t audio_format = 3; /* IEEE float */
    fwrite(&audio_format, 2, 1, g_wav_file);
    uint16_t ch = (uint16_t)channels;
    fwrite(&ch, 2, 1, g_wav_file);
    uint32_t sr = (uint32_t)sample_rate;
    fwrite(&sr, 4, 1, g_wav_file);
    fwrite(&byte_rate, 4, 1, g_wav_file);
    fwrite(&block_align, 2, 1, g_wav_file);
    uint16_t bits = 32;
    fwrite(&bits, 2, 1, g_wav_file);
    fwrite("data", 1, 4, g_wav_file);
    fwrite(&placeholder, 4, 1, g_wav_file);
}

/* 回填 WAV 头大小并关闭（转码完成、播放器加载前调用） */
static void wav_finalize(void)
{
    if (!g_wav_file) return;
    long data_size = ftell(g_wav_file) - 44;
    fseek(g_wav_file, 40, SEEK_SET); /* data chunk size */
    uint32_t sz = (uint32_t)data_size;
    fwrite(&sz, 4, 1, g_wav_file);
    fseek(g_wav_file, 4, SEEK_SET); /* RIFF size = data + 36 */
    sz = (uint32_t)(data_size + 36);
    fwrite(&sz, 4, 1, g_wav_file);
    fclose(g_wav_file);
    g_wav_file = NULL;
}

/* PCM 流出回调：块头 [int32 pos_ms][int32 samples][int32 channels] + float PCM。
 * 播放模式（--player-file）同时把 PCM 落盘 WAV（miniaudio 内置解码播放）。 */
static void on_pcm_out(const float *pcm, int samples, int channels,
                       double position_ms, void *user_data)
{
    (void)user_data;
    if (samples <= 0 || channels <= 0) return;

    if (g_wav_file) {
        fwrite(pcm, sizeof(float), (size_t)samples * (size_t)channels,
               g_wav_file);
    }

    if (!g_pcm_uds) return;

    int32_t header[3];
    header[0] = (int32_t)position_ms;
    header[1] = (int32_t)samples;
    header[2] = (int32_t)channels;

    struct iovec iov[2];
    iov[0].iov_base = header;
    iov[0].iov_len = sizeof(header);
    iov[1].iov_base = (void *)pcm;
    iov[1].iov_len = (size_t)samples * (size_t)channels * sizeof(float);

    pcm_uds_push(g_pcm_uds, iov, 2);
}

/* SIGTERM 处理器：优雅关闭管线而非被终止。
 * 1. decoder_interrupt() 设置 AVIOInterruptCB 标志 — 若 av_read_frame()
 *    正阻塞在磁盘 I/O，FFmpeg 下次检查时立即返回 AVERROR_EXIT。
 * 2. pipeline_signal_shutdown() 设置管线退出标志 — 主循环检测后退出。 */
static void handle_sigterm(int sig) {
    (void)sig;
    g_sigterm_received = 1;
    decoder_interrupt();
    if (g_pipeline) {
        pipeline_signal_shutdown(g_pipeline);
    }
}

/* ── 简单 JSON 解析辅助（仅处理我们的控制协议格式） ───────────────── */

/** 跳过空白 */
static const char* skip_ws(const char *s) {
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    return s;
}

/** 在 JSON 字符串中找到键的值，返回值的起始位置 */
static const char* json_find(const char *json, const char *key) {
    char search[128];
    int key_len = (int)strlen(key);
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *pos = strstr(json, search);
    if (!pos) return NULL;
    return skip_ws(pos + key_len + 2 + 1); /* skip "key": */
}

/** 读取 JSON 字符串值（复制到 buf） */
static int json_get_string(const char *json, const char *key, char *buf, int bufsize) {
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

/** 读取 JSON 数值 */
static int json_get_number(const char *json, const char *key, double *out) {
    const char *val = json_find(json, key);
    if (!val) return -1;
    char *end;
    *out = strtod(val, &end);
    return (end == val) ? -1 : 0;
}

/** 读取 JSON 布尔 */
static int json_get_bool(const char *json, const char *key, bool *out) {
    const char *val = json_find(json, key);
    if (!val) return -1;
    if (strncmp(val, "true", 4) == 0) { *out = true; return 0; }
    if (strncmp(val, "false", 5) == 0) { *out = false; return 0; }
    return -1;
}

/** 读取 JSON 数组 [n1,n2,...] 到 float 数组 */
static int json_get_float_array(const char *json, const char *key, float *out, int max_count) {
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

/* ── 输出辅助 ──────────────────────────────────────────────────── */

/** 写入 fd 的辅助函数（带重试） */
static int write_fd(int fd, const char *data, int len) {
    int written = 0;
    while (written < len) {
        int n = (int)write(fd, data + written, len - written);
        if (n <= 0) return -1;
        written += n;
    }
    return written;
}

/** 向 control-fd 写入 JSON 行 */
static int control_send(int fd, const char *json) {
    int len = (int)strlen(json);
    int ret = write_fd(fd, json, len);
    if (ret < 0) return ret;
    return write_fd(fd, "\n", 1);
}

/** 控制事件统一输出：优先 control UDS（桌面 Flutter），否则 fd3（Web/Node） */
static int control_send_line(const char *json)
{
    if (g_ctl_uds) {
        struct iovec iov;
        char buf[1024];
        int n = snprintf(buf, sizeof(buf), "%s\n", json);
        if (n < 0 || n >= (int)sizeof(buf)) return -1;
        iov.iov_base = buf;
        iov.iov_len = (size_t)n;
        return pcm_uds_push(g_ctl_uds, &iov, 1);
    }
    if (g_ctl_fd >= 0) return control_send(g_ctl_fd, json);
    return -1;
}

/* 播放器事件回调适配：player 事件 → control_send_line（int → void 签名桥接） */
static void player_event_cb(const char *json, void *user_data)
{
    (void)user_data;
    control_send_line(json);
}

/* ── OutputCallback：写到 stdout ────────────────────────────────── */
static int write_to_stdout(const uint8_t *data, size_t size, void *user)
{
    (void)user;
    size_t written = 0;
    while (written < size) {
        size_t n = fwrite(data + written, 1, size - written, stdout);
        if (n == 0) return -1;
        written += n;
    }
    fflush(stdout);
    return (int)written;
}

/* ── OutputCallback：写到流 UDS（libmpv unix:// 直连，零 TCP，§9）── */
static int write_to_stream_uds(const uint8_t *data, size_t size, void *user)
{
    (void)user;
    if (!g_stream_uds) return (int)size; /* 无监听/无连接：丢弃（无人消费） */
    struct iovec iov;
    iov.iov_base = (void *)data;
    iov.iov_len = size;
    /* 有连接时阻塞写 = 背压限速（libmpv 消费节奏驱动转码）；断开自动等重连 */
    pcm_uds_push(g_stream_uds, &iov, 1);
    return (int)size;
}

/* ── 解析 EQ 增益字符串 ────────────────────────────────────────── */
static int parse_eq_gains(const char *str, float gains[EQ_BANDS])
{
    int count = 0;
    char *copy = strdup(str);
    char *token = strtok(copy, ",");
    while (token && count < EQ_BANDS) {
        gains[count++] = atof(token);
        token = strtok(NULL, ",");
    }
    free(copy);
    return count;
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "用法: %s <输入文件/URL> [选项]\n"
        "\n"
        "基本选项:\n"
        "  -b, --bitrate <bps>     Opus 比特率（默认 128000）\n"
        "  -f, --frame-size <ms>   Opus 帧时长（默认 20ms）\n"
        "  -r, --sample-rate <Hz>  输出采样率（默认 48000，Opus 固定）\n"
        "  -c, --channels <n>      输出声道数（默认 2）\n"
        "  -o, --offset <ms>       跳过开头的毫秒数（CUE 分轨，默认 0）\n"
        "\n"
        "Phase 2 音频处理选项:\n"
        "  --eq <gains>            10 段 EQ 增益（dB），逗号分隔，如 \"0,2,0,-1,0,0,0,0,0,0\"\n"
        "  --preamp <dB>           前级增益（dB），默认 0\n"
        "  --normalization         启用响度归一化\n"
        "  --normalization-gain <dB> 预计算响度增益（dB），默认 0\n"
        "  --no-limiter            禁用限幅器\n"
        "  --limiter-threshold <dB> 限幅器阈值（dB），默认 -1.0\n"
        "  --fft                   启用 FFT 频谱分析\n"
        "  --fft-size <n>          FFT 点数（默认 1024）\n"
        "\n"
        "Phase 4 变速变调选项:\n"
        "  --tempo                 启用变速变调\n"
        "  --tempo-speed <x>       播放速度 [0.5-2.0]，默认 1.0\n"
        "  --tempo-pitch <semitones> 音调偏移（半音）[-12-12]，默认 0\n"
        "  --tempo-pitch-sync      保音调模式（默认）\n"
        "\n"
        "Phase 3 交互模式选项:\n"
        "  --interactive           启用交互模式（stdin JSON 控制）\n"
        "  --control-fd <n>        控制协议 fd（默认 3）\n"
        "  --fft-fd <n>            FFT 数据输出 fd（默认 4），需同时启用 --fft\n"
        "  --fft-interval-ms <n>   FFT 推送间隔（默认 100ms）\n"
        "  --keep-alive-ms <n>     转码完成后保持进程存活 n 毫秒，等待迟到消费者\n"
        "                          （默认 0 = 立即退出；仅播放服务显式启用）\n"
        "\n"
        "FFT 客户端化选项（桌面端 Flutter 直连，替代 --fft-fd）:\n"
        "  --stream-uds <path>    OGG 流经 UDS 输出（Flutter 转发桥/libmpv 直连；\n"
        "                          引擎等待消费者连上后才开始转码，保证流从头完整）\n"
        "  --pcm-uds <path>       原始 float PCM 经 UDS 流出（块头 [pos_ms|samples|channels]）\n"
        "                          Flutter 连接后自行分析频谱；无需 --fft\n"
        "  --control-uds <path>   控制事件（ready/status/done/error JSON 行）经 UDS 输出，\n"
        "                          替代 fd3（Dart Process 无法传额外 fd，桌面端必用）\n"
        "\n"
        "自写播放器选项（Phase 4，§10.8 替代 libmpv，需 --interactive）:\n"
        "  --player-file <path>    转码完成后进入播放模式：PCM 落盘为该 WAV 文件，\n"
        "                          经 miniaudio 内置 dr_wav 解码播放（零外部依赖）；\n"
        "                          播放中 stdin 接受 play/pause/seek/set_volume，\n"
        "                          位置经 control 事件（playing/position/player:ended）推送\n"
        "\n"
        "其他:\n"
        "  -h, --help              显示帮助\n"
        "  -v, --version           显示版本\n"
        "\n"
        "输出:\n"
        "  stdout: OGG/Opus 音频流\n"
        "  stderr: 日志信息\n",
        prog);
}

/* ── 处理单条 stdin 控制命令 ───────────────────────────────────── */
static void handle_command(AudioPipeline *p, const char *line) {
    char type[64] = {0};
    if (json_get_string(line, "type", type, sizeof(type)) < 0) return;

    if (strcmp(type, "set_eq") == 0) {
        float gains[EQ_BANDS] = {0};
        int n = json_get_float_array(line, "gains", gains, EQ_BANDS);
        if (n > 0) pipeline_set_eq_gains(p, gains);
        double preamp = 0;
        if (json_get_number(line, "preamp", &preamp) == 0) {
            pipeline_set_preamp(p, (float)preamp);
        }
    } else if (strcmp(type, "set_volume") == 0) {
        double vol = 1.0;
        if (json_get_number(line, "gain", &vol) == 0) {
            if (g_player) {
                player_command(g_player, "set_volume", NULL, &vol);
            } else {
                pipeline_set_volume(p, (float)vol);
            }
        }
    } else if (strcmp(type, "set_normalization") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_normalization_enabled(p, enabled);
        }
    } else if (strcmp(type, "set_limiter") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_limiter_enabled(p, enabled);
        }
    } else if (strcmp(type, "set_fft") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_fft_enabled(p, enabled);
        }
    } else if (strcmp(type, "set_tempo_speed") == 0) {
        double speed = 1.0;
        if (json_get_number(line, "speed", &speed) == 0) {
            pipeline_set_tempo_speed(p, (float)speed);
        }
    } else if (strcmp(type, "set_tempo_pitch") == 0) {
        double semitones = 0.0;
        if (json_get_number(line, "semitones", &semitones) == 0) {
            pipeline_set_tempo_pitch(p, (float)semitones);
        }
    } else if (strcmp(type, "set_tempo") == 0) {
        bool enabled = true;
        if (json_get_bool(line, "enabled", &enabled) == 0) {
            pipeline_set_tempo_enabled(p, enabled);
        }
    } else if (strcmp(type, "get_status") == 0) {
        if (g_player) {
            player_command(g_player, "get_status", NULL, NULL);
        } else {
            char buf[256];
            double pos = pipeline_get_position(p);
            double dur = pipeline_get_duration(p);
            snprintf(buf, sizeof(buf),
                "{\"type\":\"status\",\"position_ms\":%.0f,\"duration_ms\":%.0f}",
                pos * 1000.0, dur * 1000.0);
            control_send_line(buf);
        }
    } else if (strcmp(type, "play") == 0) {
        if (g_player) player_command(g_player, "play", NULL, NULL);
    } else if (strcmp(type, "pause") == 0) {
        if (g_player) player_command(g_player, "pause", NULL, NULL);
    } else if (strcmp(type, "set_playing") == 0) {
        bool playing = true;
        if (json_get_bool(line, "playing", &playing) == 0 && g_player) {
            double v = playing ? 1.0 : 0.0;
            player_command(g_player, "set_playing", NULL, &v);
        }
    } else if (strcmp(type, "seek") == 0) {
        double pos = 0.0;
        if (json_get_number(line, "position_ms", &pos) == 0 && g_player) {
            player_command(g_player, "seek", &pos, NULL);
        }
    } else if (strcmp(type, "stop") == 0) {
        /* keep-alive 等待循环据此退出（桌面端主动停止也走 SIGTERM） */
        g_want_exit = 1;
    }
}

/* ── 交互模式主循环 ────────────────────────────────────────────── */

/* 前端渲染契约：固定 128 bins 归一化频谱（[0,1] 对数映射，对齐 Electron Rust 端） */
#define FFT_PUSH_BINS 128

/* 推送一帧 FFT 频谱到 fft_fd（JSON 行，双声道归一化 [0,1] bins） */
static int push_fft_frame(AudioPipeline *p, int fft_fd)
{
    if (fft_fd < 0) return 0;
    if (pipeline_get_fft_size(p) <= 0) return 0;
    int bins = FFT_PUSH_BINS;
    float fft_data[FFT_PUSH_BINS];
    float fft_data_r[FFT_PUSH_BINS];
    pipeline_get_fft_spectrum_norm_stereo(p, fft_data, fft_data_r, bins);

    /* 构造 JSON（双声道独立数据；offsetMs=起始偏移+已处理位置，供前端按播放位置取帧） */
    char fft_json[16384];
    int off = snprintf(fft_json, sizeof(fft_json),
        "{\"type\":\"fft\",\"bins\":%d,\"offsetMs\":%.0f,\"ldata\":[",
        bins, (double)g_offset_ms + pipeline_get_fft_processed_seconds(p) * 1000.0);
    for (int i = 0; i < bins; i++) {
        off += snprintf(fft_json + off, sizeof(fft_json) - off,
            "%.1f%s", fft_data[i], i < bins - 1 ? "," : "");
    }
    off += snprintf(fft_json + off, sizeof(fft_json) - off, "],\"rdata\":[");
    for (int i = 0; i < bins; i++) {
        off += snprintf(fft_json + off, sizeof(fft_json) - off,
            "%.1f%s", fft_data_r[i], i < bins - 1 ? "," : "");
    }
    off += snprintf(fft_json + off, sizeof(fft_json) - off, "]}");

    int ret = write_fd(fft_fd, fft_json, off);
    if (ret < 0) return ret;
    return write_fd(fft_fd, "\n", 1);
}

/* FFT 帧回调：每次频谱计算完成即触发（fft 内部同步调用）。
 * 按已处理音频位置推进推送——转码速度随管道背压变化（真实播放≈实时、
 * CLI 无背压时秒级完成），墙钟间隔不可靠，音频位置恒定。 */
static void on_fft_frame(void *user_data, int fft_size)
{
    (void)fft_size;
    if (g_fft_fd < 0) return;
    AudioPipeline *p = (AudioPipeline *)user_data;
    if (!p) return;
    double pos = pipeline_get_fft_processed_seconds(p);
    if (g_last_fft_pos < 0) {
        g_last_fft_pos = pos;
        return;
    }
    if (pos - g_last_fft_pos >= g_fft_interval_sec) {
        push_fft_frame(p, g_fft_fd);
        g_last_fft_pos = pos; /* 追踪最新位置，避免误差累积 */
    }
}

static int run_interactive(AudioPipeline *p, int fft_fd, int fft_interval_ms,
                           int keep_alive_ms, const char *player_file)
{
    /* 发送就绪消息（经 control UDS / fd3）：
     * sample_rate 为源采样率（诊断/兼容）；out_sample_rate 为管线实际输出采样率
     * （player 模式跟随源时即源采样率，Flutter FFT 客户端按此建分析器） */
    char ready[320];
    snprintf(ready, sizeof(ready),
        "{\"type\":\"ready\",\"version\":\"%s\",\"duration_ms\":%.0f,"
        "\"sample_rate\":%d,\"channels\":%d,\"out_sample_rate\":%d}",
        audio_engine_version(),
        pipeline_get_duration(p) * 1000.0,
        pipeline_get_source_sample_rate(p),
        pipeline_get_source_channels(p),
        pipeline_get_output_sample_rate(p));
    control_send_line(ready);

    /* 设置 stdin 为非阻塞 */
    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);

    /* stdin 读取缓冲区 */
    char stdin_buf[4096];
    int stdin_pos = 0;

    /* FFT 推送：帧回调按已处理音频位置驱动（每 fft_interval_ms 音频 1 帧） */
    g_fft_fd = fft_fd;
    g_fft_interval_sec = (fft_interval_ms > 0 ? fft_interval_ms : 100) / 1000.0;
    g_last_fft_pos = -1.0;
    pipeline_set_fft_frame_cb(p, on_fft_frame, p);

    /* 主循环：交替处理音频帧 + 检查 stdin 命令 */
    for (;;) {
        /* 处理若干音频帧 */
        ssize_t n = pipeline_process(p);
        if (n < 0) {
            char err_buf[128];
            snprintf(err_buf, sizeof(err_buf),
                "{\"type\":\"error\",\"message\":\"pipeline error %zd\"}", (size_t)n);
            control_send_line(err_buf);
            return (int)n;
        }
        if (n == 0) break; /* EOF */

        /* 读取 stdin 命令（非阻塞） */
        for (;;) {
            ssize_t r = read(STDIN_FILENO, stdin_buf + stdin_pos,
                             sizeof(stdin_buf) - stdin_pos - 1);
            if (r <= 0) break; /* 无数据或错误 */
            stdin_pos += r;
            stdin_buf[stdin_pos] = '\0';

            /* 处理完整的行 */
            char *sol = stdin_buf;
            while (1) {
                char *nl = strchr(sol, '\n');
                if (!nl) break;
                *nl = '\0';
                if (nl > sol && *sol != '\0') {
                    handle_command(p, sol);
                }
                sol = nl + 1;
            }
            /* 保留未完成的行 */
            if (sol > stdin_buf) {
                int leftover = (int)(stdin_buf + stdin_pos - sol);
                if (leftover > 0) {
                    memmove(stdin_buf, sol, leftover);
                }
                stdin_pos = leftover;
                stdin_buf[stdin_pos] = '\0';
            }
        }
    }

    /* flush 残留 */
    int ret = pipeline_run(p);
    control_send_line("{\"type\":\"done\"}");

    /* 转码后阶段：keep-alive（等待迟到消费者）与播放模式（自写播放器）。
     *   - --keep-alive-ms > 0：转码完成后保持存活 n 毫秒（Web/播放服务兼容）
     *   - --player-file <path>：转码完成后播放 PCM 落盘的 WAV（miniaudio 内置
     *     dr_wav 解码，§10.8 替代 libmpv）；播放中持续响应 stdin 控制，
     *     播放结束/stop/SIGTERM 退出 */
    if (keep_alive_ms > 0 || player_file) {
        if (player_file) {
            /* WAV 头回填 + 关闭（播放器加载需要完整文件） */
            wav_finalize();
            g_player = player_start(player_file, player_event_cb, NULL);
            if (!g_player) {
                control_send_line(
                    "{\"type\":\"error\",\"message\":\"player start failed\"}");
            }
        }

        struct timespec deadline;
        if (keep_alive_ms > 0) {
            clock_gettime(CLOCK_MONOTONIC, &deadline);
            deadline.tv_sec += keep_alive_ms / 1000;
            deadline.tv_nsec += (long)(keep_alive_ms % 1000) * 1000000L;
            if (deadline.tv_nsec >= 1000000000L) {
                deadline.tv_sec += 1;
                deadline.tv_nsec -= 1000000000L;
            }
        }

        while (!g_sigterm_received && !g_want_exit) {
            /* 播放模式：播放自然结束 → 退出（Flutter 收到 player:ended） */
            if (g_player && player_poll(g_player)) {
                g_want_exit = 1;
                break;
            }

            /* 超时检查（仅非播放模式；播放模式播完/stop 才退出） */
            if (keep_alive_ms > 0 && !player_file) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                if (now.tv_sec > deadline.tv_sec ||
                    (now.tv_sec == deadline.tv_sec &&
                     now.tv_nsec >= deadline.tv_nsec)) {
                    break; /* 超时 */
                }
            }

            /* 处理 stdin 命令（非阻塞；play/pause/seek/stop → 状态变更） */
            for (;;) {
                ssize_t r = read(STDIN_FILENO, stdin_buf + stdin_pos,
                                 sizeof(stdin_buf) - stdin_pos - 1);
                if (r <= 0) break;
                stdin_pos += r;
                stdin_buf[stdin_pos] = '\0';
                char *sol = stdin_buf;
                while (1) {
                    char *nl = strchr(sol, '\n');
                    if (!nl) break;
                    *nl = '\0';
                    if (nl > sol && *sol != '\0') {
                        handle_command(p, sol);
                    }
                    sol = nl + 1;
                }
                if (sol > stdin_buf) {
                    int leftover = (int)(stdin_buf + stdin_pos - sol);
                    if (leftover > 0) memmove(stdin_buf, sol, leftover);
                    stdin_pos = leftover;
                    stdin_buf[stdin_pos] = '\0';
                }
            }

            /* 节流轮询（50ms ≈ position 事件 100ms 精度的驱动） */
            struct timespec ts = {0, 50 * 1000000L};
            nanosleep(&ts, NULL);
        }

        if (g_player) {
            player_stop(g_player);
            g_player = NULL;
        }
        fprintf(stderr, "[audio-engine] 转码后阶段结束: %s\n",
                g_sigterm_received ? "SIGTERM"
                : (g_want_exit ? "stop/播放结束" : "超时"));
    }

    return ret;
}

int main(int argc, char *argv[])
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;

    /* Phase 3: 交互模式选项 */
    bool interactive = false;
    int control_fd = 3;
    int fft_fd = -1;
    int fft_interval_ms = 100;
    int keep_alive_ms = 0;

    static struct option long_opts[] = {
        {"bitrate",           required_argument, 0, 'b'},
        {"frame-size",        required_argument, 0, 'f'},
        {"sample-rate",       required_argument, 0, 'r'},
        {"channels",          required_argument, 0, 'c'},
        {"offset",            required_argument, 0, 'o'},
        {"eq",                required_argument, 0, 'e'},
        {"preamp",            required_argument, 0, 'p'},
        {"normalization",     no_argument,       0, 'n'},
        {"normalization-gain",required_argument, 0, 'g'},
        {"no-limiter",        no_argument,       0, 'L'},
        {"limiter-threshold", required_argument, 0, 'l'},
        {"fft",               no_argument,       0, 'F'},
        {"fft-size",          required_argument, 0, 's'},
        /* Phase 4 */
        {"tempo",             no_argument,       0, 'P'},
        {"tempo-speed",       required_argument, 0, 'Q'},
        {"tempo-pitch",       required_argument, 0, 'R'},
        {"tempo-pitch-sync",  no_argument,       0, 'S'},
        /* Phase 3 */
        {"interactive",       no_argument,       0, 'I'},
        {"control-fd",        required_argument, 0, 'C'},
        {"fft-fd",            required_argument, 0, 'D'},
        {"fft-interval-ms",   required_argument, 0, 'T'},
        {"keep-alive-ms",     required_argument, 0, 'K'},
        {"pcm-uds",           required_argument, 0, 'U'},
        {"stream-uds",        required_argument, 0, 'W'},
        {"control-uds",       required_argument, 0, 'J'},
        /* 自写播放器（§10.8 替代 libmpv）：转码完成后播放该 OGG 文件 */
        {"player-file",       required_argument, 0, 'Y'},
        /* 通用 */
        {"help",              no_argument,       0, 'h'},
        {"version",           no_argument,       0, 'v'},
        {0, 0, 0, 0},
    };

    int opt;
    const char *pcm_uds_path = NULL;
    const char *stream_uds_path = NULL;
    const char *control_uds_path = NULL;
    const char *player_file = NULL;
    while ((opt = getopt_long(argc, argv, "b:f:r:c:o:e:p:ng:Ll:s:FQ:R:PSIC:D:T:KUhvWJY", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'b': cfg.bitrate = atoi(optarg); break;
        case 'f': cfg.frame_size_ms = atoi(optarg); break;
        case 'r': cfg.output_sample_rate = atoi(optarg); break;
        case 'c': cfg.output_channels = atoi(optarg); break;
        case 'o': cfg.start_offset_ms = atol(optarg); g_offset_ms = atol(optarg); break;
        case 'e': parse_eq_gains(optarg, cfg.eq_gains); break;
        case 'p': cfg.eq_preamp_db = atof(optarg); break;
        case 'n': cfg.normalization = true; break;
        case 'g': cfg.normalization_gain = atof(optarg); break;
        case 'L': cfg.limiter_enabled = false; break;
        case 'l': cfg.limiter_threshold_db = atof(optarg); break;
        case 'F': cfg.fft_enabled = true; break;
        case 's': cfg.fft_size = atoi(optarg); break;
        /* Phase 4 */
        case 'P': cfg.tempo_enabled = true; break;
        case 'Q': cfg.tempo_speed = atof(optarg); break;
        case 'R': cfg.tempo_pitch = atof(optarg); break;
        case 'S': cfg.tempo_pitch_sync = true; break;
        /* Phase 3 */
        case 'I': interactive = true; break;
        case 'C': control_fd = atoi(optarg); break;
        case 'D': fft_fd = atoi(optarg); break;
        case 'T': fft_interval_ms = atoi(optarg); break;
        case 'K': keep_alive_ms = atoi(optarg); break;
        case 'U': pcm_uds_path = optarg; break;
        case 'W': stream_uds_path = optarg; break;
        case 'J': control_uds_path = optarg; break;
        case 'Y': player_file = optarg; break;
        /* 通用 */
        case 'h': print_usage(argv[0]); return 0;
        case 'v': fprintf(stderr, "%s\n", audio_engine_version()); return 0;
        default:  print_usage(argv[0]); return 1;
        }
    }

    if (optind >= argc) {
        fprintf(stderr, "错误：缺少输入文件\n\n");
        print_usage(argv[0]);
        return 1;
    }

    const char *source = argv[optind];

    /* 安装 SIGTERM 处理器：TS 层发送 kill 时优雅关闭，而非被终止 */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_sigterm;
    sigaction(SIGTERM, &sa, NULL);

    /* 非交互模式关闭 stdin（stdin pipe 对 TS 层无用，提前释放 fd） */
    if (!interactive) {
        close(STDIN_FILENO);
    }

    /* 输出采样率：
     *   - 非 player 模式（批量/流式 Opus 输出）强制 48000（Opus 固定）；
     *   - player 模式（--player-file，miniaudio 播放）保持用户指定值，
     *     未指定时跟随源采样率（原生 Hi-Res 直通，§10.8） */
    if (!player_file && cfg.output_sample_rate != 48000) {
        fprintf(stderr, "[audio-engine] 警告：Opus 固定使用 48000Hz，已自动调整\n");
        cfg.output_sample_rate = 48000;
    }

    fprintf(stderr, "[audio-engine] 开始转码: %s\n", source);
    if (player_file && cfg.output_sample_rate <= 0) {
        fprintf(stderr, "[audio-engine] 输出: 原生采样率(跟随源) / %dch / %dbps / %dms",
                cfg.output_channels, cfg.bitrate, cfg.frame_size_ms);
    } else {
        fprintf(stderr, "[audio-engine] 输出: %dHz / %dch / %dbps / %dms",
                cfg.output_sample_rate, cfg.output_channels,
                cfg.bitrate, cfg.frame_size_ms);
    }
    if (cfg.start_offset_ms > 0) {
        fprintf(stderr, " / offset=%ldms", (long)cfg.start_offset_ms);
    }
    if (interactive) fprintf(stderr, " / interactive(ctl_fd=%d)", control_fd);
    fprintf(stderr, "\n");

    /* 控制输出目标：interactive 时默认 fd3（Web/Node），--control-uds 时走 UDS（桌面） */
    if (interactive && control_uds_path) {
        g_ctl_fd = -1;
    } else if (interactive) {
        g_ctl_fd = control_fd;
    }

    /* 打印 Phase 2 处理状态 */
    bool has_eq = false;
    for (int i = 0; i < EQ_BANDS; i++) {
        if (cfg.eq_gains[i] != 0.0f) { has_eq = true; break; }
    }
    if (has_eq || cfg.eq_preamp_db != 0.0f) {
        fprintf(stderr, "[audio-engine] EQ: preamp=%.1fdB, gains=[", cfg.eq_preamp_db);
        for (int i = 0; i < EQ_BANDS; i++)
            fprintf(stderr, "%.1f%s", cfg.eq_gains[i], i < 9 ? "," : "");
        fprintf(stderr, "]\n");
    }
    if (cfg.normalization) fprintf(stderr, "[audio-engine] 响度归一化: %.1fdB\n", cfg.normalization_gain);
    if (cfg.limiter_enabled) fprintf(stderr, "[audio-engine] 限幅器: %.1fdB\n", cfg.limiter_threshold_db);
    if (cfg.fft_enabled) fprintf(stderr, "[audio-engine] FFT: %d 点\n", cfg.fft_size);

    /* UDS 服务器统一创建（listen fd 非阻塞，连接惰性 accept）。
     * 桌面端（Flutter 直连）三路：
     *   --stream-uds  OGG/Opus 流（Flutter 转发桥连上后驱动转码）
     *   --pcm-uds     原始 float PCM（Flutter 做 FFT 分析）
     *   --control-uds 控制事件 JSON 行（ready/status/done/error） */
    signal(SIGPIPE, SIG_IGN); /* UDS 写断开连接时避免 SIGPIPE 杀进程 */

    if (stream_uds_path) {
        g_stream_uds = pcm_uds_create(stream_uds_path);
        if (!g_stream_uds) {
            fprintf(stderr, "[audio-engine] 警告: 流 UDS 创建失败，回退 stdout 输出\n");
        }
    }
    if (control_uds_path) {
        g_ctl_uds = pcm_uds_create(control_uds_path);
        if (!g_ctl_uds) {
            fprintf(stderr, "[audio-engine] 警告: 控制 UDS 创建失败，控制事件不可用\n");
        }
    }
    if (pcm_uds_path) {
        g_pcm_uds = pcm_uds_create(pcm_uds_path);
        if (!g_pcm_uds) {
            fprintf(stderr, "[audio-engine] 警告: PCM UDS 创建失败，继续转码（无频谱流出）\n");
        }
    }

    /* 等待流消费者连接（桌面 Flutter 转发桥连上后才开始转码，保证 OGG 从开头完整；
     * 无消费者/超时则继续转码，数据经 UDS 丢弃——兼容 Web/CLI 场景）。
     * 注意：SIGTERM 期间此处最多阻塞 STREAM_WAIT_MS，Flutter 停止走 SIGKILL 兜底。 */
    if (g_stream_uds) {
        fprintf(stderr, "[audio-engine] 等待流消费者连接 %s ...\n", stream_uds_path);
        if (pcm_uds_wait_conn(g_stream_uds, STREAM_WAIT_MS) == 0) {
            fprintf(stderr, "[audio-engine] 流消费者已连接，开始转码\n");
        } else {
            fprintf(stderr, "[audio-engine] 等待流消费者超时，继续转码（无消费者则数据丢弃）\n");
        }
    }

    /* player 模式：跳过 Opus 编码（仅 PCM 落盘 WAV/UDS，原生采样率直通） */
    cfg.skip_encoder = (player_file != NULL);

    AudioPipeline *p = pipeline_create(source, &cfg,
        g_stream_uds ? write_to_stream_uds : write_to_stdout, NULL);
    if (!p) {
        fprintf(stderr, "[audio-engine] 管线创建失败\n");
        return 2;
    }

    /* PCM 流出（FFT 客户端化 / 播放模式 WAV 落盘）：
     *   - g_pcm_uds：Flutter 直连收取原始 PCM 做 FFT
     *   - g_wav_file：--player-file 模式，转码 PCM 落盘 WAV 供 miniaudio 播放 */
    if (player_file) {
        /* WAV 头用实际输出采样率/声道（跟随源时即源采样率，原生直通） */
        wav_begin(player_file, pipeline_get_output_sample_rate(p),
                  cfg.output_channels);
        fprintf(stderr, "[audio-engine] 播放模式: PCM 落盘 %s (%dHz)\n",
                player_file, pipeline_get_output_sample_rate(p));
    }
    if (g_pcm_uds || g_wav_file) {
        pipeline_set_pcm_out_cb(p, on_pcm_out, NULL);
    }

    /* 注册全局指针，供 SIGTERM 处理器访问 */
    g_pipeline = p;

    fprintf(stderr, "[audio-engine] 源: %dHz / %dch / 时长 %.1fs\n",
            pipeline_get_source_sample_rate(p),
            pipeline_get_source_channels(p),
            pipeline_get_duration(p));

    int ret;
    if (interactive) {
        ret = run_interactive(p, fft_fd, fft_interval_ms, keep_alive_ms,
                              player_file);
    } else {
        /* 批量模式：阻塞处理 */
        ret = pipeline_run(p);
    }

    if (ret < 0) {
        fprintf(stderr, "[audio-engine] 转码错误: %d\n", ret);
        if (g_pcm_uds) { pcm_uds_destroy(g_pcm_uds); g_pcm_uds = NULL; }
        if (g_stream_uds) { pcm_uds_destroy(g_stream_uds); g_stream_uds = NULL; }
        if (g_ctl_uds) { pcm_uds_destroy(g_ctl_uds); g_ctl_uds = NULL; }
        pipeline_destroy(p);
        return 3;
    }

    fprintf(stderr, "[audio-engine] 转码完成\n");
    if (g_pcm_uds) { pcm_uds_destroy(g_pcm_uds); g_pcm_uds = NULL; }
    if (g_stream_uds) { pcm_uds_destroy(g_stream_uds); g_stream_uds = NULL; }
    if (g_ctl_uds) { pcm_uds_destroy(g_ctl_uds); g_ctl_uds = NULL; }
    pipeline_destroy(p);
    return 0;
}

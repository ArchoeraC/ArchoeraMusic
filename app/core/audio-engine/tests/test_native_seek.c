/**
 * test_native_seek.c — EraAudio 原生内核 offset/seek 回归测试（headless）
 *
 * 覆盖（§bug: 断点续播 offset 起播 / 播放中 seek 在 EraAudio 下失败）：
 *   - 带 SEEKTABLE + PICTURE 的 FLAC（seekpoint stream_offset 为规范「相对首个
 *     音频帧」偏移，音频起点前有大块元数据）：pipeline_create 以 start_offset
 *     起播，自研内核 seek 必须落到真实帧起点并正常解码到 EOF，不返回 Corrupt；
 *   - 不触碰音频输出设备（无 player/pcm_out）：可在无声 CI 上 headless 跑。
 *
 * 旧实现把 seekpoint 偏移当文件绝对偏移，会落进元数据区 → seek Corrupt →
 * pipeline_process 报错，冷启动续播/播放中 seek 直接失败。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_engine.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail = 1;                                                      \
        } else {                                                             \
            fprintf(stderr, "ok   %s\n", msg);                               \
        }                                                                    \
    } while (0)

static int dummy_output(const uint8_t *data, size_t size, void *user)
{
    (void)data; (void)size; (void)user;
    return 0;
}

/* 以指定 offset 起播（自研内核路径）；成功且能解码到 EOF 返回 0。 */
static int run_offset_case(const char *path, int engine_mode, long offset_ms)
{
    EngineConfig cfg = ENGINE_CONFIG_DEFAULT;
    AudioPipeline *p;
    ssize_t n = 1;
    long frames = 0;
    int rc = 0;

    cfg.engine_mode = engine_mode;
    cfg.start_offset_ms = offset_ms;
    cfg.skip_encoder = true; /* 纯解码路径，无 Opus 输出 */

    p = pipeline_create(path, &cfg, dummy_output, NULL);
    if (!p) {
        fprintf(stderr, "pipeline_create 失败 (mode=%d offset=%ld)\n",
                engine_mode, offset_ms);
        return -1;
    }
    while (n > 0) {
        n = pipeline_process(p);
        if (n < 0) {
            fprintf(stderr, "pipeline_process 错误 %zd (mode=%d offset=%ld)\n",
                    n, engine_mode, offset_ms);
            rc = -1;
            break;
        }
        frames += n;
    }
    if (rc == 0 && frames <= 0) {
        fprintf(stderr, "无解码输出 (mode=%d offset=%ld)\n", engine_mode, offset_ms);
        rc = -1;
    }
    pipeline_destroy(p);
    return rc;
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : NULL;
    if (!path) {
        fprintf(stderr, "usage: %s <flac-with-seektable-picture>\n", argv[0]);
        return 2;
    }
    fprintf(stderr, "fixture=%s\n", path);

    /* EraAudio 自研内核：offset 起播（0 / 中间点 / 近尾）均应成功解码到 EOF */
    CHECK(run_offset_case(path, 1, 0) == 0, "EraAudio offset=0 解码到 EOF");
    CHECK(run_offset_case(path, 1, 150) == 0, "EraAudio offset=150ms 解码到 EOF");
    CHECK(run_offset_case(path, 1, 400) == 0, "EraAudio offset=400ms 解码到 EOF");

    /* Stable(FFmpeg) 对照：同 offset 语义不回归 */
    CHECK(run_offset_case(path, 0, 150) == 0, "Stable  offset=150ms 解码到 EOF");

    if (g_fail) {
        fprintf(stderr, "test_native_seek: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_native_seek: ALL PASS\n");
    return 0;
}

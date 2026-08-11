/**
 * test_limiter.c — 限幅器单元测试
 */
#include "../src/limiter.h"
#include <assert.h>
#include <math.h>
#include <stddef.h>

int main(void) {
    Limiter *lim = limiter_create(48000, 2);
    assert(lim != NULL);

    /* 阈值应为 -1dB */
    assert(fabsf(limiter_get_threshold(lim) - (-1.0f)) < 0.01f);

    /* 信号在阈值以下应不变 */
    float pcm[4] = {0.5f, -0.5f, 0.3f, -0.3f};
    limiter_process(lim, pcm, 2);
    assert(fabsf(pcm[0] - 0.5f) < 0.01f);
    assert(fabsf(pcm[1] - (-0.5f)) < 0.01f);

    /* 超大信号应被限制 */
    float clip[4] = {2.0f, -2.0f, 1.5f, -1.5f};
    limiter_process(lim, clip, 2);
    /* 输出应不超过 1.0 */
    for (int i = 0; i < 4; i++) {
        assert(fabsf(clip[i]) <= 1.01f);
    }

    /* 禁用限幅器 */
    limiter_set_enabled(lim, false);
    float pass[4] = {2.0f, -2.0f, 0.5f, -0.5f};
    limiter_process(lim, pass, 2);
    /* 禁用时应原样通过 */
    assert(fabsf(pass[0] - 2.0f) < 0.01f);
    assert(fabsf(pass[1] - (-2.0f)) < 0.01f);

    /* 重新启用并修改阈值 */
    limiter_set_enabled(lim, true);
    limiter_set_threshold(lim, -6.0f);
    assert(fabsf(limiter_get_threshold(lim) - (-6.0f)) < 0.01f);

    float hard_clip[4] = {0.9f, -0.9f, 0.3f, -0.3f};
    limiter_process(lim, hard_clip, 2);
    /* -6dB 阈值 = 0.5 linear，0.9 会被压缩 */
    assert(hard_clip[0] < 0.9f);
    /* 小信号不变 */
    assert(fabsf(hard_clip[2] - 0.3f) < 0.01f);

    limiter_destroy(lim);
    return 0;
}

/**
 * test_loudness.c — 响度归一化单元测试
 */
#include "../src/loudness.h"
#include <assert.h>
#include <math.h>
#include <stdlib.h>

static float randf(void) {
    return (float)rand() / (float)RAND_MAX * 0.1f - 0.05f;
}

int main(void) {
    Loudness *loud = loudness_create(48000, 2);
    assert(loud != NULL);

    /* 默认禁用，处理应不变 */
    float pcm[256];
    for (int i = 0; i < 256; i++) pcm[i] = randf();
    float copy[256];
    for (int i = 0; i < 256; i++) copy[i] = pcm[i];

    loudness_process(loud, pcm, 128);
    for (int i = 0; i < 256; i++) {
        assert(fabsf(pcm[i] - copy[i]) < 0.01f);
    }

    /* 启用并设置增益 */
    loudness_set_enabled(loud, true);
    loudness_set_gain(loud, 3.0f);

    /* 处理应放大信号 */
    for (int i = 0; i < 256; i++) pcm[i] = copy[i] = randf();
    loudness_process(loud, pcm, 128);

    /* 检查至少有一个样本放大了 */
    int amplified = 0;
    for (int i = 0; i < 256; i++) {
        if (fabsf(pcm[i]) > fabsf(copy[i]) + 0.001f) amplified++;
    }
    assert(amplified > 0);

    /* 不应产生 NaN */
    for (int i = 0; i < 256; i++) {
        assert(!isnan(pcm[i]));
        assert(!isinf(pcm[i]));
    }

    /* 禁用后再处理，应还原 */
    loudness_set_enabled(loud, false);
    for (int i = 0; i < 256; i++) pcm[i] = copy[i];
    loudness_process(loud, pcm, 128);
    for (int i = 0; i < 256; i++) {
        assert(fabsf(pcm[i] - copy[i]) < 0.01f);
    }

    loudness_destroy(loud);
    return 0;
}

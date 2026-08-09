/**
 * test_equalizer.c — 均衡器单元测试
 */
#include "../src/equalizer.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static float randf(void) {
    return (float)rand() / (float)RAND_MAX * 2.0f - 1.0f;
}

int main(void) {
    /* 创建 */
    Equalizer *eq = equalizer_create(48000, 2);
    assert(eq != NULL);

    /* 默认增益全零，处理应不改变数据 */
    float processed[256];
    float reference[256];
    for (int i = 0; i < 256; i++) {
        reference[i] = randf();
        processed[i] = reference[i];
    }
    equalizer_process(eq, processed, 128);
    for (int i = 0; i < 256; i++) {
        /* 默认全零增益，输出应近似等于输入 */
        assert(fabsf(processed[i] - reference[i]) < 0.1f);
    }

    /* 设置增益 */
    float gains[EQ_BANDS] = {0, 0, 0, 0, 0, 3, 0, 0, 0, 0};
    equalizer_set_gains(eq, gains);

    /* 处理静音 */
    float silence[256] = {0};
    equalizer_process(eq, silence, 128);
    for (int i = 0; i < 256; i++) {
        assert(silence[i] == 0.0f);
    }

    /* 设置前级增益 */
    equalizer_set_preamp(eq, -3.0f);

    /* 处理数据不应产生 NaN */
    for (int i = 0; i < 256; i++) {
        processed[i] = randf();
    }
    equalizer_process(eq, processed, 128);
    for (int i = 0; i < 256; i++) {
        assert(!isnan(processed[i]));
        assert(!isinf(processed[i]));
    }

    equalizer_destroy(eq);
    return 0;
}

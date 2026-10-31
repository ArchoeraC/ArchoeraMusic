// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * channel_merge.h — 多声道合并（单侧设备兜底）
 *
 * 设备实际只有左/右一侧发声时，立体声内容会漏掉另一侧。本块把交错 PCM
 * 的**所有声道**按等功率（1/√N）求和为单声道，再复制到每一个输出声道，
 * 使任意一侧都能听到完整内容。
 *
 * 整块默认禁用 = 逐位旁通；只做线性混合，限幅交给管线后续的限幅器。
 */
#ifndef CHANNEL_MERGE_H
#define CHANNEL_MERGE_H

#include <stdbool.h>

typedef struct ChannelMerge ChannelMerge;

/** 创建（channels 1..64；失败返回 NULL）。 */
ChannelMerge* channel_merge_create(int channels);

/** 整块启用/禁用（默认禁用 = 逐位旁通）。 */
void channel_merge_set_enabled(ChannelMerge *cm, bool enabled);

/** 就地处理交错 float PCM（samples = 每声道帧数）。 */
void channel_merge_process(ChannelMerge *cm, float *pcm, int samples);

/** 销毁（NULL 空操作）。 */
void channel_merge_destroy(ChannelMerge *cm);

#endif /* CHANNEL_MERGE_H */

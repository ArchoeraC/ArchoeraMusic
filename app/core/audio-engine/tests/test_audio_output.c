// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * test_audio_output.c — 输出设备枚举「名称启发式分类」确定性单测
 *
 * 覆盖 ao_classify_by_name 的类别判定与 ALSA 虚拟设备标记（纯函数，无音频设备依赖）。
 * 平台原生富化（pulse/WASAPI/CoreAudio）需真实系统，不在本测试范围。
 */
#include "audio_output_platform.h"

#include <stdio.h>
#include <string.h>

static int g_fails;

static audio_output make_io(const char *id, const char *name,
                            unsigned rate, unsigned channels, int has_native)
{
    audio_output io;
    memset(&io, 0, sizeof(io));
    ao_copy(io.id, sizeof(io.id), id);
    ao_copy(io.name, sizeof(io.name), name);
    io.sample_rate = rate;
    io.channels = channels;
    io.has_native = has_native;
    return io;
}

static void expect_cls(const char *id, const char *name,
                       unsigned rate, unsigned channels, int want)
{
    audio_output io = make_io(id, name, rate, channels, 1);
    ao_classify_by_name(&io, 0);
    if (io.cls != want) {
        printf("FAIL class id=%s got=%s want=%s\n", id,
               audio_output_class_str(io.cls), audio_output_class_str(want));
        g_fails++;
    }
}

static void expect_virtual(const char *id, int allow, uint32_t want_flag)
{
    audio_output io = make_io(id, id, 48000, 2, 1);
    ao_classify_by_name(&io, allow);
    if ((io.flags & want_flag) != want_flag) {
        printf("FAIL flag id=%s flags=0x%x want=0x%x\n", id, io.flags, want_flag);
        g_fails++;
    }
}

int main(void)
{
    /* 蓝牙：A2DP（立体声）与 HFP（单声道/低采样或 headset 特征） */
    expect_cls("bluez_sink.AA_BB.a2dp-sink", "BT Speaker",
               48000, 2, AUDIO_OUTPUT_CLASS_A2DP);
    expect_cls("bluez_sink.AA_BB.headset-head-unit", "BT Hands-Free",
               16000, 1, AUDIO_OUTPUT_CLASS_HFP);

    /* HDMI / USB / 内置模拟 / 未知 */
    expect_cls("alsa_output.pci-0000_00_1f.3.hdmi-stereo", "HDMI",
               48000, 2, AUDIO_OUTPUT_CLASS_HDMI);
    expect_cls("alsa_output.usb-Generic_USB_Audio", "USB DAC",
               48000, 2, AUDIO_OUTPUT_CLASS_USB);
    expect_cls("alsa_output.pci-0000_00_1f.3.analog-stereo", "Analog Stereo",
               48000, 2, AUDIO_OUTPUT_CLASS_INTERNAL);
    expect_cls("alsa_output.platform-foo", "Mystery",
               48000, 2, AUDIO_OUTPUT_CLASS_UNKNOWN);

    /* 低质非蓝牙 → LOW（低采样/单声道） */
    expect_cls("alsa_output.foo.bar", "Generic Mono",
               44100, 1, AUDIO_OUTPUT_CLASS_LOW);

    /* 无 native 信息（has_native=0）不应误判为低质 */
    {
        audio_output io = make_io("alsa_output.pci.foo.analog-stereo",
                                  "Analog", 0, 0, 0);
        ao_classify_by_name(&io, 0);
        if (io.cls != AUDIO_OUTPUT_CLASS_INTERNAL) {
            printf("FAIL no-native got=%s\n", audio_output_class_str(io.cls));
            g_fails++;
        }
    }

    /* ALSA 回退：虚拟/伪设备标记（pulse 路径下 allow=0 不应标记） */
    expect_virtual("null", 1, AUDIO_OUTPUT_F_VIRTUAL);
    expect_virtual("alsa_output.foo.monitor", 1, AUDIO_OUTPUT_F_MONITOR);
    {
        audio_output io = make_io("null", "Null Output", 48000, 2, 1);
        ao_classify_by_name(&io, 0);
        if (io.flags & AUDIO_OUTPUT_F_VIRTUAL) {
            printf("FAIL virtual marked when allow=0\n");
            g_fails++;
        }
    }

    /* class 枚举 → 稳定字符串 */
    if (strcmp(audio_output_class_str(AUDIO_OUTPUT_CLASS_HDMI), "hdmi") != 0 ||
        strcmp(audio_output_class_str(AUDIO_OUTPUT_CLASS_HFP), "hfp") != 0 ||
        strcmp(audio_output_class_str(AUDIO_OUTPUT_CLASS_VIRTUAL), "virtual") != 0 ||
        strcmp(audio_output_class_str(AUDIO_OUTPUT_CLASS_UNKNOWN), "unknown") != 0) {
        printf("FAIL class_str mapping\n");
        g_fails++;
    }

    if (g_fails) {
        printf("FAILED %d check(s)\n", g_fails);
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}

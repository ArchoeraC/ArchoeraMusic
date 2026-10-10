// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Runtime.InteropServices;

namespace Archoera.Scanner;

/// <summary>
/// 自研内核离线 EBU R128 集成响度测量直桥（docs/audio-kernel-zig.md §14；
/// ITU-R BS.1770-4）。
///
/// 通过结构化 C ABI（zk_loudness_measure，**非 JSON、无子进程**）一次解码并测量
/// 集成响度 + 线性采样峰值，写入曲库 `loudness_lufs` / `loudness_peak`，作为无
/// ReplayGain 标签文件的兜底归一化增益来源。
///
/// 仅在 scanner 以 `--analyze-loudness` 扫描时调用（默认关闭，避免拖慢常规扫描）。
/// 内核动态库定位/解析复用 <see cref="KernelMetadata"/> 的 DllImportResolver
/// （同一程序集、同一库名 archoera_kernel）。
/// </summary>
public static class KernelLoudness
{
    /* ---- 原生结构（与 kernel_bridge.h / kernel.zig CLoudnessResult 逐字段一致）---- */

    [StructLayout(LayoutKind.Sequential)]
    private struct ZkLoudnessResult
    {
        public double IntegratedLufs;
        public double Peak;
        public int Valid;
    }

    private const string LibName = "archoera_kernel";

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int zk_loudness_measure(IntPtr path, out ZkLoudnessResult outResult);

    private static bool _loadFailed;

    /// <summary>内核原生库是否可用（首次调用失败后缓存为不可用）。</summary>
    public static bool Available
    {
        get
        {
            KernelMetadata.EnsureResolver();
            return !_loadFailed;
        }
    }

    /// <summary>
    /// 测量结果（托管快照）。<see cref="Valid"/> = false 表示无通过绝对门限的
    /// 400 ms 块（静音 / 时长不足），此时不应写入响度列。
    /// </summary>
    public readonly record struct Result(double IntegratedLufs, double Peak, bool Valid);

    /// <summary>
    /// 解码并测量文件响度。内核不可用 / 打开失败 / 未接管格式 / 内存不足 → 返回
    /// null（调用方跳过，写入 NULL）。返回的非 null 结果可能 Valid=false。
    /// </summary>
    public static Result? TryMeasure(string filePath)
    {
        KernelMetadata.EnsureResolver();
        if (_loadFailed) return null;

        IntPtr path = IntPtr.Zero;
        try
        {
            path = Marshal.StringToCoTaskMemUTF8(filePath);
            var rc = zk_loudness_measure(path, out var raw);
            if (rc != 0) return null;
            return new Result(raw.IntegratedLufs, raw.Peak, raw.Valid != 0);
        }
        catch (DllNotFoundException)
        {
            _loadFailed = true;
            return null;
        }
        catch (EntryPointNotFoundException)
        {
            // 旧内核库无该导出：视为不可用，避免每次文件重复抛异常。
            _loadFailed = true;
            return null;
        }
        finally
        {
            if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path);
        }
    }
}

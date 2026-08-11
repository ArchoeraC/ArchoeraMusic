using System.Globalization;
using System.Runtime.InteropServices;

namespace Archoera.Scanner;

/// <summary>
/// 系统内存信息工具
///
/// 提供跨平台（Linux / Windows）的物理内存总量和可用内存读取。
/// 读取失败时静默返回 0，由调用方自行降级处理。
/// </summary>
public static class SystemMemoryInfo
{
    /// <summary>
    /// 获取总物理内存（MB）。0 表示获取失败。
    /// </summary>
    public static long GetTotalPhysicalMemoryMb()
    {
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                var totalKb = ReadMeminfoValue("MemTotal:");
                if (totalKb > 0)
                    return totalKb / 1024; // kB → MB
            }
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                var info = GC.GetGCMemoryInfo();
                return info.TotalAvailableMemoryBytes / (1024 * 1024);
            }
        }
        catch
        {
            // 权限不足/文件不存在时静默降级
        }
        return 0;
    }

    /// <summary>
    /// 获取当前可用内存（MB）。0 表示获取失败。
    /// </summary>
    public static long GetAvailableMemoryMb()
    {
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                var availKb = ReadMeminfoValue("MemAvailable:");
                if (availKb > 0)
                    return availKb / 1024;
            }
        }
        catch { }
        return 0;
    }

    /// <summary>
    /// 从 /proc/meminfo 读取指定键的值（kB）
    /// </summary>
    private static long ReadMeminfoValue(string key)
    {
        var lines = File.ReadAllLines("/proc/meminfo");
        foreach (var line in lines)
        {
            if (line.StartsWith(key, StringComparison.Ordinal))
            {
                var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length >= 2
                    && long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var kb))
                {
                    return kb;
                }
            }
        }
        return 0;
    }
}

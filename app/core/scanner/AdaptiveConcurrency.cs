namespace Archoera.Scanner;

/// <summary>
/// 自适应并发度计算
///
/// 根据设备硬件质量动态决定合理的并行度，而非使用固定值。
/// 考虑因素（按优先级）：
///   1. CPU 核心数（基数）
///   2. 总物理内存（设备档次：低端 ＜2GB / 中端 2-8GB / 高端 ＞8GB）
///   3. 可用内存比例（低内存时降低并发）
///   4. 工作类型 (I/O bound 可用更高并发，CPU bound 应贴近核心数)
///
/// 上限 64，下限 1，默认 2。
/// </summary>
public static class AdaptiveConcurrency
{
    /// <summary>
    /// 获取适合 I/O bound 类型工作的并行度（HTTP 请求、文件解析等）
    /// </summary>
    /// <param name="cpuBound">若为 CPU 密集工作请设为 true，否则按 I/O bound 计算</param>
    /// <param name="maxOverride">环境变量指定的上限（0 表示不限制）</param>
    public static int ForIOBound(int maxOverride = 0)
    {
        return Compute(isCpuBound: false, maxOverride);
    }

    /// <summary>
    /// 获取适合 CPU bound 类型工作的并行度
    /// </summary>
    public static int ForCPUBound(int maxOverride = 0)
    {
        return Compute(isCpuBound: true, maxOverride);
    }

    private static int Compute(bool isCpuBound, int maxOverride)
    {
        var cpuCount = Environment.ProcessorCount;
        var totalMemMb = SystemMemoryInfo.GetTotalPhysicalMemoryMb();
        var availableMemMb = SystemMemoryInfo.GetAvailableMemoryMb();

        // 1) CPU 基数
        var baseParallelism = isCpuBound
            ? Math.Max(1, cpuCount)               // CPU bound：贴近核心数
            : Math.Max(2, (cpuCount + 1) / 2);    // I/O bound：可超线程，但留余量

        // 2) 内存系数（每 worker 估算需要的内存）
        const int memPerWorkerMb = 256;  // 每个并发 worker 留 256MB 余量
        var memCap = totalMemMb > 0
            ? Math.Max(1, totalMemMb / memPerWorkerMb)
            : int.MaxValue;  // 获取不到内存则不限制

        // 3) 可用内存比例（低于 20% 可用时主动降级）
        var availRatio = totalMemMb > 0
            ? (double)availableMemMb / totalMemMb
            : 1.0;
        var memoryPressure = availRatio < 0.2
            ? 0.5   // 严重不足 → 砍半
            : availRatio < 0.4
                ? 0.75 // 偏紧 → 打七五折
                : 1.0;

        // 4) 设备等级上限（防止低端设备开太高）
        int deviceCap = totalMemMb switch
        {
            < 0    => 8,     // 获取不到，保守 8
            < 1024 => 2,     // ＜1GB：极低端
            < 2048 => 4,     // 1-2GB：低端
            < 4096 => 8,     // 2-4GB：入门
            < 8192 => 16,    // 4-8GB：中端
            _      => 64,    // ＞8GB：高端
        };

        // 5) 综合计算
        var raw = baseParallelism * memoryPressure;
        var result = (int)Math.Round(raw);

        // 依次施加各上限，取最小值
        result = Math.Min(result, (int)Math.Min(memCap, int.MaxValue));
        result = Math.Min(result, deviceCap);

        // 6) 环境变量覆盖（仅降低，不提高——安全原则）
        if (maxOverride > 0)
            result = Math.Min(result, maxOverride);

        return Math.Clamp(result, 1, 64);
    }

}

namespace Archoera.Scanner;

/// <summary>
/// 自适应批量写入大小
///
/// 综合两方面因素动态决定每次写入多少条：
///   1. 系统内存状况（初始估计 + 安全上限）
///   2. 实际写入耗时反馈（快则加大，慢则减小）
///
/// 目标：每批写入耗时在 ~300ms 左右的甜点区间，兼顾吞吐和延迟。
/// 下限 10，上限 10000（单批暴力上限，实际仍受 _memoryCap 安全约束）。
/// </summary>
public class AdaptiveBatchSize
{
    /// <summary>最小批量</summary>
    public const int MinBatchSize = 10;

    /// <summary>最大批量</summary>
    public const int MaxBatchSize = 10000;

    /// <summary>默认初始批量（获取不到内存信息时）</summary>
    public const int DefaultBatchSize = 50;

    /// <summary>目标写入耗时（ms），控制器会尽量让每批写入稳定在这个时间附近</summary>
    private const double TargetWriteMs = 300;

    /// <summary>连续同方向调整 N 次后才放大步长（×0.5），否则小步（×0.25），防止抖动</summary>
    private const int ConsecutiveDampen = 3;

    private readonly int _userMax;

    /// <summary>基于内存计算的设备安全上限</summary>
    private readonly int _memoryCap;

    /// <summary>连续同方向调整计数（正=连续加速，负=连续减速）</summary>
    private int _consecutiveDirection;

    public AdaptiveBatchSize(int userMax = 0)
    {
        _userMax = userMax;
        _memoryCap = ComputeMemoryCap();
    }

    /// <summary>
    /// 根据内存状况给出初始批量推荐，作为写入线程起步值。
    /// </summary>
    public int Initial()
    {
        var batch = Math.Min(DefaultBatchSize * 2, _memoryCap);
        if (_userMax > 0)
            batch = Math.Min(batch, _userMax);
        return Math.Clamp(batch, MinBatchSize, MaxBatchSize);
    }

    /// <summary>
    /// 根据上一批写入的实际耗时，动态调整批量大小。
    /// 调用方每次 FlushBatch 后调用此方法。
    /// </summary>
    /// <param name="currentSize">当前批量大小</param>
    /// <param name="elapsedMs">上批写入耗时（ms）</param>
    /// <returns>调整后的批量大小</returns>
    public int Adjust(int currentSize, double elapsedMs)
    {
        // 计算每条的均摊耗时，用于消除批量大小本身对耗时的影响
        var perTrackMs = elapsedMs / Math.Max(1, currentSize);

        // 反推：如果按目标耗时跑，应该写多少条
        var ideal = (int)Math.Round(TargetWriteMs / Math.Max(perTrackMs, 0.001));

        // 阻尼：连续同方向时才放大步长，防止抖动
        int direction = ideal > currentSize ? 1 : (ideal < currentSize ? -1 : 0);
        if (direction == Math.Sign(_consecutiveDirection))
            _consecutiveDirection += direction;
        else
            _consecutiveDirection = direction;

        double factor = Math.Abs(_consecutiveDirection) >= ConsecutiveDampen ? 0.5 : 0.25;
        var next = (int)Math.Round(currentSize + (ideal - currentSize) * factor);

        // 施加安全约束
        next = Math.Clamp(next, MinBatchSize, MaxBatchSize);
        next = Math.Min(next, _memoryCap);
        if (_userMax > 0)
            next = Math.Min(next, _userMax);

        // 最少变化 1 条，否则不调整
        if (Math.Abs(next - currentSize) < 1)
            return currentSize;

        return next;
    }

    /// <summary>
    /// 基于内存计算设备安全上限
    /// </summary>
    private static int ComputeMemoryCap()
    {
        var totalMemMb = SystemMemoryInfo.GetTotalPhysicalMemoryMb();
        var availableMemMb = SystemMemoryInfo.GetAvailableMemoryMb();

        // 设备理想上限（基于总内存）
        int deviceCap = totalMemMb switch
        {
            < 0    => 100,
            < 1024 => 50,
            < 2048 => 100,
            < 4096 => 250,
            < 8192 => 1000,
            _      => MaxBatchSize,
        };

        // 可用内存压力系数
        var availRatio = totalMemMb > 0
            ? (double)availableMemMb / totalMemMb
            : 1.0;
        double pressureFactor = availRatio switch
        {
            < 0.10 => 0.25,
            < 0.20 => 0.40,
            < 0.35 => 0.60,
            < 0.50 => 0.80,
            _      => 1.00,
        };

        return Math.Max(MinBatchSize, (int)(deviceCap * pressureFactor));
    }
}

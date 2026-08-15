using System.Runtime.InteropServices;

namespace Archoera.Vault;

/// 运行时内存保护（credential-vault-plan §3.6 三平台映射）：
/// 密钥/短时明文缓冲 mlock 禁 swap + 销毁时 zeroize + munlock。
///
/// 只锁关键小区域（主密钥份额、单条明文缓冲），不锁全进程——
/// 规避 RLIMIT_MEMLOCK 默认上限（Linux 8KB）与性能影响。
public sealed unsafe class LockedBuffer : IDisposable
{
    private byte* _ptr;
    private readonly nint _len;
    private bool _disposed;

    private LockedBuffer(byte* ptr, nint len)
    {
        _ptr = ptr;
        _len = len;
    }

    /// 当前缓冲（读写前应确认未释放）。
    public Span<byte> Span => new(_ptr, (int)_len);

    /// 分配并 mlock 一段内存；mlock 失败（无权限/上限不足）不静默——抛异常，
    /// 由上层决定降级路径（安全上下文宁可失败也不静默放弃）。
    public static LockedBuffer Alloc(int size)
    {
        var ptr = (byte*)NativeMemory.Alloc((nuint)size);
        try
        {
            new Span<byte>(ptr, size).Clear();
            if (MlockFailed(ptr, (nuint)size))
            {
                throw new InvalidOperationException(
                    $"mlock 失败（errno={Marshal.GetLastPInvokeError()}）：内存保护不可用");
            }
            return new LockedBuffer(ptr, size);
        }
        catch
        {
            NativeMemory.Free(ptr);
            throw;
        }
    }

    /// 销毁：zeroize → munlock → 释放。幂等。
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_ptr == null) return;
        new Span<byte>(_ptr, (int)_len).Clear();
        Munlock(_ptr, (nuint)_len);
        NativeMemory.Free(_ptr);
        _ptr = null;
    }

    private static readonly bool IsWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    [DllImport("libc", EntryPoint = "mlock", SetLastError = true)]
    private static extern int mlock_nix(byte* addr, nuint len);

    [DllImport("libc", EntryPoint = "munlock", SetLastError = true)]
    private static extern int munlock_nix(byte* addr, nuint len);

    [DllImport("kernel32.dll", EntryPoint = "VirtualLock", SetLastError = true)]
    private static extern int virtual_lock(byte* addr, nuint len);

    [DllImport("kernel32.dll", EntryPoint = "VirtualUnlock", SetLastError = true)]
    private static extern int virtual_unlock(byte* addr, nuint len);

    // 平台返回语义相反（2026-08-15 修复实录）：
    //   Windows VirtualLock 成功返回非 0、失败返回 0；
    //   Linux mlock 成功返回 0、失败返回 -1。
    // 按 Linux 语义 `!= 0` 判失败会让 Windows 必然误报「mlock 失败」。
    private static bool MlockFailed(byte* addr, nuint len) =>
        IsWindows ? virtual_lock(addr, len) == 0 : mlock_nix(addr, len) != 0;

    private static int Munlock(byte* addr, nuint len) =>
        IsWindows ? virtual_unlock(addr, len) : munlock_nix(addr, len);
}

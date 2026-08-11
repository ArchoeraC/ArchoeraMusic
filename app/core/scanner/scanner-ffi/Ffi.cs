using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Archoera.Scanner.Ffi;

/// <summary>
/// NativeAOT 导出层：供 Flutter 通过 FFI 直接调用本地音乐扫描。
///
/// 与 CLI（Program.cs）共用同一套 ScannerEngine / SqliteDirectWriter 源码，
/// 差异仅在进度上报（CLI=stdout JSON，FFI=回调函数指针）与取消
/// （CLI=SIGINT，FFI=scanner_cancel）。
///
/// ABI（对齐 Dart FFI 绑定，C 调用约定）：
///   int  scanner_scan(
///       const char* dirs_json,       // ["/dir1","/dir2"]（UTF-8 JSON）
///       const char* db_path,         // SQLite 库文件路径
///       const char* cover_dir,       // 封面缓存目录
///       const char* quarantine_dir,  // 损坏文件隔离目录
///       int incremental,             // 1=增量 0=全量
///       int batch,                   // 批量上限（0=自适应）
///       int max_parallelism,         // 并行解析数（0=自适应）
///       void (*on_progress)(const char* json),  // 进度 JSON（UTF-8；读后调 scanner_free）
///       const char** out_result,     // 成功=ScanResult JSON，失败=错误文本（读后调 scanner_free）
///       int* out_len)                // 结果字节数
///   int  scanner_cancel()            // 请求取消进行中的扫描（0=已请求，1=无进行中扫描）
///   void scanner_free(const char* ptr)  // 释放本模块 NativeMemory.Alloc 分配的内存
/// </summary>
public static unsafe class ScannerFfi
{
    /// <summary>进行中的扫描 CTS（scanner_cancel 从任意线程取消）</summary>
    private static CancellationTokenSource? _currentScanCts;

    [UnmanagedCallersOnly(EntryPoint = "scanner_scan")]
    public static int Scan(
        byte* dirsJson,
        byte* dbPath,
        byte* coverDir,
        byte* quarantineDir,
        int incremental,
        int batch,
        int maxParallelism,
        delegate* unmanaged[Cdecl]<byte*, void> onProgress,
        byte** outResult,
        int* outLen)
    {
        *outResult = null;
        *outLen = 0;
        try
        {
            var dirs = DeserializeStringArray(dirsJson);
            var dbPathStr = PtrToString(dbPath);
            var coverDirStr = PtrToString(coverDir);
            var quarantineDirStr = PtrToString(quarantineDir);

            if (dirs.Count == 0)
                return Fail(outResult, outLen, "dirs_json 为空");
            if (string.IsNullOrEmpty(dbPathStr))
                return Fail(outResult, outLen, "db_path 为空");

            var dbDir = Path.GetDirectoryName(dbPathStr) ?? ".";
            using var db = new SqliteDirectWriter(dbPathStr);
            var engine = new ScannerEngine(
                db,
                coverDirStr ?? Path.Combine(dbDir, "cache", "covers"),
                quarantineDirStr ?? Path.Combine(dbDir, "quarantine"),
                batchSize: batch,
                incremental: incremental != 0,
                maxParallelism: maxParallelism > 0 ? maxParallelism : null,
                progressSink: onProgress != null
                    ? (Action<ScanProgress>)(p => FireProgress(onProgress, p))
                    : null);

            using var cts = new CancellationTokenSource();
            Interlocked.Exchange(ref _currentScanCts, cts);
            try
            {
                // UnmanagedCallersOnly 不能 async；在后台线程执行异步引擎并阻塞等待
                var result = Task.Run(() => engine.ScanAsync(dirs, cts.Token), cts.Token)
                    .GetAwaiter().GetResult();
                SetUtf8(outResult, outLen,
                    JsonSerializer.Serialize(result, ScannerJsonContext.Default.ScanResult));
                return 0;
            }
            finally
            {
                Interlocked.Exchange(ref _currentScanCts, null);
            }
        }
        catch (OperationCanceledException)
        {
            return Fail(outResult, outLen, "canceled");
        }
        catch (Exception ex)
        {
            return Fail(outResult, outLen, ex.Message);
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "scanner_cancel")]
    public static int Cancel()
    {
        var cts = Volatile.Read(ref _currentScanCts);
        if (cts == null) return 1;
        cts.Cancel();
        return 0;
    }

    [UnmanagedCallersOnly(EntryPoint = "scanner_free")]
    public static void Free(byte* ptr)
    {
        if (ptr != null) NativeMemory.Free(ptr);
    }

    /* ------------------------------------------------------------------ */
    /* 工具                                                                */
    /* ------------------------------------------------------------------ */

    private static void FireProgress(delegate* unmanaged[Cdecl]<byte*, void> cb, ScanProgress p)
    {
        var json = JsonSerializer.Serialize(p, ScannerJsonContext.Default.ScanProgress);
        var bytes = Encoding.UTF8.GetBytes(json);
        var ptr = (byte*)NativeMemory.Alloc((nuint)bytes.Length + 1);
        Marshal.Copy(bytes, 0, (IntPtr)ptr, bytes.Length);
        ptr[bytes.Length] = 0;
        cb(ptr);
    }

    private static List<string> DeserializeStringArray(byte* json)
    {
        if (json == null) return new List<string>();
        var text = new string((sbyte*)json);
        try
        {
            var arr = JsonSerializer.Deserialize(text, ScannerJsonContext.Default.StringArray);
            return arr == null ? new List<string>() : arr.ToList();
        }
        catch
        {
            return new List<string> { text };
        }
    }

    private static string? PtrToString(byte* ptr)
        => ptr == null ? null : Marshal.PtrToStringUTF8((IntPtr)ptr);

    private static void SetUtf8(byte** dst, int* len, string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        var ptr = (byte*)NativeMemory.Alloc((nuint)bytes.Length + 1);
        Marshal.Copy(bytes, 0, (IntPtr)ptr, bytes.Length);
        ptr[bytes.Length] = 0;
        *dst = ptr;
        *len = bytes.Length;
    }

    private static int Fail(byte** dst, int* len, string message)
    {
        SetUtf8(dst, len, message);
        return 1;
    }
}

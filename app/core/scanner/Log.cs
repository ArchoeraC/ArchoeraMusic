// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Runtime.InteropServices;
using System.Text;

namespace Archoera.Scanner;

/// <summary>
/// 扫描器统一日志门面。
///
/// 宿主（Dart）在载入 scanner-ffi 后，经 <c>scanner_set_log_sink</c> 注入
/// <c>libarchoera_log</c> 的 <c>archoera_log_write</c> 指针，扫描器日志即走
/// 统一格式/落盘；未注入时（CLI / 测试）回退 stderr，格式与统一日志核心一致：
/// <c>[HH:mm:ss LEVEL] [tag] message</c>（本地时间）。
///
/// 级别数值对齐 <c>app/native/log/include/archoera_log.h</c>：0=DEBUG..4=FATAL。
/// 调用方（ScannerEngine / SqliteDirectWriter / Program）只需传 tag + 消息；
/// sink 调用约定为 C：<c>void (*)(int level, const char *tag, const char *message)</c>。
/// </summary>
public static class Log
{
    /// <summary>日志级别常量（数值对齐 archoera_log.h）。</summary>
    public const int Debug = 0;
    public const int Info = 1;
    public const int Warn = 2;
    public const int Error = 3;
    public const int Fatal = 4;

    /// <summary>注入的 sink 函数指针（0 = 未注入，回退 stderr）。</summary>
    private static nint _sink;

    /// <summary>最小级别（低于此级别直接丢弃，与统一核心的二次过滤一致）。</summary>
    private static int _minLevel = Info;

    /// <summary>
    /// 注入/注销统一日志 sink（由 scanner-ffi 的 <c>scanner_set_log_sink</c> 调用）。
    /// sink=NULL 注销并回退 stderr；[minLevel] 越界时收敛到 0..4。幂等，可随时调用。
    /// </summary>
    public static unsafe void SetSink(
        delegate* unmanaged[Cdecl]<int, byte*, byte*, void> sink, int minLevel)
    {
        Volatile.Write(ref _minLevel, Clamp(minLevel));
        Volatile.Write(ref _sink, (nint)sink);
    }

    public static void LogDebug(string tag, string message) => Write(Debug, tag, message);
    public static void LogInfo(string tag, string message) => Write(Info, tag, message);
    public static void LogWarn(string tag, string message) => Write(Warn, tag, message);
    public static void LogError(string tag, string message) => Write(Error, tag, message);
    public static void LogFatal(string tag, string message) => Write(Fatal, tag, message);

    /// <summary>按级别写出：有 sink 走 sink（UTF-8 传参，sink 同步复制），否则回退 stderr。</summary>
    public static unsafe void Write(int level, string? tag, string? message)
    {
        if (level < Volatile.Read(ref _minLevel)) return;

        var raw = Volatile.Read(ref _sink);
        if (raw != 0)
        {
            var sink = (delegate* unmanaged[Cdecl]<int, byte*, byte*, void>)raw;
            var tagPtr = AllocUtf8(tag);
            var msgPtr = AllocUtf8(message);
            try
            {
                sink(level, tagPtr, msgPtr);
            }
            finally
            {
                if (tagPtr != null) NativeMemory.Free(tagPtr);
                if (msgPtr != null) NativeMemory.Free(msgPtr);
            }
            return;
        }

        Console.Error.WriteLine(FormatFallback(level, tag, message));
    }

    /// <summary>无 sink 时的等价格式化（不含颜色，与统一核心的纯文本行一致）。</summary>
    private static string FormatFallback(int level, string? tag, string? message)
    {
        var now = DateTime.Now;
        var body = string.IsNullOrEmpty(tag)
            ? (message ?? string.Empty)
            : $"[{tag}] {message ?? string.Empty}";
        return $"[{now:HH:mm:ss} {LevelName(level)}] {body}";
    }

    private static string LevelName(int level) => level switch
    {
        Debug => "DEBUG",
        Info => "INFO",
        Warn => "WARN",
        Error => "ERROR",
        Fatal => "FATAL",
        _ => "INFO",
    };

    private static int Clamp(int level) => level < Debug ? Debug : (level > Fatal ? Fatal : level);

    /// <summary>UTF-8 编码到非托管内存（null 终止）；[s] 为 null 时返回 null。</summary>
    private static unsafe byte* AllocUtf8(string? s)
    {
        if (s is null) return null;
        var bytes = Encoding.UTF8.GetBytes(s);
        var ptr = (byte*)NativeMemory.Alloc((nuint)bytes.Length + 1);
        Marshal.Copy(bytes, 0, (IntPtr)ptr, bytes.Length);
        ptr[bytes.Length] = 0;
        return ptr;
    }
}

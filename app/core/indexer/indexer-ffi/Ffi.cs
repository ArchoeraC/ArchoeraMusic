// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Archoera.Indexer.Ffi;

/// <summary>
/// NativeAOT 导出层：供 Flutter 通过 FFI 直接调用本地曲库搜索索引器。
///
/// 与 CLI（Program.cs）共用同一套 IndexerEngine / FtsStore 源码，
/// 差异仅在进度上报（CLI=stdout JSON，FFI=回调函数指针）与取消
/// （CLI=SIGINT，FFI=indexer_cancel）。
///
/// ABI（对齐 Dart FFI 绑定，C 调用约定）：
///   int  indexer_run(
///       const char* db_path,          // library.db（只读）
///       const char* index_path,       // search.db
///       int full,                     // 1=重建 0=增量
///       const char* options_json,     // {"index_lrc":false,"pinyin":true,"batch":0}
///       void (*on_progress)(const char* json),  // 进度 JSON（UTF-8）
///       const char** out_result,      // 成功=IndexerResult JSON，失败=错误文本（读后调 indexer_free）
///       int* out_len)                 // 结果字节数
///   int  indexer_cancel()             // 请求取消进行中的构建（0=已请求，1=无进行中）
///   void indexer_free(const char* ptr)           // 释放本模块 NativeMemory.Alloc 分配的内存
///   int  indexer_analyze(const char* text, int field,
///                        const char** out_tokens, int* out_len)
///                                     // 查询侧分析（P4：含连写全拼切分），
///                                     // out_tokens = {"tokens","pinyin","initials"} JSON
///   void indexer_set_log_sink(void (*sink)(int, const char*, const char*), int minLevel)
///                                     // 注入统一日志 sink（archoera_log_write）；NULL 注销
/// </summary>
public static unsafe class IndexerFfi
{
    /// <summary>进行中的构建 CTS（indexer_cancel 从任意线程取消）。</summary>
    private static CancellationTokenSource? _currentCts;

    [UnmanagedCallersOnly(EntryPoint = "indexer_run")]
    public static int Run(
        byte* dbPath,
        byte* indexPath,
        int full,
        byte* optionsJson,
        delegate* unmanaged[Cdecl]<byte*, void> onProgress,
        byte** outResult,
        int* outLen)
    {
        *outResult = null;
        *outLen = 0;
        try
        {
            var dbPathStr = PtrToString(dbPath);
            var indexPathStr = PtrToString(indexPath);
            if (string.IsNullOrEmpty(dbPathStr))
                return Fail(outResult, outLen, "db_path 为空");
            if (string.IsNullOrEmpty(indexPathStr))
                return Fail(outResult, outLen, "index_path 为空");
            if (!File.Exists(dbPathStr))
                return Fail(outResult, outLen, $"源曲库不存在: {dbPathStr}");

            if (!TryParseOptions(optionsJson, out var options, out var error))
                return Fail(outResult, outLen, error);

            using var store = new FtsStore();
            var engine = new IndexerEngine(store, onProgress != null
                ? p => FireProgress(onProgress, p)
                : null);

            using var cts = new CancellationTokenSource();
            Interlocked.Exchange(ref _currentCts, cts);
            try
            {
                var result = engine.Run(dbPathStr, indexPathStr, full != 0, options, cts.Token);
                SetUtf8(outResult, outLen, IndexerJson.Result(result));
                return 0;
            }
            finally
            {
                Interlocked.Exchange(ref _currentCts, null);
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

    [UnmanagedCallersOnly(EntryPoint = "indexer_cancel")]
    public static int Cancel()
    {
        var cts = Volatile.Read(ref _currentCts);
        if (cts == null) return 1;
        cts.Cancel();
        return 0;
    }

    [UnmanagedCallersOnly(EntryPoint = "indexer_free")]
    public static void Free(byte* ptr)
    {
        if (ptr != null) NativeMemory.Free(ptr);
    }

    [UnmanagedCallersOnly(EntryPoint = "indexer_analyze")]
    public static int Analyze(byte* text, int field, byte** outTokens, int* outLen)
    {
        *outTokens = null;
        *outLen = 0;
        try
        {
            var value = PtrToString(text);
            if (value is null) return Fail(outTokens, outLen, "text 为空");
            if (field < 0 || field > (int)Field.Filename)
                return Fail(outTokens, outLen, $"非法 field: {field}");
            // 查询侧分析（P4）：含连写全拼切分（woaini → wo ai ni）；
            // 索引侧词元输出随 v4（拼音改走 ToolGood.Words 词级消歧）变化，AnalyzerVersion 已递增。
            SetUtf8(outTokens, outLen, IndexerJson.Analysis(Analyzer.AnalyzeQuery(value)));
            return 0;
        }
        catch (Exception ex)
        {
            return Fail(outTokens, outLen, ex.Message);
        }
    }

    /// <summary>
    /// 注入统一日志 sink（宿主 Dart 传入 libarchoera_log 的 archoera_log_write 指针）。
    /// 调用约定 C：void (*)(int level, const char* tag, const char* message)。
    /// sink=NULL 注销并回退 stderr；[minLevel] 数值对齐 archoera_log.h：0..4。
    /// </summary>
    [UnmanagedCallersOnly(EntryPoint = "indexer_set_log_sink")]
    public static void SetLogSink(
        delegate* unmanaged[Cdecl]<int, byte*, byte*, void> sink, int minLevel)
    {
        Log.SetSink(sink, minLevel);
    }

    /* ------------------------------------------------------------------ */
    /* 工具                                                                */
    /* ------------------------------------------------------------------ */

    /// <summary>
    /// 解析 <c>options_json</c>：未知键忽略；非法 JSON 返回 <c>false</c> 与错误文本。
    /// 缺省：index_lrc=false、pinyin=true、batch=0。
    /// </summary>
    private static bool TryParseOptions(byte* optionsJson, out IndexerOptions options, out string error)
    {
        options = new IndexerOptions();
        error = "";
        if (optionsJson == null) return true;

        var raw = PtrToString(optionsJson);
        if (string.IsNullOrWhiteSpace(raw)) return true;

        try
        {
            using var doc = JsonDocument.Parse(raw);
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
            {
                error = "options_json 必须是 JSON 对象";
                return false;
            }
            var root = doc.RootElement;
            if (root.TryGetProperty("index_lrc", out var lrc)
                && (lrc.ValueKind == JsonValueKind.True || lrc.ValueKind == JsonValueKind.False))
                options.IndexLrc = lrc.GetBoolean();
            if (root.TryGetProperty("pinyin", out var py)
                && (py.ValueKind == JsonValueKind.True || py.ValueKind == JsonValueKind.False))
                options.Pinyin = py.GetBoolean();
            if (root.TryGetProperty("batch", out var batch) && batch.ValueKind == JsonValueKind.Number)
                options.Batch = batch.GetInt32();
            return true;
        }
        catch (JsonException ex)
        {
            error = $"options_json 非法: {ex.Message}";
            return false;
        }
    }

    private static void FireProgress(delegate* unmanaged[Cdecl]<byte*, void> cb, IndexerProgress p)
    {
        var json = IndexerJson.Progress(p);
        var bytes = Encoding.UTF8.GetBytes(json);
        var ptr = (byte*)NativeMemory.Alloc((nuint)bytes.Length + 1);
        Marshal.Copy(bytes, 0, (IntPtr)ptr, bytes.Length);
        ptr[bytes.Length] = 0;
        cb(ptr);
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

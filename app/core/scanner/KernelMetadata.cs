// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Runtime.InteropServices;

namespace Archoera.Scanner;

/// <summary>
/// 自研内核元数据快路径直桥（docs/audio-kernel-zig.md §8.4.2①）。
///
/// 通过结构化 C ABI（zk_metadata_*，**非 JSON**）一次取回标量 + 全量标签 + 首张
/// 封面，不触发 PCM 解码。scanner 优先用内核解析支持格式，失败/不支持时回退
/// TagLibSharp（见 ScannerEngine.ParseFile）。
///
/// 并发协商：scanner 依据自身指标（AdaptiveConcurrency/内存）算出并行度后调用
/// <see cref="SetConcurrency"/> 下发给内核（metadata 池/限流参考）。
/// </summary>
public static class KernelMetadata
{
    /* ---- 原生结构（与 kernel_bridge.h / engine.ZkMetaInfo 逐字段一致）---- */

    [StructLayout(LayoutKind.Sequential)]
    private struct ZkTag
    {
        public IntPtr Key;
        public int KeyLen;
        public IntPtr Value;
        public int ValueLen;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ZkMetaInfo
    {
        public int SampleRate;
        public int Channels;
        public int BitsPerSample;
        public long DurationUs;
        public int DurationKnown;
        public IntPtr CodecName;
        public IntPtr FormatName;
        public IntPtr Profile;
        public IntPtr Title;
        public IntPtr Artist;
        public IntPtr Album;
        public IntPtr Date;
        public IntPtr Genre;
        public IntPtr Comment;
        public IntPtr Tags;
        public int TagsCount;
        public IntPtr CoverMime;
        public int CoverMimeLen;
        public IntPtr CoverData;
        public int CoverSize;
    }

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr zk_metadata_open(IntPtr path, out ZkMetaInfo outInfo,
                                                  byte[] errbuf, int errbufSize);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void zk_metadata_close(IntPtr handle);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void zk_metadata_set_concurrency(int n);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int zk_metadata_get_concurrency();

    private const string LibName = "archoera_kernel";

    /// <summary>内核可解析格式（扩展名，不含点）；其余回退 TagLibSharp。</summary>
    private static readonly HashSet<string> KernelExts = new(StringComparer.OrdinalIgnoreCase)
    {
        "flac", "mp3", "mp2", "mp1", "wav", "wave", "ogg", "oga", "opus",
        "m4a", "m4b", "mp4", "aac", "wma", "asf", "amr", "awb",
    };

    /// <summary>一次性 DllImportResolver 注册（定位随包分发的 libarchoera_kernel.so）。</summary>
    private static bool _resolverReady;
    private static bool _loadFailed;
    private static readonly object Gate = new();

    /// <summary>内核原生库是否可用（首次调用失败后缓存为不可用）。</summary>
    public static bool Available
    {
        get
        {
            EnsureResolver();
            return !_loadFailed;
        }
    }

    /// <summary>该扩展名是否优先走内核元数据路径。</summary>
    public static bool Supported(string filePath)
    {
        var ext = Path.GetExtension(filePath);
        return ext.Length > 1 && KernelExts.Contains(ext.Substring(1));
    }

    private static void EnsureResolver()
    {
        if (_resolverReady) return;
        lock (Gate)
        {
            if (_resolverReady) return;
            try
            {
                NativeLibrary.SetDllImportResolver(typeof(KernelMetadata).Assembly,
                    (name, _, _) =>
                    {
                        if (name != LibName) return IntPtr.Zero;
                        var lib = LocateLibrary();
                        return lib == null ? IntPtr.Zero : NativeLibrary.Load(lib);
                    });
            }
            catch (InvalidOperationException)
            {
                // 已有 resolver（例如 ffi 宿主）——沿用，忽略
            }
            _resolverReady = true;
        }
    }

    private static string? LocateLibrary()
    {
        var fileName = OperatingSystem.IsWindows() ? "archoera_kernel.dll"
            : OperatingSystem.IsMacOS() ? "libarchoera_kernel.dylib"
            : "libarchoera_kernel.so";

        var env = Environment.GetEnvironmentVariable("ARCHOERA_KERNEL_LIB");
        var candidates = new List<string?>
        {
            env,
            Path.Combine(AppContext.BaseDirectory, fileName),
            // 开发树：scanner/ → audio-engine/zig-out/lib/
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..",
                "..", "audio-engine", "zig-out", "lib", fileName)),
            Path.Combine(Directory.GetCurrentDirectory(), "..", "audio-engine",
                "zig-out", "lib", fileName),
        };

        foreach (var c in candidates)
        {
            if (!string.IsNullOrEmpty(c) && File.Exists(c)) return c;
        }
        return null;
    }

    /// <summary>
    /// 内核元数据结果（托管快照；调用返回后原生句柄已释放，字节已复制）。
    /// </summary>
    public sealed class Meta
    {
        public int SampleRate;
        public int Channels;
        public int BitsPerSample;
        public long DurationUs;
        public int DurationKnown; // 0=exact 1=estimate 2=unknown
        public string? Codec;
        public string? Format;
        public string? Profile;
        public string? Title;
        public string? Artist;
        public string? Album;
        public string? Date;
        public string? Genre;
        public string? Comment;
        public List<KeyValuePair<string, string>> Tags = new();
        public byte[]? Cover;
        public string? CoverMime;

        /// <summary>按 key（忽略大小写）取标签值。</summary>
        public string? Tag(string key)
        {
            foreach (var kv in Tags)
            {
                if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase))
                    return kv.Value;
            }
            return null;
        }
    }

    /// <summary>
    /// 读取文件元数据。内核不可用 / 打开失败 / 非支持格式 → 返回 null（调用方回退）。
    /// </summary>
    public static Meta? TryOpen(string filePath)
    {
        EnsureResolver();
        if (_loadFailed) return null;

        IntPtr path = IntPtr.Zero;
        IntPtr handle = IntPtr.Zero;
        try
        {
            path = Marshal.StringToCoTaskMemUTF8(filePath);
            var err = new byte[64];
            handle = zk_metadata_open(path, out var raw, err, err.Length);
            if (handle == IntPtr.Zero) return null;

            var meta = new Meta
            {
                SampleRate = raw.SampleRate,
                Channels = raw.Channels,
                BitsPerSample = raw.BitsPerSample,
                DurationUs = raw.DurationUs,
                DurationKnown = raw.DurationKnown,
                Codec = Utf8Z(raw.CodecName),
                Format = Utf8Z(raw.FormatName),
                Profile = Utf8Z(raw.Profile),
                Title = Utf8Z(raw.Title),
                Artist = Utf8Z(raw.Artist),
                Album = Utf8Z(raw.Album),
                Date = Utf8Z(raw.Date),
                Genre = Utf8Z(raw.Genre),
                Comment = Utf8Z(raw.Comment),
                CoverMime = Utf8(raw.CoverMime, raw.CoverMimeLen),
            };

            if (raw.Tags != IntPtr.Zero && raw.TagsCount > 0)
            {
                var size = Marshal.SizeOf<ZkTag>();
                for (var i = 0; i < raw.TagsCount; i++)
                {
                    var t = Marshal.PtrToStructure<ZkTag>(raw.Tags + i * size);
                    var k = Utf8(t.Key, t.KeyLen);
                    var v = Utf8(t.Value, t.ValueLen);
                    if (k != null && v != null)
                        meta.Tags.Add(new KeyValuePair<string, string>(k, v));
                }
            }

            if (raw.CoverData != IntPtr.Zero && raw.CoverSize > 0)
            {
                var buf = new byte[raw.CoverSize];
                Marshal.Copy(raw.CoverData, buf, 0, raw.CoverSize);
                meta.Cover = buf;
            }

            return meta;
        }
        catch (DllNotFoundException)
        {
            _loadFailed = true;
            return null;
        }
        catch (EntryPointNotFoundException)
        {
            _loadFailed = true;
            return null;
        }
        finally
        {
            if (handle != IntPtr.Zero) zk_metadata_close(handle);
            if (path != IntPtr.Zero) Marshal.FreeCoTaskMem(path);
        }
    }

    /// <summary>scanner 依自身指标协商并发数下发内核（0=自动）。</summary>
    public static void SetConcurrency(int parallelism)
    {
        EnsureResolver();
        if (_loadFailed) return;
        try { zk_metadata_set_concurrency(parallelism); }
        catch (DllNotFoundException) { _loadFailed = true; }
    }

    /// <summary>回读内核当前并发提示（校验用）。</summary>
    public static int GetConcurrency()
    {
        EnsureResolver();
        if (_loadFailed) return -1;
        try { return zk_metadata_get_concurrency(); }
        catch (DllNotFoundException) { _loadFailed = true; return -1; }
    }

    /* ---- UTF-8 指针读取 ---- */

    private static string? Utf8Z(IntPtr p) => p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);

    private static string? Utf8(IntPtr p, int len)
    {
        if (p == IntPtr.Zero || len <= 0) return null;
        return Marshal.PtrToStringUTF8(p, len);
    }
}

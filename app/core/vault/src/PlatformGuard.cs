using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Archoera.Vault;

/// 平台护栏（credential-vault-plan §3.6 配套 + §3.8 血缘/联动）：
///   - Linux：血缘校验（/proc/&lt;ppid&gt;/comm ∈ 白名单）+ PR_SET_PDEATHSIG(SIGTERM)
///            + RLIMIT_CORE=0（崩溃不产 dump）+ PR_SET_DUMPABLE=0（禁 /proc/pid/mem、ptrace 读取）
///   - macOS：血缘校验（proc_pidpath 父进程 basename ∈ 白名单）+ RLIMIT_CORE=0；
///            父死检测由 [ParentGone]（getppid 变更）兜底
///   - Windows：血缘校验（NtQueryInformationProcess 取 ParentPid + ProcessName ∈ 白名单）；
///              父死检测由 [ParentGone]（OpenProcess/GetExitCodeProcess）兜底
///
/// 白名单经环境变量 `ARCHOERA_VAULT_PARENT_OK`（逗号分隔可执行名）声明——
/// 未声明即拒绝服务（防独立/脚本直接调用）；spawn 方负责注入主程序可执行名。
public static class PlatformGuard
{
    private const int SIGTERM = 15;

    /// 血缘校验 + 安全武装。失败抛 [InvalidOperationException]（原因即 err 消息，不含敏感信息）。
    /// 返回父进程 pid（供 [ParentGone] 使用）。
    public static int VerifyAndArm()
    {
        var ppid = GetParentPid();
        if (ppid <= 1) throw new InvalidOperationException("独立运行被拒：父进程缺失");
        var okNames = (Environment.GetEnvironmentVariable("ARCHOERA_VAULT_PARENT_OK") ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (okNames.Length == 0)
        {
            throw new InvalidOperationException("独立运行被拒：未声明允许的父进程白名单");
        }
        var parentName = ParentProcessName(ppid) ?? "";
        if (Array.IndexOf(okNames, parentName) < 0)
        {
            throw new InvalidOperationException($"独立运行被拒：父进程 {parentName} 不在白名单");
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            // 父进程死亡 → vault 自动随 SIGTERM 退出（防被劫持脱离主程序）
            Prctl(1 /* PR_SET_PDEATHSIG */, (nuint)SIGTERM, 0, 0, 0);
            SetCoreRlimit(0);                       // 崩溃瞬间不向磁盘拷内存（§3.7 前提）
            Prctl(4 /* PR_SET_DUMPABLE */, 0, 0, 0, 0); // 禁调试读取（/proc/pid/mem、ptrace）
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            SetCoreRlimit(0);
        }
        return ppid;
    }

    /// 父进程是否已消失（Linux/macOS：getppid 变为 1 或不再等于会话记录；
    /// Windows：OpenProcess 失败或退出码非 STILL_ACTIVE）。
    public static bool ParentGone(int parentPid)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return !WindowsParentAlive(parentPid);
        }
        var ppid = GetParentPid();
        return ppid <= 1 || ppid != parentPid;
    }

    // ── 父进程标识 ──────────────────────────────────────────────────

    private static int GetParentPid()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var cur = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, Environment.ProcessId);
            if (cur == IntPtr.Zero) return -1;
            try
            {
                var info = new ProcessBasicInformation();
                var len = Marshal.SizeOf<ProcessBasicInformation>();
                if (NtQueryInformationProcess(cur, 0, ref info, len, out _) != 0) return -1;
                return (int)info.InheritedFromUniqueProcessId;
            }
            finally { CloseHandle(cur); }
        }
        return GetPpidNix();
    }

    private static string? ParentProcessName(int ppid)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            try { return Process.GetProcessById(ppid).ProcessName; }
            catch { return null; }
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return MacParentPath(ppid) is { } p ? Path.GetFileName(p) : null;
        }
        // Linux：/proc/<ppid>/comm
        try
        {
            var comm = File.ReadAllText($"/proc/{ppid}/comm").Trim();
            return string.IsNullOrEmpty(comm) ? null : comm;
        }
        catch { return null; }
    }

    private static bool WindowsParentAlive(int parentPid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, parentPid);
        if (h == IntPtr.Zero) return false;
        try
        {
            return GetExitCodeProcess(h, out var code) && code == 259 /* STILL_ACTIVE */;
        }
        finally { CloseHandle(h); }
    }

    private static string? MacParentPath(int pid)
    {
        try
        {
            var buf = new byte[4096];
            var n = ProcPidPath(pid, buf, (uint)buf.Length);
            if (n <= 0) return null;
            return System.Text.Encoding.UTF8.GetString(buf, 0, n);
        }
        catch { return null; }
    }

    private static void SetCoreRlimit(ulong value)
    {
        var rl = new RLimit { RlimCur = (nuint)value, RlimMax = (nuint)value };
        if (setrlimit(4 /* RLIMIT_CORE：Linux 与 macOS 一致 */, ref rl) != 0)
        {
            // 非致命：尽力而为（部分容器内受限），核心安全由 DUMPABLE/无 dump 双保险兜底
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RLimit
    {
        public nuint RlimCur;
        public nuint RlimMax;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    [DllImport("libc", EntryPoint = "getppid")]
    private static extern int GetPpidNix();

    [DllImport("libc", EntryPoint = "prctl", SetLastError = true)]
    private static extern int Prctl(int option, nuint a2, nuint a3, nuint a4, nuint a5);

    [DllImport("libc", EntryPoint = "setrlimit", SetLastError = true)]
    private static extern int setrlimit(int resource, ref RLimit rlp);

    [DllImport("/usr/lib/libproc.dylib")]
    private static extern int ProcPidPath(int pid, byte[] buffer, uint bufferSize);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int processInformationClass,
        ref ProcessBasicInformation processInformation, int processInformationLength, out int returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
}

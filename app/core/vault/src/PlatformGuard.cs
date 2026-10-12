// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace Archoera.Vault;

/// 平台护栏（credential-vault-plan §3.6 配套 + §3.8 血缘/联动）：
///   - Linux：血缘校验（OS 侧读取父进程可执行文件路径 /proc/&lt;ppid&gt;/exe，与「由本
///            可执行文件自身位置推导的预期主程序路径」比对）+ PR_SET_PDEATHSIG(SIGTERM)
///            + RLIMIT_CORE=0（崩溃不产 dump）+ PR_SET_DUMPABLE=0（禁 /proc/pid/mem、ptrace 读取）
///            + 加载器注入拒绝（LD_PRELOAD/LD_AUDIT 非空即拒，防 hook read 窃取口令）
///            + seccomp-BPF 反侵入过滤器（denylist：ptrace/进程内存/网络/exec/内核模块/
///              命名空间/io_uring 等被拒 → SECCOMP_RET_KILL_PROCESS，best-effort 降级）
///   - macOS：血缘校验（proc_pidpath 取父进程可执行文件路径并与预期主程序比对）
///            + 加载器注入拒绝（DYLD_INSERT_LIBRARIES 非空即拒）+ RLIMIT_CORE=0；
///            父死检测由 [ParentGone]（getppid 变更）兜底。
///            macOS 无 seccomp 等价物（需 entitlement/沙箱描述文件，本仓库不引入），
///            故仅 RLIMIT_CORE=0 一项平台硬化；ptrace(PT_DENY_ATTACH) 已废弃且属
///            反调试，明确不用。
///   - Windows：血缘校验（NtQueryInformationProcess 取 ParentPid +
///              QueryFullProcessImageNameW 取父进程**完整映像路径**并与预期主程序比对）
///              + SetProcessMitigationPolicy（ACG/签名/扩展点/严格句柄/CFG/镜像加载，
///              best-effort）；父死检测由 [ParentGone]（OpenProcess/GetExitCodeProcess）兜底
///
/// 血缘校验（**无环境变量信任**）：父进程 pid 由 OS 取得，父进程可执行文件路径亦由 OS
/// 读取（Linux readlink(/proc/&lt;ppid&gt;/exe)、macOS proc_pidpath、Windows
/// QueryFullProcessImageNameW），与「由本可执行文件自身位置推导出的预期主程序路径」比对。
/// 仅**打包布局**（本可执行文件位于 `.../native/`，预期主程序为同级目录的
/// `archoera_music[.exe]`）作路径绑定；dev/测试布局（如 core/vault/build、vault/build、
/// 测试拷贝目录）不作路径绑定以免自砖，预期主程序缺失时同样放行（防御性，仅记日志）。
/// 不读取任何环境变量作为信任来源。
public static class PlatformGuard
{
    private const int SIGTERM = 15;

    /// Linux seccomp 过滤器是否成功装载（仅隐藏测试子命令 `selftest-seccomp` 读取；
    /// 生产路径不消费此值，装不上即 best-effort 降级）。
    public static bool SeccompActive { get; private set; }

    /// 血缘校验 + 安全武装。失败抛 [InvalidOperationException]（原因即 err 消息，不含敏感信息）。
    /// 返回父进程 pid（供 [ParentGone] 使用）。
    public static int VerifyAndArm()
    {
        // 加载器注入拒绝（best-effort 加固，与 Dart 侧 spawn 环境净化双保险）：
        // `LD_PRELOAD`/`LD_AUDIT`（Linux）、`DYLD_INSERT_LIBRARIES`（macOS）可在动态
        // 装载阶段劫持 vault 的 `read`，从 stdin 握手窃取明文口令。恶意库可谎报环境
        // （故仅 best-effort），但可拦住直接以注入环境 spawn 的攻击，抬高门槛。
        // 不拒绝 `LD_LIBRARY_PATH`（常被合法使用）；Windows 不变（无此载荷机制）。
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("LD_PRELOAD")) ||
                !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("LD_AUDIT")))
            {
                throw new InvalidOperationException("检测到 LD_PRELOAD/LD_AUDIT，拒绝运行以防注入");
            }
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DYLD_INSERT_LIBRARIES")))
            {
                throw new InvalidOperationException("检测到 DYLD_INSERT_LIBRARIES，拒绝运行以防注入");
            }
        }
        var ppid = GetParentPid();
        if (ppid <= 1) throw new InvalidOperationException("独立运行被拒：父进程缺失");
        VerifyParentIdentity(ppid);
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            // 父进程死亡 → vault 自动随 SIGTERM 退出（防被劫持脱离主程序）
            Prctl(1 /* PR_SET_PDEATHSIG */, (nuint)SIGTERM, 0, 0, 0);
            SetCoreRlimit(0);                       // 崩溃瞬间不向磁盘拷内存（§3.7 前提）
            Prctl(4 /* PR_SET_DUMPABLE */, 0, 0, 0, 0); // 禁调试读取（/proc/pid/mem、ptrace）
            ApplyLinuxSeccompFilter();              // seccomp-BPF denylist（best-effort）
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            SetCoreRlimit(0);
            // macOS 无 seccomp 等价物：完整沙箱需 entitlement/沙箱描述文件（不引入）。
            // 保持 RLIMIT_CORE=0；不启用 ptrace(PT_DENY_ATTACH)（废弃且属反调试）。
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            ApplyWindowsMitigations();
        }
        return ppid;
    }

    // ── Linux：seccomp-BPF 反侵入过滤器（denylist，best-effort）──────
    //
    // 设计取舍：采用 **denylist**（仅对已知危险系统调用 KILL）而非 allowlist——
    // allowlist 一旦漏列 NativeAOT 运行时所依赖的系统调用（futex/mmap/mprotect/
    // clock_gettime/…）即"自砖"；denylist 下未知/新增系统调用默认放行，最坏是漏拦，
    // 不会令 vault 失效。过滤器在进程内一次性装载；不改变任何持久化数据。
    // PT 语义：被拒系统调用由内核以 SIGSYS 终止整个进程（SECCOMP_RET_KILL_PROCESS），
    // 触发父进程已有的 fail-closed（崩溃标记 → VaultCrashGate）。
    private const int PR_SET_NO_NEW_PRIVS = 38;
    private const int PR_SET_SECCOMP = 22;
    private const int SECCOMP_MODE_FILTER = 2;
    private const uint SECCOMP_RET_KILL_PROCESS = 0x80000000; // 违例 → 内核杀进程（SIGSYS）
    private const uint SECCOMP_RET_ALLOW = 0x7FFF0000;        // 放行
    private const ushort BPF_LD_W_ABS = 0x20;                 // BPF_LD | BPF_W | BPF_ABS
    private const ushort BPF_JMP_JEQ_K = 0x15;                // BPF_JMP | BPF_JEQ | BPF_K
    private const ushort BPF_JMP_JA = 0x05;                   // BPF_JMP | BPF_JA（无条件跳转）
    private const ushort BPF_RET_K = 0x06;                    // BPF_RET | BPF_K
    private const uint AF_INET = 2;                          // 仅 AF_INET/AF_INET6 视为网络
    private const uint AF_INET6 = 10;

    [StructLayout(LayoutKind.Sequential)]
    private struct SockFilter
    {
        public ushort Code;
        public byte Jt;
        public byte Jf;
        public uint K;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SockFprog
    {
        public ushort Len;
        public IntPtr Filter;
    }

    /// 装载 seccomp-BPF 过滤器。任何一步失败（EPERM/ENOSYS/内核无 seccomp/未知架构）
    /// 都只写 stderr 并继续——**绝不令 vault 启动失败**（best-effort 降级）。
    private static void ApplyLinuxSeccompFilter()
    {
        var (denied, socketNr) = LinuxSyscallPolicy();
        if (socketNr < 0)
        {
            Console.Error.WriteLine("[vault] seccomp: 未知架构，跳过过滤器（best-effort）");
            return;
        }
        // 先置 NO_NEW_PRIVS：此后进程不再获得提权（seccomp 无 CAP_SYS_ADMIN 的前提）。
        if (Prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
        {
            Console.Error.WriteLine(
                $"[vault] seccomp: PR_SET_NO_NEW_PRIVS 失败（errno={Marshal.GetLastPInvokeError()}），跳过");
            return;
        }

        // 构造经典 BPF：载入 seccomp_data.nr（偏移 0），逐条比对 denylist；
        // 命中 → KILL，未命中/未知 → 末尾 ALLOW 放行。
        var filters = new List<SockFilter>(denied.Length * 2 + 8)
        {
            new() { Code = BPF_LD_W_ABS, Jt = 0, Jf = 0, K = 0 },
        };
        foreach (var nr in denied)
        {
            filters.Add(new SockFilter { Code = BPF_JMP_JEQ_K, Jt = 0, Jf = 1, K = (uint)nr });
            filters.Add(new SockFilter { Code = BPF_RET_K, Jt = 0, Jf = 0, K = SECCOMP_RET_KILL_PROCESS });
        }
        // socket() 特判（arg-aware）：Linux 上 libsecret 经 D-Bus 走 **AF_UNIX** socket，
        // 且 D-Bus 客户端还会 connect() 该 AF_UNIX 连接。若整体拒 socket/connect 会
        // 令 OS 模式（libsecret）在真实桌面自砖；故仅对 AF_INET/AF_INET6（真正的网络）
        // 以 KILL 拒绝，AF_UNIX 等一律放行。seccomp_data.args[0]（domain，低 32 位）
        // 位于偏移 16；socket 块置于末尾，clobber 累加器不影响前面的 nr 比较。
        filters.Add(new SockFilter { Code = BPF_JMP_JEQ_K, Jt = 0, Jf = 5, K = (uint)socketNr });
        filters.Add(new SockFilter { Code = BPF_LD_W_ABS, Jt = 0, Jf = 0, K = 16 });          // args[0] = domain
        filters.Add(new SockFilter { Code = BPF_JMP_JEQ_K, Jt = 2, Jf = 0, K = AF_INET });    // == AF_INET → KILL
        filters.Add(new SockFilter { Code = BPF_JMP_JEQ_K, Jt = 1, Jf = 0, K = AF_INET6 });   // == AF_INET6 → KILL
        filters.Add(new SockFilter { Code = BPF_JMP_JA, Jt = 0, Jf = 0, K = 1 });             // 其他 family → 跳过 KILL
        filters.Add(new SockFilter { Code = BPF_RET_K, Jt = 0, Jf = 0, K = SECCOMP_RET_KILL_PROCESS });
        filters.Add(new SockFilter { Code = BPF_RET_K, Jt = 0, Jf = 0, K = SECCOMP_RET_ALLOW });

        var arr = filters.ToArray();
        var filtersHandle = GCHandle.Alloc(arr, GCHandleType.Pinned);
        try
        {
            // SockFprog 指向托管数组；须在装箱/pin 前填好指针字段（value type boxing）。
            var fprog = new SockFprog { Len = (ushort)arr.Length, Filter = filtersHandle.AddrOfPinnedObject() };
            var fprogHandle = GCHandle.Alloc(fprog, GCHandleType.Pinned);
            try
            {
                if (Prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER,
                        (nuint)fprogHandle.AddrOfPinnedObject(), 0, 0) != 0)
                {
                    Console.Error.WriteLine(
                        $"[vault] seccomp: PR_SET_SECCOMP 失败（errno={Marshal.GetLastPInvokeError()}），best-effort 继续");
                    return;
                }
                SeccompActive = true;
            }
            finally { fprogHandle.Free(); }
        }
        finally { filtersHandle.Free(); }
    }

    /// 按架构给出（整体拒绝的系统调用号，socket 号）。过滤器是 denylist：
    /// **其余一切放行**，包括 vault 正常运作所需 open/openat/read/write/close/lseek/
    /// fsync/fstat/newfstatat/rename/unlink/mkdir/getdents64/mmap/munmap/mprotect/
    /// madvise/mlock/munlock/brk/futex/clock_gettime/getrandom/rt_sigaction/
    /// rt_sigprocmask/nanosleep/exit/exit_group/readlink/getcwd/prlimit64/setrlimit/
    /// getpid/getppid/uname/sigaltstack，以及 socket(AF_UNIX)/connect 等 D-Bus
    /// （libsecret）所需路径——**绝不列入**。未知架构返回 (-1) → 跳过过滤（避免误杀）。
    private static (int[] Denied, int SocketNr) LinuxSyscallPolicy() =>
        RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => (X64Denied, 41 /* __NR_socket */),
            Architecture.Arm64 => (Arm64Denied, 198 /* __NR_socket */),
            _ => (Array.Empty<int>(), -1),
        };

    // x86_64（asm/unistd_64.h）。仅列**明确危险**者。
    // 取舍说明：
    //   - **有意不拒 clone/clone3/fork/vfork**：NativeAOT 运行时会在会话期间按需创建
    //     线程（TimerQueue/线程池/GC），glibc pthread_create 优先走 clone3，且仅在返回
    //     ENOSYS 时才回退 clone——若把 clone3 设为 KILL，运行时的惰性建线程会直接令
    //     进程自杀（自砖）。denylist 的目标是反侵入而非自残，故线程创建路径整体放行。
    //   - **网络只拒 AF_INET/AF_INET6 的 socket()**（见 ApplyLinuxSeccompFilter 的
    //     arg-aware 特判）；socketpair/connect/bind/listen/accept/accept4/sendto/
    //     recvfrom 整体放行——D-Bus（libsecret，AF_UNIX）客户端会调用 connect，
    //     整体拒之会令 OS 模式在真实桌面自砖；无法建 INET socket 已足以阻断网络。
    private static readonly int[] X64Denied =
    {
        101, // ptrace
        310, // process_vm_readv
        311, // process_vm_writev
        59,  // execve
        322, // execveat
        246, // kexec_load
        320, // kexec_file_load
        321, // bpf
        323, // userfaultfd
        298, // perf_event_open
        304, // open_by_handle_at
        440, // process_madvise
        438, // pidfd_getfd
        175, // init_module
        313, // finit_module
        176, // delete_module
        169, // reboot
        167, // swapon
        168, // swapoff
        165, // mount
        166, // umount2
        155, // pivot_root
        161, // chroot
        308, // setns
        272, // unshare
        428, // open_tree
        429, // move_mount
        430, // fsopen
        432, // fsmount
        433, // fspick
        425, // io_uring_setup
        426, // io_uring_enter
        427, // io_uring_register
    };

    // aarch64（asm-generic/unistd.h）。同样有意不拒 clone/clone3/fork/vfork；
    // 网络仅在 socket() 上按 family 拒绝（AF_INET/AF_INET6），connect 等放行以兼容 D-Bus。
    private static readonly int[] Arm64Denied =
    {
        117, // ptrace
        270, // process_vm_readv
        271, // process_vm_writev
        221, // execve
        281, // execveat
        104, // kexec_load
        294, // kexec_file_load
        280, // bpf
        282, // userfaultfd
        241, // perf_event_open
        265, // open_by_handle_at
        440, // process_madvise
        438, // pidfd_getfd
        105, // init_module
        273, // finit_module
        106, // delete_module
        142, // reboot
        224, // swapon
        225, // swapoff
        40,  // mount
        39,  // umount2
        41,  // pivot_root
        51,  // chroot
        268, // setns
        97,  // unshare
        428, // open_tree
        429, // move_mount
        430, // fsopen
        432, // fsmount
        433, // fspick
        425, // io_uring_setup
        426, // io_uring_enter
        427, // io_uring_register
    };

    // ── Windows：进程缓解策略（best-effort，失败即忽略）────────────
    private const int ProcessDynamicCodePolicy = 2;          // ACG：禁动态代码
    private const int ProcessStrictHandleCheckPolicy = 3;    // 严格句柄校验
    private const int ProcessExtensionPointDisablePolicy = 6;// 禁扩展点（AppInit 等）
    private const int ProcessControlFlowGuardPolicy = 7;     // CFG
    private const int ProcessSignaturePolicy = 8;            // 镜像签名要求
    private const int ProcessImageLoadPolicy = 10;           // 镜像加载来源约束

    /// 武装 Windows 进程缓解策略。所有项均 best-effort：旧系统不支持或与 NativeAOT
    /// 运行时冲突时 SetProcessMitigationPolicy 返回 false，仅忽略、绝不阻断启动。
    /// 未启用会破坏 NativeAOT 正常运作的策略（如 SystemCallDisable）。
    [SupportedOSPlatform("windows")]
    private static void ApplyWindowsMitigations()
    {
        SetMitigation(ProcessDynamicCodePolicy, 0x1);            // ProhibitDynamicCode
        SetMitigation(ProcessSignaturePolicy, 0x1);              // MicrosoftSignedOnly
        SetMitigation(ProcessExtensionPointDisablePolicy, 0x1);  // DisableExtensionPoints
        SetMitigation(ProcessStrictHandleCheckPolicy, 0x1);      // RaiseExceptionOnInvalidHandleReference
        SetMitigation(ProcessControlFlowGuardPolicy, 0x1);       // EnableControlFlowGuard
        SetMitigation(ProcessImageLoadPolicy, 0x3);              // NoRemoteImages | NoLowMandatoryLabelImages
    }

    [SupportedOSPlatform("windows")]
    private static void SetMitigation(int policy, uint flags)
    {
        try
        {
            uint value = flags;
            _ = SetProcessMitigationPolicy(policy, ref value, (nuint)sizeof(uint));
        }
        catch (DllNotFoundException) { }        // 旧系统 / 缺少导出
        catch (EntryPointNotFoundException) { }
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

    // ── 血缘校验：OS 侧父进程可执行文件路径 vs 预期主程序路径 ────────

    /// 校验父进程身份（**不读任何环境变量**）：父进程 pid 由 OS 取得，父进程
    /// 可执行文件路径由 OS 读取，与「由本可执行文件自身位置推导的预期主程序路径」
    /// 比对。失败抛 [InvalidOperationException]（原因即 err 消息）。
    ///
    /// 规则：
    ///   - 仅当**打包布局**（本可执行文件目录名为 `native`，即 `.../native/<vault>`）
    ///     才作路径绑定，预期主程序 = `.../archoera_music[.exe]`；
    ///   - dev/测试布局（build/、测试拷贝目录等，目录名非 `native`）放行（仅记日志）
    ///     —— `flutter run` 与 vault 冒烟测试均在 dev 布局运行；
    ///   - 预期主程序不存在（非常规布局）亦放行（防御性，仅记日志），避免自砖；
    ///   - 路径比较前尽量解析符号链接（best-effort），Windows 忽略大小写、Unix 序数比较。
    private static void VerifyParentIdentity(int ppid)
    {
        var processPath = Environment.ProcessPath;
        if (string.IsNullOrEmpty(processPath))
        {
            Console.Error.WriteLine("[vault] 血缘校验：无法确定自身可执行文件路径，跳过路径绑定（dev/异常布局）");
            return;
        }
        var vaultDir = Path.GetDirectoryName(processPath);
        if (string.IsNullOrEmpty(vaultDir))
        {
            Console.Error.WriteLine("[vault] 血缘校验：自身可执行文件无目录，跳过路径绑定（dev/异常布局）");
            return;
        }
        // 打包布局判定：本可执行文件位于 `.../native/` 下。
        if (!string.Equals(Path.GetFileName(vaultDir), "native", StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine($"[vault] 血缘校验：dev/测试布局（{vaultDir}），跳过父进程路径绑定");
            return;
        }
        var expectedDir = Path.GetDirectoryName(vaultDir);
        if (string.IsNullOrEmpty(expectedDir))
        {
            Console.Error.WriteLine($"[vault] 血缘校验：打包布局无上层目录（{vaultDir}），跳过路径绑定");
            return;
        }
        // 预期主程序候选（按打包布局）：
        //   - 通用：<parent-of-native>/archoera_music[.exe]（Linux/Windows，及 macOS
        //     `Contents/MacOS/native` 布局）；
        //   - macOS `.app`：本可执行文件位于 `Contents/native`（Xcode 与 CI 的统一下
        //     载目录），预期主程序在 `Contents/MacOS/archoera_music`。
        // 取第一个真实存在者；全部不存在 → 防御性放行（非常规布局），仅记日志，绝不 brick。
        var expectedCandidates = new List<string>
        {
            Path.Combine(expectedDir,
                RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "archoera_music.exe" : "archoera_music"),
        };
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            expectedCandidates.Add(Path.Combine(expectedDir, "MacOS", "archoera_music"));
        }
        string? expected = null;
        foreach (var candidate in expectedCandidates)
        {
            if (File.Exists(candidate)) { expected = candidate; break; }
        }
        if (expected == null)
        {
            // 防御：预期主程序缺失（非常规布局/裁剪产物）→ 放行，仅记日志，绝不 brick。
            Console.Error.WriteLine(
                $"[vault] 血缘校验：预期主程序不存在（候选：{string.Join(", ", expectedCandidates)}），跳过父进程路径绑定");
            return;
        }
        var parentPath = ParentExecutablePath(ppid);
        if (string.IsNullOrEmpty(parentPath))
        {
            throw new InvalidOperationException("独立运行被拒：无法读取父进程可执行文件路径");
        }
        if (!PathsEqual(CanonicalizePath(parentPath), CanonicalizePath(expected)))
        {
            throw new InvalidOperationException("独立运行被拒：父进程不是预期的主程序");
        }
    }

    /// 取父进程可执行文件完整路径（OS 侧）。失败返回 null。
    private static string? ParentExecutablePath(int ppid)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return WindowsProcessImagePath(ppid);
        }
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return MacParentPath(ppid);
        }
        // Linux：readlink("/proc/<ppid>/exe")（可能以 " (deleted)" 结尾，须剥离）
        try
        {
            var buf = new byte[4096];
            var n = ReadLink($"/proc/{ppid}/exe", buf, (nuint)buf.Length);
            if (n <= 0) return null;
            var s = Encoding.UTF8.GetString(buf, 0, (int)n);
            const string deleted = " (deleted)";
            if (s.EndsWith(deleted, StringComparison.Ordinal))
            {
                s = s[..^deleted.Length];
            }
            return string.IsNullOrEmpty(s) ? null : s;
        }
        catch { return null; }
    }

    /// 路径规范化（best-effort 解析符号链接，其后回退 [Path.GetFullPath]）。
    private static string CanonicalizePath(string path)
    {
        try
        {
            var resolved = new FileInfo(path).ResolveLinkTarget(returnFinalTarget: true);
            if (resolved != null && !string.IsNullOrEmpty(resolved.FullName))
            {
                return resolved.FullName;
            }
        }
        catch { /* 非链接 / 不可解析 → 回退 GetFullPath */ }
        try { return Path.GetFullPath(path); }
        catch { return path; }
    }

    /// 路径相等判定：Windows 忽略大小写，Unix 序数比较。
    private static bool PathsEqual(string a, string b) =>
        RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
            ? string.Equals(a, b, StringComparison.OrdinalIgnoreCase)
            : string.Equals(a, b, StringComparison.Ordinal);

    [SupportedOSPlatform("windows")]
    private static string? WindowsProcessImagePath(int pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            if (!QueryFullProcessImageNameW(h, 0, sb, ref size)) return null;
            return size == 0 ? null : sb.ToString(0, (int)size);
        }
        catch { return null; }
        finally { CloseHandle(h); }
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

    /// proc_pidpath 符号无法解析时是否已记日志（仅一次，避免每次会话刷屏）。
    private static bool _procPidPathUnavailableLogged;

    private static string? MacParentPath(int pid)
    {
        var buf = new byte[4096];
        try
        {
            var n = ProcPidPath(pid, buf, (uint)buf.Length);
            if (n > 0) return System.Text.Encoding.UTF8.GetString(buf, 0, n);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            // 主入口（逻辑名 libproc.dylib）解析失败 → 回退绝对路径（旧系统/受限环境）。
            try
            {
                var n = ProcPidPathAbsolute(pid, buf, (uint)buf.Length);
                if (n > 0) return System.Text.Encoding.UTF8.GetString(buf, 0, n);
            }
            catch (Exception e2) when (e2 is DllNotFoundException or EntryPointNotFoundException)
            {
                // 符号真正不可解析：返回 null（调用方 fail-closed），但明确记一次日志，
                // 不再静默吞掉——此前正是此处让 macOS 父进程校验「总是失败」而无人察觉。
                if (!_procPidPathUnavailableLogged)
                {
                    _procPidPathUnavailableLogged = true;
                    Console.Error.WriteLine(
                        $"[vault] 血缘校验：无法解析 proc_pidpath（libproc.dylib）：{e2.Message}；macOS 父进程路径校验不可用");
                }
                return null;
            }
        }
        catch { return null; }
        return null;
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

    // readlink(2)：ssize_t → nint（Linux 取 /proc/<pid>/exe 目标）。
    [DllImport("libc", EntryPoint = "readlink", SetLastError = true)]
    private static extern nint ReadLink(string path, byte[] buf, nuint bufSize);

    [DllImport("libc", EntryPoint = "prctl", SetLastError = true)]
    private static extern int Prctl(int option, nuint a2, nuint a3, nuint a4, nuint a5);

    [DllImport("libc", EntryPoint = "setrlimit", SetLastError = true)]
    private static extern int setrlimit(int resource, ref RLimit rlp);

    // macOS proc_pidpath(3)（libproc）。必须显式 EntryPoint：否则按托管名
    // "ProcPidPath" 解析到不存在的导出 → EntryPointNotFoundException 被吞 →
    // macOS 父进程身份校验恒失败、每次 serve 被拒。首选逻辑名 "libproc.dylib"，
    // 旧系统回退绝对路径（见 [MacParentPath]）。
    [DllImport("libproc.dylib", EntryPoint = "proc_pidpath")]
    private static extern int ProcPidPath(int pid, byte[] buffer, uint bufferSize);

    [DllImport("/usr/lib/libproc.dylib", EntryPoint = "proc_pidpath")]
    private static extern int ProcPidPathAbsolute(int pid, byte[] buffer, uint bufferSize);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int processInformationClass,
        ref ProcessBasicInformation processInformation, int processInformationLength, out int returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    // 取进程完整映像路径（Windows）：须用 PROCESS_QUERY_LIMITED_INFORMATION 句柄。
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags,
        StringBuilder exeName, ref uint size);

    // PROCESS_MITIGATION_* 策略均为单个 DWORD 位域；dwLength = 4。
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessMitigationPolicy(int mitigationPolicy, ref uint lpBuffer, nuint dwLength);
}

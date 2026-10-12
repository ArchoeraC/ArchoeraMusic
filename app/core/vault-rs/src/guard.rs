// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 平台护栏（与 C# PlatformGuard.cs 语义一致）。
//!
//! Linux：血缘校验（`/proc/<ppid>/exe`）+ PR_SET_PDEATHSIG + RLIMIT_CORE=0 +
//!        PR_SET_DUMPABLE=0 + seccomp-BPF denylist（含 socket 按地址族的 arg-aware 特判）；
//! macOS：血缘校验（`proc_pidpath`，libproc 动态解析）+ 拒绝 `DYLD_INSERT_LIBRARIES`
//!        + RLIMIT_CORE=0；父死检测由 `getppid` 变更兜底；
//! Windows：血缘校验（`NtQueryInformationProcess` 取父 pid + `OpenProcess` /
//!        `QueryFullProcessImageNameW` 取父进程映像路径，大小写不敏感比较）+
//!        `SetProcessMitigationPolicy`（ACG/CIG/扩展点/严格句柄/CFG/镜像，best-effort）；
//!        父死检测由 `GetExitCodeProcess` 兜底。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::errors::{Result, VaultError};

static SECCOMP_ACTIVE: AtomicBool = AtomicBool::new(false);

pub fn seccomp_active() -> bool {
    SECCOMP_ACTIVE.load(Ordering::SeqCst)
}

/// 血缘校验 + 安全武装；返回父进程 pid。
pub fn verify_and_arm() -> Result<i32> {
    #[cfg(target_os = "linux")]
    {
        let preload = std::env::var("LD_PRELOAD").unwrap_or_default();
        let audit = std::env::var("LD_AUDIT").unwrap_or_default();
        if !preload.is_empty() || !audit.is_empty() {
            return Err(VaultError::invalid_operation(
                "检测到 LD_PRELOAD/LD_AUDIT，拒绝运行以防注入",
            ));
        }
    }
    #[cfg(target_os = "macos")]
    {
        let insert = std::env::var("DYLD_INSERT_LIBRARIES").unwrap_or_default();
        if !insert.is_empty() {
            return Err(VaultError::invalid_operation(
                "检测到 DYLD_INSERT_LIBRARIES，拒绝运行以防注入",
            ));
        }
    }

    let ppid = get_parent_pid();
    if ppid <= 1 {
        return Err(VaultError::invalid_operation("独立运行被拒：父进程缺失"));
    }
    verify_parent_identity(ppid)?;

    #[cfg(target_os = "linux")]
    {
        unsafe {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM as libc::c_ulong, 0, 0, 0);
        }
        set_core_rlimit(0);
        unsafe {
            libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
        }
        apply_linux_seccomp_filter();
    }
    #[cfg(target_os = "macos")]
    {
        set_core_rlimit(0);
    }
    #[cfg(windows)]
    {
        apply_windows_mitigations();
    }
    Ok(ppid)
}

/// 父进程是否已消失（Linux/macOS：getppid 变更；Windows：句柄退出码非 STILL_ACTIVE）。
#[cfg(unix)]
pub fn parent_gone(parent_pid: i32) -> bool {
    let ppid = get_parent_pid();
    ppid <= 1 || ppid != parent_pid
}

#[cfg(windows)]
pub fn parent_gone(parent_pid: i32) -> bool {
    !win::parent_alive(parent_pid)
}

#[cfg(not(any(unix, windows)))]
pub fn parent_gone(_parent_pid: i32) -> bool {
    false
}

#[cfg(unix)]
fn get_parent_pid() -> i32 {
    unsafe { libc::getppid() as i32 }
}

#[cfg(windows)]
fn get_parent_pid() -> i32 {
    win::parent_pid()
}

#[cfg(not(any(unix, windows)))]
fn get_parent_pid() -> i32 {
    -1
}

#[cfg(unix)]
fn set_core_rlimit(value: u64) {
    let rl = libc::rlimit {
        rlim_cur: value as libc::rlim_t,
        rlim_max: value as libc::rlim_t,
    };
    unsafe {
        libc::setrlimit(libc::RLIMIT_CORE, &rl);
    }
}

// ── 血缘校验 ────────────────────────────────────────────────────────

fn verify_parent_identity(ppid: i32) -> Result<()> {
    let process_path = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => {
            eprintln!("[vault] 血缘校验：无法确定自身可执行文件路径，跳过路径绑定（dev/异常布局）");
            return Ok(());
        }
    };
    let vault_dir = match process_path.parent() {
        Some(d) => d.to_path_buf(),
        None => {
            eprintln!("[vault] 血缘校验：自身可执行文件无目录，跳过路径绑定（dev/异常布局）");
            return Ok(());
        }
    };
    let dir_name = vault_dir
        .file_name()
        .map(|s| s.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    if dir_name != "native" {
        eprintln!(
            "[vault] 血缘校验：dev/测试布局（{}），跳过父进程路径绑定",
            vault_dir.display()
        );
        return Ok(());
    }
    let expected_dir = match vault_dir.parent() {
        Some(d) => d.to_path_buf(),
        None => {
            eprintln!(
                "[vault] 血缘校验：打包布局无上层目录（{}），跳过路径绑定",
                vault_dir.display()
            );
            return Ok(());
        }
    };
    // 预期主程序候选（按打包布局）：
    //   - 通用：<parent-of-native>/archoera_music[.exe]（Linux/Windows，及 macOS
    //     `Contents/MacOS/native` 布局）；
    //   - macOS `.app`：本可执行文件位于 `Contents/native`（Xcode 与 CI 统一下载
    //     目录），预期主程序在 `Contents/MacOS/archoera_music`。
    let main_name = if cfg!(windows) {
        "archoera_music.exe"
    } else {
        "archoera_music"
    };
    #[allow(unused_mut)]
    let mut candidates = vec![expected_dir.join(main_name)];
    #[cfg(target_os = "macos")]
    {
        candidates.push(expected_dir.join("MacOS").join("archoera_music"));
    }
    let expected = candidates.iter().find(|c| c.exists()).cloned();
    let expected = match expected {
        Some(e) => e,
        None => {
            eprintln!("[vault] 血缘校验：预期主程序不存在，跳过父进程路径绑定");
            return Ok(());
        }
    };
    let parent_path = parent_executable_path(ppid);
    let parent_path = match parent_path {
        Some(p) if !p.is_empty() => p,
        _ => {
            return Err(VaultError::invalid_operation(
                "独立运行被拒：无法读取父进程可执行文件路径",
            ))
        }
    };
    if !paths_equal(
        &canonicalize(Path::new(&parent_path)),
        &canonicalize(&expected),
    ) {
        return Err(VaultError::invalid_operation(
            "独立运行被拒：父进程不是预期的主程序",
        ));
    }
    Ok(())
}

/// 路径相等判定：Windows 忽略大小写，Unix 序数比较（与 C# `PlatformGuard.PathsEqual`
/// 一致）。
#[cfg(windows)]
fn paths_equal(a: &Path, b: &Path) -> bool {
    a.to_string_lossy()
        .eq_ignore_ascii_case(&b.to_string_lossy())
}

#[cfg(not(windows))]
fn paths_equal(a: &Path, b: &Path) -> bool {
    a == b
}

#[cfg(target_os = "linux")]
fn parent_executable_path(ppid: i32) -> Option<String> {
    let link = format!("/proc/{ppid}/exe");
    let target = std::fs::read_link(link).ok()?;
    let mut s = target.to_string_lossy().into_owned();
    const DELETED: &str = " (deleted)";
    if let Some(stripped) = s.strip_suffix(DELETED) {
        s = stripped.to_string();
    }
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

#[cfg(target_os = "macos")]
fn parent_executable_path(ppid: i32) -> Option<String> {
    macos::parent_path(ppid)
}

#[cfg(windows)]
fn parent_executable_path(ppid: i32) -> Option<String> {
    win::process_image_path(ppid)
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn parent_executable_path(_ppid: i32) -> Option<String> {
    None
}

// ── Windows：血缘校验 + 进程缓解（best-effort）───────────────────────

/// Windows 侧实现：
///   - 父 pid：`NtQueryInformationProcess(ProcessBasicInformation)`；
///   - 父进程映像路径：`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` +
///     `QueryFullProcessImageNameW`（大小写不敏感比较见 [paths_equal]）；
///   - 进程缓解：`SetProcessMitigationPolicy`（ACG/CIG/扩展点/严格句柄/CFG/镜像，
///     best-effort，失败即忽略，绝不阻断启动）。
#[cfg(windows)]
mod win {
    use core::ffi::c_void;

    use windows::core::PWSTR;
    use windows::Win32::Foundation::{CloseHandle, HANDLE, STILL_ACTIVE};
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, QueryFullProcessImageNameW, SetProcessMitigationPolicy,
        ProcessControlFlowGuardPolicy, ProcessDynamicCodePolicy,
        ProcessExtensionPointDisablePolicy, ProcessImageLoadPolicy, ProcessSignaturePolicy,
        ProcessStrictHandleCheckPolicy, PROCESS_MITIGATION_POLICY, PROCESS_NAME_FORMAT,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };

    // PROCESS_BASIC_INFORMATION：布局与 C# `ProcessBasicInformation` 一致（ntdll 语义）。
    #[repr(C)]
    struct ProcessBasicInformation {
        reserved1: *mut c_void,
        peb_base_address: *mut c_void,
        reserved2_0: *mut c_void,
        reserved2_1: *mut c_void,
        unique_process_id: usize,
        inherited_from_unique_process_id: usize,
    }

    // windows crate 将 NtQueryInformationProcess 置于 `Wdk` 特性下；此处自声明以避免
    // 额外引入 Wdk / Win32_System_Kernel（仅需 ntdll 链接）。
    #[link(name = "ntdll")]
    extern "system" {
        fn NtQueryInformationProcess(
            process_handle: HANDLE,
            process_information_class: u32,
            process_information: *mut c_void,
            process_information_length: u32,
            return_length: *mut u32,
        ) -> i32;
    }

    /// 当前进程父 pid（失败返回 -1，调用方按「父进程缺失」处理）。
    pub fn parent_pid() -> i32 {
        unsafe {
            let cur = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, std::process::id())
            {
                Ok(h) => h,
                Err(_) => return -1,
            };
            let mut info = ProcessBasicInformation {
                reserved1: core::ptr::null_mut(),
                peb_base_address: core::ptr::null_mut(),
                reserved2_0: core::ptr::null_mut(),
                reserved2_1: core::ptr::null_mut(),
                unique_process_id: 0,
                inherited_from_unique_process_id: 0,
            };
            let mut ret_len = 0u32;
            let status = NtQueryInformationProcess(
                cur,
                0, // ProcessBasicInformation
                &mut info as *mut _ as *mut c_void,
                core::mem::size_of::<ProcessBasicInformation>() as u32,
                &mut ret_len,
            );
            let _ = CloseHandle(cur);
            if status != 0 {
                return -1;
            }
            info.inherited_from_unique_process_id as i32
        }
    }

    /// 父进程是否仍存活（`GetExitCodeProcess == STILL_ACTIVE`）。
    pub fn parent_alive(pid: i32) -> bool {
        unsafe {
            let h = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid as u32) {
                Ok(h) => h,
                Err(_) => return false,
            };
            let mut code = 0u32;
            let alive = GetExitCodeProcess(h, &mut code).is_ok() && code == STILL_ACTIVE.0 as u32;
            let _ = CloseHandle(h);
            alive
        }
    }

    /// 进程完整映像路径（`QueryFullProcessImageNameW`，Win32 格式）。
    pub fn process_image_path(pid: i32) -> Option<String> {
        unsafe {
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid as u32).ok()?;
            let mut buf = vec![0u16; 1024];
            let mut size = buf.len() as u32;
            let result = QueryFullProcessImageNameW(
                h,
                PROCESS_NAME_FORMAT(0),
                PWSTR(buf.as_mut_ptr()),
                &mut size,
            );
            let _ = CloseHandle(h);
            result.ok()?;
            if size == 0 {
                return None;
            }
            Some(String::from_utf16_lossy(&buf[..size as usize]))
        }
    }

    /// 武装进程缓解策略（best-effort，失败即忽略）。
    pub fn apply_mitigations() {
        set_mitigation(ProcessDynamicCodePolicy, 0x1); // ProhibitDynamicCode（ACG）
        set_mitigation(ProcessSignaturePolicy, 0x1); // MicrosoftSignedOnly（CIG）
        set_mitigation(ProcessExtensionPointDisablePolicy, 0x1); // DisableExtensionPoints
        set_mitigation(ProcessStrictHandleCheckPolicy, 0x1); // RaiseExceptionOnInvalidHandleReference
        set_mitigation(ProcessControlFlowGuardPolicy, 0x1); // EnableControlFlowGuard
        set_mitigation(ProcessImageLoadPolicy, 0x3); // NoRemoteImages | NoLowMandatoryLabelImages
    }

    fn set_mitigation(policy: PROCESS_MITIGATION_POLICY, flags: u32) {
        // SAFETY: PROCESS_MITIGATION_* 均为单个 DWORD 位域，dwLength=4（与 C# 一致）。
        unsafe {
            let value = flags;
            let _ = SetProcessMitigationPolicy(
                policy,
                &value as *const u32 as *const c_void,
                core::mem::size_of::<u32>(),
            );
        }
    }
}

#[cfg(windows)]
fn apply_windows_mitigations() {
    win::apply_mitigations();
}

// ── macOS：血缘校验（proc_pidpath）───────────────────────────────────

/// macOS 侧实现：`proc_pidpath(3)`（libproc）。经 `dlopen`/`dlsym` 解析，优先逻辑名
/// `libproc.dylib`，回退绝对路径 `/usr/lib/libproc.dylib`——与 C# `MacParentPath`
/// 的动态加载 + 回退一致，避免链接期对 libproc 的硬依赖；符号不可解析时记一次日志
/// 并返回 None（调用方 fail-closed，或 dev 布局放行）。
#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::CStr;
    use std::os::raw::{c_char, c_int, c_void};

    type ProcPidPathFn = unsafe extern "C" fn(c_int, *mut c_void, u32) -> c_int;

    /// 解析 `proc_pidpath` 符号（逻辑名 → 绝对路径回退；全部失败返回 None）。
    fn proc_pidpath_symbol() -> Option<ProcPidPathFn> {
        const LIB_NAMES: [&[u8]; 2] = [b"libproc.dylib\0", b"/usr/lib/libproc.dylib\0"];
        const SYM: &[u8] = b"proc_pidpath\0";
        for name in LIB_NAMES {
            // SAFETY: name 为 NUL 结尾的静态字节串。
            let handle = unsafe { libc::dlopen(name.as_ptr() as *const c_char, libc::RTLD_NOW) };
            if handle.is_null() {
                continue;
            }
            // SAFETY: handle 为有效 dlopen 句柄；SYM 为 NUL 结尾。
            let sym = unsafe { libc::dlsym(handle, SYM.as_ptr() as *const c_char) };
            // 不 dlclose：句柄在进程生命周期内保持（与 C# 缓存一致）。
            if !sym.is_null() {
                // SAFETY: sym 指向 proc_pidpath 函数，签名与 ProcPidPathFn 一致。
                return Some(unsafe { std::mem::transmute::<*mut c_void, ProcPidPathFn>(sym) });
            }
        }
        None
    }

    pub fn parent_path(ppid: i32) -> Option<String> {
        let f = match proc_pidpath_symbol() {
            Some(f) => f,
            None => {
                eprintln!(
                    "[vault] 血缘校验：无法解析 proc_pidpath（libproc.dylib）；macOS 父进程路径校验不可用"
                );
                return None;
            }
        };
        let mut buf = vec![0 as c_char; 4096];
        // SAFETY: buf 为 4096 字节可写缓冲；proc_pidpath 最多写 buffersize 字节。
        let n = unsafe { f(ppid as c_int, buf.as_mut_ptr() as *mut c_void, buf.len() as u32) };
        if n <= 0 {
            return None;
        }
        // SAFETY: n>0 时 proc_pidpath 已写入 NUL 结尾路径。
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    }
}

fn canonicalize(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

// ── Linux seccomp-BPF denylist ──────────────────────────────────────

#[cfg(target_os = "linux")]
mod seccomp {
    pub const PR_SET_NO_NEW_PRIVS: libc::c_int = 38;
    pub const PR_SET_SECCOMP: libc::c_int = 22;
    pub const SECCOMP_MODE_FILTER: libc::c_ulong = 2;
    pub const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
    pub const SECCOMP_RET_ALLOW: u32 = 0x7FFF_0000;
    pub const BPF_LD_W_ABS: u16 = 0x20;
    pub const BPF_JMP_JEQ_K: u16 = 0x15;
    pub const BPF_JMP_JA: u16 = 0x05;
    pub const BPF_RET_K: u16 = 0x06;
    pub const AF_INET: u32 = 2;
    pub const AF_INET6: u32 = 10;

    pub const X64_DENIED: &[i32] = &[
        101, 310, 311, 59, 322, 246, 320, 321, 323, 298, 304, 440, 438, 175, 313, 176, 169, 167,
        168, 165, 166, 155, 161, 308, 272, 428, 429, 430, 432, 433, 425, 426, 427,
    ];
    pub const ARM64_DENIED: &[i32] = &[
        117, 270, 271, 221, 281, 104, 294, 280, 282, 241, 265, 440, 438, 105, 273, 106, 142, 224,
        225, 40, 39, 41, 51, 268, 97, 428, 429, 430, 432, 433, 425, 426, 427,
    ];
}

#[cfg(target_os = "linux")]
fn apply_linux_seccomp_filter() {
    use seccomp::*;
    let (denied, socket_nr): (&[i32], i32) = match std::env::consts::ARCH {
        "x86_64" => (X64_DENIED, 41),
        "aarch64" => (ARM64_DENIED, 198),
        _ => {
            eprintln!("[vault] seccomp: 未知架构，跳过过滤器（best-effort）");
            return;
        }
    };

    unsafe {
        if libc::prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
            eprintln!(
                "[vault] seccomp: PR_SET_NO_NEW_PRIVS 失败（errno={}），跳过",
                *libc::__errno_location()
            );
            return;
        }
    }

    let sf = |code: u16, jt: u8, jf: u8, k: u32| libc::sock_filter { code, jt, jf, k };
    let mut filters: Vec<libc::sock_filter> = Vec::with_capacity(denied.len() * 2 + 8);
    filters.push(sf(BPF_LD_W_ABS, 0, 0, 0));
    for nr in denied {
        filters.push(sf(BPF_JMP_JEQ_K, 0, 1, *nr as u32));
        filters.push(sf(BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS));
    }
    // socket() arg-aware：仅 AF_INET/AF_INET6 以 KILL 拒绝，AF_UNIX 等放行。
    filters.push(sf(BPF_JMP_JEQ_K, 0, 5, socket_nr as u32));
    filters.push(sf(BPF_LD_W_ABS, 0, 0, 16)); // seccomp_data.args[0] = domain
    filters.push(sf(BPF_JMP_JEQ_K, 2, 0, AF_INET));
    filters.push(sf(BPF_JMP_JEQ_K, 1, 0, AF_INET6));
    filters.push(sf(BPF_JMP_JA, 0, 0, 1));
    filters.push(sf(BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS));
    filters.push(sf(BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW));

    let mut prog = libc::sock_fprog {
        len: filters.len() as u16,
        filter: filters.as_mut_ptr(),
    };
    unsafe {
        let rc = libc::prctl(
            PR_SET_SECCOMP,
            SECCOMP_MODE_FILTER,
            &mut prog as *mut libc::sock_fprog as libc::c_ulong,
            0,
            0,
        );
        if rc != 0 {
            eprintln!(
                "[vault] seccomp: PR_SET_SECCOMP 失败（errno={}），best-effort 继续",
                *libc::__errno_location()
            );
            return;
        }
    }
    SECCOMP_ACTIVE.store(true, Ordering::SeqCst);
}

/// 测试探针：直接调用可能被 seccomp 拒绝的 socket()。
#[cfg(unix)]
pub unsafe fn probe_socket(domain: libc::c_int) -> libc::c_int {
    libc::socket(domain, libc::SOCK_STREAM, 0)
}

#[cfg(not(unix))]
pub unsafe fn probe_socket(_domain: libc::c_int) -> libc::c_int {
    -1
}

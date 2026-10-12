// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 平台护栏（与 C# PlatformGuard.cs 语义一致）。
//!
//! Linux：血缘校验 + PR_SET_PDEATHSIG + RLIMIT_CORE=0 + PR_SET_DUMPABLE=0 +
//!        seccomp-BPF denylist（含 socket 按地址族的 arg-aware 特判）；
//! macOS/Windows：血缘校验 + 对应硬化（V1 仅 Linux 完整实现，其余为最小路径）。

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
        // V1：Windows 进程缓解策略（best-effort）——未实现，保持构造契约。
    }
    Ok(ppid)
}

/// 父进程是否已消失。
#[cfg(unix)]
pub fn parent_gone(parent_pid: i32) -> bool {
    let ppid = get_parent_pid();
    ppid <= 1 || ppid != parent_pid
}

/// Windows：父死检测由 OS 句柄实现（V1 未实现）——返回未消失，避免过早自退。
#[cfg(not(unix))]
pub fn parent_gone(_parent_pid: i32) -> bool {
    false
}

#[cfg(unix)]
fn get_parent_pid() -> i32 {
    unsafe { libc::getppid() as i32 }
}

#[cfg(not(unix))]
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
    #[allow(unused_mut)]
    let mut candidates = vec![expected_dir.join("archoera_music")];
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
    if canonicalize(Path::new(&parent_path)) != canonicalize(&expected) {
        return Err(VaultError::invalid_operation(
            "独立运行被拒：父进程不是预期的主程序",
        ));
    }
    Ok(())
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
fn parent_executable_path(_ppid: i32) -> Option<String> {
    // V1：macOS 运行时路径未实现（proc_pidpath）。返回 None → 调用方 fail-closed
    // 或以 dev 布局放行；打包布局下将明确拒绝。
    eprintln!("[vault] 血缘校验：macOS proc_pidpath 在 V1 未实现");
    None
}

#[cfg(windows)]
fn parent_executable_path(_ppid: i32) -> Option<String> {
    None
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn parent_executable_path(_ppid: i32) -> Option<String> {
    None
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

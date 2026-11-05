// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 提权（root / 管理员）探测与 CLI 拦截。
//!
//! 与 GUI 启动门（`app/lib/app/elevation_gate.dart`）同一策略：`archoerashell`
//! 与 MCP 凭据都不需要超级用户权限，以 root / 管理员运行只会放大任何缺陷的
//! 影响面，并写出普通用户难以读取或清理的配置/日志属主。区别是 CLI 没有可
//! 交互的确认界面，故默认**直接拒绝**（退出码 [`EXIT_ELEVATED`]）；容器 / CI
//! 确有需要时用 `ARCHOERA_ALLOW_ELEVATED=1` 显式放行。
//!
//! 只读探测，不做任何提权 / 降权。

/// 拒绝提权启动时的进程退出码（BSD `EX_NOPERM`，便于脚本区分「用法错误」）。
pub const EXIT_ELEVATED: i32 = 77;

/// 容器 / CI 等确需提权时显式放行的环境变量。
const OVERRIDE_ENV: &str = "ARCHOERA_ALLOW_ELEVATED";

/// 当前进程是否持有 root（POSIX）/ 管理员（Windows）权限。
pub fn is_elevated() -> bool {
    #[cfg(unix)]
    {
        // sudo / root 登录 / setuid 均使有效 uid 为 0。
        unsafe { libc::geteuid() == 0 }
    }
    #[cfg(windows)]
    {
        windows::is_elevated()
    }
    #[cfg(not(any(unix, windows)))]
    {
        false
    }
}

/// 是否显式允许提权启动（`ARCHOERA_ALLOW_ELEVATED=1/true/yes/on`）。
pub fn override_allowed() -> bool {
    override_from(std::env::var(OVERRIDE_ENV).ok().as_deref())
}

fn override_from(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim).map(str::to_ascii_lowercase).as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

/// Windows：令牌 `TokenElevation`（UAC 未提权的管理员账户为普通启动）。
///
/// 仓库刻意不引入 `windows-sys`：CLI 面只用到这 4 个符号，手写最小 FFI 可避免
/// 额外依赖与更大的导入表。
#[cfg(windows)]
mod windows {
    use std::os::raw::{c_int, c_void};

    type Handle = *mut c_void;

    const TOKEN_QUERY: u32 = 0x0008;
    const TOKEN_ELEVATION_CLASS: c_int = 20;

    #[repr(C)]
    struct TokenElevation {
        token_is_elevated: u32,
    }

    #[link(name = "advapi32")]
    extern "system" {
        fn OpenProcessToken(process: Handle, desired_access: u32, token: *mut Handle) -> c_int;
        fn GetTokenInformation(
            token: Handle,
            class: c_int,
            info: *mut c_void,
            len: u32,
            returned: *mut u32,
        ) -> c_int;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> Handle;
        fn CloseHandle(handle: Handle) -> c_int;
    }

    pub fn is_elevated() -> bool {
        unsafe {
            let mut token: Handle = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return false;
            }
            let mut info = TokenElevation {
                token_is_elevated: 0,
            };
            let mut returned = 0u32;
            let ok = GetTokenInformation(
                token,
                TOKEN_ELEVATION_CLASS,
                &mut info as *mut TokenElevation as *mut c_void,
                std::mem::size_of::<TokenElevation>() as u32,
                &mut returned,
            );
            CloseHandle(token);
            ok != 0 && info.token_is_elevated != 0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn override_only_accepts_explicit_truthy_values() {
        for v in ["1", "true", "TRUE", " yes ", "on"] {
            assert!(override_from(Some(v)), "{v:?} 应放行");
        }
        for v in ["", "0", "false", "off", "no", "yes please"] {
            assert!(!override_from(Some(v)), "{v:?} 不应放行");
        }
        assert!(!override_from(None));
    }

    #[cfg(unix)]
    #[test]
    fn probe_matches_effective_uid() {
        assert_eq!(is_elevated(), unsafe { libc::geteuid() == 0 });
    }
}

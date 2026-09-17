//! `archoera_shell_v1` —— ArchoeraOS 自定义 Wayland 协议。
//!
//! 协议 XML 位于 workspace 共享目录 `os/protocol/archoera-shell-v1.xml`（相对 crate 根
//! 为 `../protocol/`），由 `wayland-scanner` 的 proc-macro 在编译期展开为服务端绑定
//! （`Request` / `Event` / 接口类型）。控制面客户端 `archoera-control` 读取同一份 XML
//! 生成客户端绑定，保证两端永远一致。
//!
//! 这里刻意把生成代码包一层 `generated` 模块：
//! - `__interfaces` 承载底层 C 接口表，`use self::__interfaces::*;` 再把它提升到
//!   `generated`，满足生成代码内 `super::ARCHOERA_SHELL_V1_INTERFACE` 的引用约定；
//! - 生成代码引用裸名 `wayland_server` / `wayland_backend`，因此两层模块都显式
//!   引入 smithay 的 re-export 别名，避免与 smithay 的 wayland 版本错位。

#[allow(unused_imports)]
pub mod generated {
    use smithay::reexports::wayland_server;
    use smithay::reexports::wayland_server::backend as wayland_backend;

    #[allow(non_upper_case_globals, non_camel_case_types, dead_code)]
    pub mod __interfaces {
        use smithay::reexports::wayland_server::backend as wayland_backend;
        wayland_scanner::generate_interfaces!("../protocol/archoera-shell-v1.xml");
    }

    use self::__interfaces::*;

    wayland_scanner::generate_server_code!("../protocol/archoera-shell-v1.xml");
}

pub use generated::archoera_shell_v1::{
    ArchoeraShellV1, Capability, MediaKey, Request, SessionState,
};

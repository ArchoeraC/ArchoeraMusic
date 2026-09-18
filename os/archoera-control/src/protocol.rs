//! 客户端侧 `archoera_shell_v1` 绑定。
//!
//! 与服务端共用 workspace 内的 `os/protocol/archoera-shell-v1.xml`（相对 crate 根为
//! `../protocol/`），由 `wayland-scanner` 的 proc-macro 在编译期展开，从而在类型层面
//! 保证控制面客户端与合成器使用完全一致的协议定义。

#[allow(unused_imports)]
pub mod generated {
    use wayland_client;

    #[allow(non_upper_case_globals, non_camel_case_types, dead_code)]
    pub mod __interfaces {
        use wayland_client::backend as wayland_backend;

        wayland_scanner::generate_interfaces!("../protocol/archoera-shell-v1.xml");
    }

    use self::__interfaces::*;

    wayland_scanner::generate_client_code!("../protocol/archoera-shell-v1.xml");
}

pub use generated::archoera_shell_v1::{
    ArchoeraShellV1, Capability, Event, MediaKey, OutputFlag, OutputTransform, PowerKey,
    SessionState,
};

//! kiosk 窗口策略：一个会话、一块输出、一个铺满全屏的无装饰窗口。
//!
//! 与通用桌面合成器不同，ArchoeraOS 不做窗口管理：不移动、不缩放、不堆叠、
//! 不绘制装饰。所有 xdg-toplevel 一律被配置为「输出尺寸 + Maximized + Activated」，
//! 客户端（ArchoeraMusic）自己负责整个界面。客户端请求 fullscreen 时按其请求升级为
//! Fullscreen（同样铺满输出），unfullscreen 时回到 Maximized。

use smithay::{
    desktop::{Space, Window},
    reexports::wayland_protocols::xdg::shell::server::xdg_toplevel,
    utils::{Logical, Rectangle, Size},
};
use tracing::warn;

/// 输出矩形（位置 + 尺寸）。
pub type OutputRect = Rectangle<i32, Logical>;

/// 以「铺满输出」方式配置窗口。`fullscreen` 为真时设置 Fullscreen 状态。
///
/// `initial` 为真表示这是首个 configure，必须无条件发送；否则仅在状态确有变化时发送。
pub fn configure_window(window: &Window, output: OutputRect, fullscreen: bool, initial: bool) {
    let Some(toplevel) = window.toplevel() else {
        warn!("kiosk 策略仅支持 xdg-toplevel，忽略非 xdg 窗口");
        return;
    };

    toplevel.with_pending_state(|state| {
        state.states.set(xdg_toplevel::State::Activated);
        state.size = Some(Size::from((output.size.w, output.size.h)));
        if fullscreen {
            state.states.set(xdg_toplevel::State::Fullscreen);
        } else {
            state.states.unset(xdg_toplevel::State::Fullscreen);
            state.states.set(xdg_toplevel::State::Maximized);
        }
    });

    if initial {
        toplevel.send_configure();
    } else {
        toplevel.send_pending_configure();
    }
}

/// 把所有已映射窗口重新配置到当前输出尺寸（输出尺寸变化时调用）。
pub fn reconfigure_all(space: &Space<Window>, output: OutputRect) {
    for window in space.elements() {
        let fullscreen = window
            .toplevel()
            .map(|t| {
                t.with_pending_state(|state| state.states.contains(xdg_toplevel::State::Fullscreen))
            })
            .unwrap_or(false);
        configure_window(window, output, fullscreen, false);
    }
}

/// kiosk 是否接受新窗口：默认**单客户端**——`space` 中已有窗口时拒绝后续 toplevel，
/// 避免第二个客户端抢占 kiosk 界面；`--allow-multiple` 可关闭该限制。
///
/// 集中此处以便后续扩展（例如按 app_id 白名单放行）。
pub fn accepts(space: &Space<Window>, allow_multiple: bool) -> bool {
    allow_multiple || space.elements().next().is_none()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_space_accepts_first_window() {
        let space: Space<Window> = Space::default();
        assert!(accepts(&space, false));
    }

    #[test]
    fn allow_multiple_bypasses_single_client_rule() {
        let space: Space<Window> = Space::default();
        assert!(accepts(&space, true));
    }
}

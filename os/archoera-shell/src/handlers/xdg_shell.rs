//! `xdg_wm_base`（toplevel / popup）与 `zxdg_decoration_manager_v1` 处理器。
//!
//! kiosk 语义：
//! - 新 toplevel 一律铺满输出、激活，不提供移动/缩放；
//! - 装饰模式固定为 `ServerSide`（服务端不绘制任何装饰 → 视觉上无标题栏），
//!   从而让客户端（ArchoeraMusic）放弃自带 CSD，铺满整块屏幕；
//! - popup（菜单/下拉）按常规非约束处理。

use smithay::{
    delegate_xdg_decoration, delegate_xdg_shell,
    desktop::{
        find_popup_root_surface, get_popup_toplevel_coords, PopupKind, PopupManager, Space, Window,
    },
    reexports::{
        wayland_protocols::xdg::{
            decoration::zv1::server::zxdg_toplevel_decoration_v1::Mode, shell::server::xdg_toplevel,
        },
        wayland_server::protocol::{wl_output, wl_seat, wl_surface::WlSurface},
    },
    utils::Serial,
    wayland::{
        compositor::with_states,
        shell::xdg::{
            decoration::XdgDecorationHandler, PopupSurface, PositionerState, ToplevelSurface,
            XdgShellHandler, XdgShellState, XdgToplevelSurfaceData,
        },
    },
};
use tracing::debug;

use crate::{kiosk, state::ArchoeraShell};

impl XdgShellHandler for ArchoeraShell {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let window = Window::new_wayland_window(surface);
        if !kiosk::accepts(&self.space, self.config.allow_multiple) {
            debug!("kiosk 已有窗口，拒绝第二个 toplevel（--allow-multiple 可关闭该限制）");
            return;
        }

        match self.output_rect() {
            Some(rect) => {
                self.space.map_element(window.clone(), rect.loc, true);
                kiosk::configure_window(&window, rect, false, true);
            }
            None => {
                // 输出尚未就绪（后端初始化竞态）：先映射，输出就绪后由后端重配。
                self.space.map_element(window.clone(), (0, 0), true);
            }
        }
        self.focus_topmost();
    }

    fn new_popup(&mut self, surface: PopupSurface, _positioner: PositionerState) {
        self.unconstrain_popup(&surface);
        let _ = self.popups.track_popup(PopupKind::Xdg(surface));
    }

    fn reposition_request(
        &mut self,
        surface: PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        surface.with_pending_state(|state| {
            state.geometry = positioner.get_geometry();
            state.positioner = positioner;
        });
        self.unconstrain_popup(&surface);
        surface.send_repositioned(token);
    }

    fn grab(&mut self, _surface: PopupSurface, _seat: wl_seat::WlSeat, _serial: Serial) {
        // kiosk 不实现弹出菜单抓取。
    }

    fn move_request(&mut self, _surface: ToplevelSurface, _seat: wl_seat::WlSeat, _serial: Serial) {
        // kiosk：忽略窗口移动请求。
    }

    fn resize_request(
        &mut self,
        _surface: ToplevelSurface,
        _seat: wl_seat::WlSeat,
        _serial: Serial,
        _edges: xdg_toplevel::ResizeEdge,
    ) {
        // kiosk：忽略窗口缩放请求。
    }

    fn maximize_request(&mut self, surface: ToplevelSurface) {
        let Some(rect) = self.output_rect() else {
            return;
        };
        surface.with_pending_state(|state| {
            state.states.set(xdg_toplevel::State::Maximized);
            state.states.unset(xdg_toplevel::State::Fullscreen);
            state.size = Some(rect.size);
        });
        surface.send_pending_configure();
    }

    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        // kiosk 永远保持最大化，客户端请求取消时重新授予。
        self.maximize_request(surface);
    }

    fn fullscreen_request(
        &mut self,
        surface: ToplevelSurface,
        output: Option<wl_output::WlOutput>,
    ) {
        let Some(rect) = self.output_rect() else {
            return;
        };
        surface.with_pending_state(|state| {
            state.states.set(xdg_toplevel::State::Fullscreen);
            state.states.set(xdg_toplevel::State::Activated);
            state.size = Some(rect.size);
            state.fullscreen_output = output.clone();
        });
        surface.send_pending_configure();
    }

    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        let Some(rect) = self.output_rect() else {
            return;
        };
        surface.with_pending_state(|state| {
            state.states.unset(xdg_toplevel::State::Fullscreen);
            state.states.set(xdg_toplevel::State::Maximized);
            state.size = Some(rect.size);
        });
        surface.send_pending_configure();
    }
}

delegate_xdg_shell!(ArchoeraShell);

impl XdgDecorationHandler for ArchoeraShell {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        toplevel.with_pending_state(|state| {
            state.decoration_mode = Some(Mode::ServerSide);
        });
        toplevel.send_configure();
    }

    fn request_mode(&mut self, toplevel: ToplevelSurface, _mode: Mode) {
        // kiosk 只接受服务端装饰（即不绘制装饰）；无论客户端偏好都回 ServerSide。
        toplevel.with_pending_state(|state| {
            state.decoration_mode = Some(Mode::ServerSide);
        });
        toplevel.send_configure();
    }

    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        toplevel.with_pending_state(|state| {
            state.decoration_mode = Some(Mode::ServerSide);
        });
        toplevel.send_configure();
    }
}

delegate_xdg_decoration!(ArchoeraShell);

/// 应在 `WlSurface::commit` 时调用：补发初始 configure 并推进 popup 状态机。
pub fn handle_commit(popups: &mut PopupManager, space: &Space<Window>, surface: &WlSurface) {
    if let Some(window) = space
        .elements()
        .find(|w| {
            w.toplevel()
                .map(|t| t.wl_surface() == surface)
                .unwrap_or(false)
        })
        .cloned()
    {
        let initial_configure_sent = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .unwrap()
                .lock()
                .unwrap()
                .initial_configure_sent
        });
        if !initial_configure_sent {
            window.toplevel().unwrap().send_configure();
        }
    }

    popups.commit(surface);
    if let Some(popup) = popups.find_popup(surface) {
        match popup {
            PopupKind::Xdg(ref xdg) => {
                if !xdg.is_initial_configure_sent() {
                    xdg.send_configure().expect("popup 初始 configure 失败");
                }
            }
            PopupKind::InputMethod(ref _im) => {}
        }
    }
}

impl ArchoeraShell {
    fn unconstrain_popup(&self, popup: &PopupSurface) {
        let Ok(root) = find_popup_root_surface(&PopupKind::Xdg(popup.clone())) else {
            return;
        };
        let Some(window) = self.space.elements().find(|w| {
            w.toplevel()
                .map(|t| t.wl_surface() == &root)
                .unwrap_or(false)
        }) else {
            return;
        };
        let Some(output) = self.space.outputs().next() else {
            return;
        };
        let Some(output_geo) = self.space.output_geometry(output) else {
            return;
        };
        let Some(window_geo) = self.space.element_geometry(window) else {
            return;
        };

        let mut target = output_geo;
        target.loc -= get_popup_toplevel_coords(&PopupKind::Xdg(popup.clone()));
        target.loc -= window_geo.loc;

        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }
}

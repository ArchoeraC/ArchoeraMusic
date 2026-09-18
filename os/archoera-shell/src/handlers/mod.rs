//! Wayland 前端协议处理器。
//!
//! 每个协议一种职责：`compositor` / `shm` / `buffer`、`xdg_shell`（含 xdg-decoration）、
//! `dmabuf`（Flutter/GTK 的 EGL 路径）、`archoera_shell`（自定义控制协议）。
//! `Seat` / `DataDevice` / `Output` / `IdleInhibit` 这类跨协议状态在本模块统一实现。

mod archoera_shell;
mod compositor;
mod dmabuf;
mod xdg_shell;

use smithay::{
    delegate_cursor_shape, delegate_data_device, delegate_fractional_scale, delegate_idle_inhibit,
    delegate_input_method_manager, delegate_output, delegate_seat, delegate_text_input_manager,
    delegate_virtual_keyboard_manager,
    desktop::{PopupKind, PopupManager},
    input::{Seat, SeatHandler, SeatState},
    reexports::wayland_server::{protocol::wl_surface::WlSurface, Resource},
    utils::{Logical, Rectangle},
    wayland::{
        compositor::with_states,
        fractional_scale::{self, FractionalScaleHandler},
        idle_inhibit::IdleInhibitHandler,
        input_method::{InputMethodHandler, PopupSurface},
        output::OutputHandler,
        selection::{
            data_device::{
                set_data_device_focus, ClientDndGrabHandler, DataDeviceHandler, DataDeviceState,
                ServerDndGrabHandler,
            },
            SelectionHandler,
        },
    },
};

use crate::state::ArchoeraShell;

//
// wl_seat
//

impl SeatHandler for ArchoeraShell {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        image: smithay::input::pointer::CursorImageStatus,
    ) {
        self.cursor.set_status(image);
        // 光标变化要立刻出帧，否则指针会停在旧形状 / 旧位置。
        self.mark_dirty();
        self.schedule_redraw();
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let dh = &self.display_handle;
        let client = focused.and_then(|s| dh.get_client(s.id()).ok());
        set_data_device_focus(dh, seat, client);
    }
}

delegate_seat!(ArchoeraShell);

//
// wl_data_device（剪贴板 / 拖放）
//

impl SelectionHandler for ArchoeraShell {
    type SelectionUserData = ();
}

impl DataDeviceHandler for ArchoeraShell {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device_state
    }
}

impl ClientDndGrabHandler for ArchoeraShell {}
impl ServerDndGrabHandler for ArchoeraShell {}

delegate_data_device!(ArchoeraShell);

//
// wl_output / zxdg_output
//

impl OutputHandler for ArchoeraShell {}

delegate_output!(ArchoeraShell);

//
// zwp_idle_inhibit（播放器请求防休眠）
//

impl IdleInhibitHandler for ArchoeraShell {
    fn inhibit(&mut self, surface: WlSurface) {
        self.idle_inhibitors = self.idle_inhibitors.saturating_add(1);
        if self.idle_inhibitors == 1 {
            let reason = self
                .idle_reason
                .clone()
                .unwrap_or_else(|| "播放器请求保持唤醒".to_string());
            if self.control.set_idle_inhibited(true, &reason) {
                tracing::info!(?surface, "已开启防休眠");
            }
        }
    }

    fn uninhibit(&mut self, surface: WlSurface) {
        self.idle_inhibitors = self.idle_inhibitors.saturating_sub(1);
        if self.idle_inhibitors == 0 {
            self.control.set_idle_inhibited(false, "");
            tracing::info!(?surface, "已关闭防休眠");
        }
    }
}

delegate_idle_inhibit!(ArchoeraShell);

//
// wp_fractional_scale_v1（客户端按输出分数缩放清晰渲染）
//

impl FractionalScaleHandler for ArchoeraShell {
    fn new_fractional_scale(&mut self, surface: WlSurface) {
        // 输出缩放由 `--scale` 决定；新 surface 订阅时即告知首选分数缩放，
        // 客户端（GTK/Flutter）据此按物理像素渲染，避免模糊。
        let scale = self.config.scale;
        with_states(&surface, |states| {
            fractional_scale::with_fractional_scale(states, |fs| fs.set_preferred_scale(scale));
        });
    }
}

delegate_fractional_scale!(ArchoeraShell);

//
// wp_cursor_shape_v1（客户端请求命名光标形状）
//
// 没有它时 GTK 会走「从主题按名字加载光标」的老路；在没有完整桌面会话的系统上
// 该查找可能失败，客户端随后发 `set_cursor(NULL)`，表现为「指针消失」。
// 有它时 GDK 直接请求形状，由合成器用 XCursor 主题绘制。

// `delegate_cursor_shape!` 以 `TabletSeatHandler` 为约束（数位板工具也能设形状）；
// 本合成器不注册数位板协议全局，仅提供默认实现满足约束。
impl smithay::wayland::tablet_manager::TabletSeatHandler for ArchoeraShell {}

delegate_cursor_shape!(ArchoeraShell);

//
// zwp_input_method_v2 / zwp_text_input_v3（输入法）
//
// smithay 在 `TextInputManagerState` ↔ `InputMethodManagerState` 之间自动互转
// （客户端输入上下文 → IME，IME 的 preedit/commit → 客户端，以及键盘抓取），
// 并随键盘焦点自动 enter/leave；合成器只需接全局对象、跟踪候选窗口 popup。

impl InputMethodHandler for ArchoeraShell {
    fn new_popup(&mut self, surface: PopupSurface) {
        // 候选窗口挂在当前输入焦点窗口上，随该窗口一起渲染。
        if let Err(err) = self.popups.track_popup(PopupKind::from(surface)) {
            tracing::warn!(%err, "跟踪输入法候选窗口失败");
        }
        self.mark_dirty();
        self.schedule_redraw();
    }

    fn popup_repositioned(&mut self, _surface: PopupSurface) {
        self.mark_dirty();
        self.schedule_redraw();
    }

    fn dismiss_popup(&mut self, surface: PopupSurface) {
        if let Some(parent) = surface.get_parent().map(|parent| parent.surface.clone()) {
            let _ = PopupManager::dismiss_popup(&parent, &PopupKind::from(surface));
        }
        self.mark_dirty();
        self.schedule_redraw();
    }

    fn parent_geometry(&self, parent: &WlSurface) -> Rectangle<i32, Logical> {
        // kiosk 单窗口：候选窗口相对命中的窗口几何定位。
        self.space
            .elements()
            .find_map(|window| {
                let matches = window
                    .toplevel()
                    .map(|toplevel| toplevel.wl_surface() == parent)
                    .unwrap_or(false);
                matches.then(|| window.geometry())
            })
            .unwrap_or_default()
    }
}

delegate_input_method_manager!(ArchoeraShell);
delegate_text_input_manager!(ArchoeraShell);

//
// zwp_virtual_keyboard_v1（虚拟键盘 / IME 按键转发）
//
// fcitx5 的 Wayland 前端在启用输入法上下文前会同时查找 `zwp_input_method_v2` 与
// `zwp_virtual_keyboard_v1`；只有前者时它不会抓取键盘，表现为「无法切换输入法」。
// 该全局同时允许屏幕键盘客户端注入按键。按键经 `Seat` 的键盘焦点直接下发给客户端。
delegate_virtual_keyboard_manager!(ArchoeraShell);
